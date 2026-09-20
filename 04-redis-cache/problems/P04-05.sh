#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-05 · Cache-aside yarışı: DB yazımı ile geçersiz kılma arasındaki pencere
# Sıra şudur: (1) DB'yi değiştir, (2) önbelleği sil. Bu iki adım arasında gelen bir OKUMA,
# DB'den ESKİ değeri alır ve önbelleğe GERİ YAZAR — silme onun öncesinde olduğu için.
# Sonuç: bayat kayıt TTL boyunca yaşar. Pencere normalde mikrosaniyelerdir; küçük olması
# yok olduğu anlamına GELMEZ — yeterince trafikte her pencere er geç yakalanır.
ensure_healthy
DELAY=${DELAY:-800}
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_UPDATE_DELAY_MS-"
step "Pencereyi ölçülebilir hâle getir: silme ile geçersiz kılma arasına ${DELAY}ms koy"
kubectl -n "$NS" set env deploy/linkly TRAP_UPDATE_DELAY_MS="$DELAY" >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null
for _ in $(seq 1 20); do serving && break; sleep 2; done
stale=0; tot=${TOT:-12}
step "$tot kez: link oluştur → önbelleğe al → SİL ve tam o anda paralel OKU"
for i in $(seq 1 $tot); do
  code=$(create_link "https://example.com/race/$i")
  [[ -z "$code" ]] && continue
  status_of "$code" >/dev/null            # önbelleğe girsin
  ( curl -s -o /dev/null -XDELETE "$BASE_URL/api/links/$code" ) &
  sleep 0.15                              # silme başladı, geçersiz kılma henüz olmadı
  for _ in $(seq 1 6); do status_of "$code" >/dev/null; done   # bu okumalar ESKİ değeri geri yazabilir
  wait
  sleep 1
  after=$(status_of "$code")
  [[ "$after" == 30* ]] && stale=$((stale+1))
done
grafana_hint "04 · Cache → 'ops by result & layer' · 03 · App Business → 'redirect sonuçları'"
note "$tot denemeden $stale tanesinde link SİLİNDİĞİ HÂLDE hâlâ yönlendiriyor"
note "Sıra tersine çevrilseydi (önce sil, sonra DB) başka bir yarış doğardı: silme ile DB yazımı"
note "arasında okuyan biri YENİ olmayan eski değeri önbelleğe koyardı. Cache-aside'ın yapısal sınırı bu."
note "Azaltma yolları: (a) yazmadan SONRA ikinci kez sil (delayed double delete),"
note "                 (b) sürümlü anahtar (link:v2:<code>) — eski anahtar hiç okunmaz,"
note "                 (c) write-through + kısa TTL. Hiçbiri bedava değil; hangisini seçtiğini BİL."
(( stale > 0 )) && reproduced "$stale/$tot durumda silinmiş link önbellekten yönlendirmeye devam etti (yarış penceresi)"
not_reproduced "yarış yakalanamadı (DELAY/TOT artırıp tekrar dene)"
