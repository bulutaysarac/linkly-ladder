#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P04-05 · Cache-aside yarışı: DB'den okuma ile önbelleğe yazma arasındaki pencere
# Bayatlığın KALICI olanı şu sıradan doğar:
#   t0  okuma önbelleği ıskalar, DB'den ESKİ değeri alır
#   t1  başkası satırı SİLER: DB'den gider, önbellek geçersiz kılınır — ama anahtar önbellekte
#       HENÜZ YOK, yani geçersiz kılma hiçbir şey silmez
#   t2  t0'daki okuma nihayet önbelleğe yazar: SİLİNMİŞ kayıt TTL boyunca yaşar
# Pencere normalde mikrosaniyelerdir. Küçük olması YOK olduğu anlamına gelmez: yeterli trafikte
# her pencere er geç yakalanır. Burada TRAP_READ_FILL_DELAY_MS ile pencereyi görünür kılıyoruz.
#
# ÖLÇÜM DERSİ: bu deneyin ilk hâli yanlış pencereyi büyütüyordu (silme ile geçersiz kılma arası).
# Orada anahtar hâlâ önbellektedir; okuyanlar bayat değeri zaten hit olarak alır ve geçersiz
# kılmadan sonra düzelir — yani KALICI bayatlık üretmez. "Yarışı büyüttüm" demeden önce hangi
# iki olayın yarıştığını yaz.
DELAY=${DELAY:-1500}
TOT=${TOT:-6}
ensure_healthy
on_cleanup "kubectl -n \"$NS\" set env deploy/linkly TRAP_READ_FILL_DELAY_MS-"
step "Pencereyi ölçülebilir hâle getir: okuma yolunda DB→önbellek arasına ${DELAY}ms"
kubectl -n "$NS" set env deploy/linkly TRAP_READ_FILL_DELAY_MS="$DELAY" >/dev/null
kubectl -n "$NS" rollout status deploy/linkly --timeout=180s >/dev/null || true
for _ in $(seq 1 30); do serving && break; sleep 2; done
stale=0
step "$TOT kez: ıskalayan bir OKUMA başlat → tam ortasında SİL → sonucu kontrol et"
for i in $(seq 1 "$TOT"); do
  code=$(create_link "https://example.com/race/$i/$RANDOM")
  [[ -z "$code" ]] && continue
  # Kod HENÜZ okunmadı → önbellekte yok. Bu okuma ıskalayacak: DB'den alıp ${DELAY}ms bekleyecek.
  ( status_of "$code" >/dev/null ) &
  reader=$!
  sleep 0.4                                   # okuma DB'den değeri ALDI, henüz YAZMADI
  curl -s -o /dev/null -XDELETE "$BASE_URL/api/links/$code"   # DB'den sil + önbelleği geçersiz kıl
  wait "$reader" 2>/dev/null || true          # okuma şimdi BAYAT değeri önbelleğe yazıyor
  sleep 1
  after=$(status_of "$code")
  [[ "$after" == 30* ]] && { stale=$((stale+1)); note "  deneme $i: kod=$code → $after (SİLİNMİŞ ama hâlâ yönlendiriyor)"; } \
                        || note "  deneme $i: kod=$code → $after"
done
grafana_hint "04 · Cache → 'ops by result & layer' · 03 · App Business → 'redirect sonuçları'"
note "$TOT denemeden $stale tanesinde link SİLİNDİĞİ HÂLDE hâlâ yönlendiriyor (TTL boyunca)"
note "Sıra tersine çevrilseydi (önce önbelleği sil, sonra DB) pencere kapanmaz, YER DEĞİŞTİRİRDİ:"
note "bu kez silme ile DB yazımı arasında okuyan biri eski değeri geri yazardı. Cache-aside'ın"
note "yapısal sınırı bu — hangi sırayı seçersen seç bir pencere kalır."
note "Azaltma yolları: (a) yazmadan SONRA ikinci kez sil (delayed double delete),"
note "                 (b) sürümlü anahtar (link:v2:<code>) — eski anahtar hiç okunmaz,"
note "                 (c) write-through + kısa TTL, (d) 14'teki gibi geçersiz kılma YAYINI."
note "Hiçbiri bedava değil; pencereyi kapatmıyorlar, DARALTIYORLAR. Hangisini seçtiğini BİL."
(( stale > 0 )) && reproduced "$stale/$TOT durumda silinmiş link önbellekten yönlendirmeye devam etti (cache-aside yarışı)"
not_reproduced "yarış yakalanamadı (DELAY/TOT artırıp tekrar dene)"
