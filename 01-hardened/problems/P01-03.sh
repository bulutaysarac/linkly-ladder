#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
# P01-03 · Tek replika + PDB = güvenlik yanılsaması
#
# İKİ UÇLU AÇMAZ. PDB "en az 1 pod ayakta kalsın" der; tek replikada bu şu demektir:
#   (a) Drain BLOKE olur → node bakımı yapamazsın (kernel yaması, upgrade, node değişimi).
#   (b) Zorlarsan (force / PDB'yi sil) → pod ölür, yedeği yok → KESİNTİ.
# Yani PDB erişilebilirlik ÜRETMEZ; yalnızca var olan yedekliliği korur. Yedeklilik yoksa
# koruyacak bir şey de yoktur — sadece bakımı kilitler. [Topic · Konu: HA, PDB, yedeklilik]
ensure_healthy
node=$(kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}') || true
allowed=$(kubectl -n "$NS" get pdb linkly -o jsonpath='{.status.disruptionsAllowed}') || true
step "PDB ne vaat ediyor?"
note "minAvailable=$(kubectl -n "$NS" get pdb linkly -o jsonpath='{.spec.minAvailable}') · izin verilen kesinti=$allowed · replika=$(replicas_of) · pod node'u=$node"
[[ "$allowed" == "0" ]] && note "izin verilen kesinti 0: PDB şu an her gönüllü tahliyeyi REDDEDECEK"

need_confirm "node cordon+drain denenecek (deney sonunda uncordon edilir)"
# Script nerede hata verirse versin node cordon'lu KALMAMALI (bkz. platform/lib/repro.sh · run_cleanup).
on_cleanup "kubectl uncordon '$node'"
( k6run redirect --vus 1 --duration 90s >/tmp/p0103.k6 2>&1 ) & kpid=$!
sleep 10

# UYGULAMANIN ERİŞİLEBİLİRLİĞİNİ ÖLÇ, TOPLAM 5xx'İ DEĞİL.
# EN: `kubectl drain` evicts EVERY pod on the node — including the single Postgres at level 02.
#     The app then returns 5xx because the DATABASE is gone, which is P02-03's problem, not this
#     one; a verdict built on total 5xx reads them as "no safe maintenance for the app" and
#     reproduces even at a level that has app redundancy. A measurement must be scoped to the
#     claim it supports: here the claim is about the APP's redundancy, so the measure is the
#     app's ready endpoint count — did it ever reach zero?
# TR: `kubectl drain` node'daki HER pod'u tahliye eder — 02'deki tek Postgres dahil. Uygulama o
#     zaman VERİTABANI gittiği için 5xx döner; bu P02-03'ün sorunudur, bunun değil. Toplam 5xx'e
#     dayanan bir hüküm bunları "uygulama için güvenli bakım yok" diye okur ve uygulama
#     yedekliliği olan bir seviyede de REPRODUCED der. Ölçü, desteklediği iddiaya göre
#     daraltılmalı: iddia UYGULAMANIN yedekliliği hakkında, o hâlde ölçü hazır endpoint sayısıdır
#     — hiç sıfıra indi mi?
EPS=$(mktemp); on_cleanup "rm -f '$EPS'"
( while :; do
    kubectl -n "$NS" get endpointslice -l "kubernetes.io/service-name=$(app_name)" \
      -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null \
      | count_lines true >> "$EPS"
    echo >> "$EPS"
    sleep 2
  done ) & eppid=$!
on_cleanup "kill $eppid 2>/dev/null"

step "UÇ (a): normal drain — PDB'ye saygı duyarak"
# NOT: `set -e` altında `x=$(başarısız komut)` scripti ÖLDÜRÜR — `; rc=$?` bunu engellemez,
# çünkü hata atama komutunun kendisinde oluşur. Bu yüzden `|| rc=$?` kalıbı şart.
# Zaten burada drain'in BAŞARISIZ olması beklenen sonuç: PDB tahliyeyi reddediyor.
drain_rc=0
drain_out=$(kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=40s 2>&1) || drain_rc=$?
echo "$drain_out" | tail -3 | sed 's/^/    /'
blocked=false
{ (( drain_rc != 0 )) || grep -qiE 'disruption budget|global timeout' <<<"$drain_out"; } && blocked=true
note "drain çıkış kodu: $drain_rc → $([[ $blocked == true ]] && echo 'BLOKE (node bakımı yapılamıyor)' || echo 'geçti')"

step "UÇ (b): operatörün gerçekte yaptığı şey — zorla"
# YALNIZCA drain edilmek istenen node'daki pod'u zorla. Hepsini silmek, çok replikalı bir seviyede
# (02+) yapay bir kesinti üretir ve "yedeklilik işe yaramadı" gibi YANLIŞ bir sonuç verirdi.
victim=$(kubectl -n "$NS" get pods -l "$APP_SELECTOR" --field-selector "spec.nodeName=$node" \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$victim" ]]; then
  note "zorla silinen pod: $victim (node $node)"
  kubectl -n "$NS" delete pod "$victim" --force --grace-period=0 >/dev/null 2>&1 || true
else
  note "bu node'da uygulama pod'u yok — zorlamaya gerek kalmadı"
fi
sleep 25
kill $eppid 2>/dev/null || true
min_ep=$(grep -E '^[0-9]+$' "$EPS" 2>/dev/null | sort -n | head -1); min_ep=${min_ep:-0}
wait_ready >/dev/null 2>&1 || true
wait $kpid || true
e5=$(k6_5xx); e404=$(k6_404)
note "bakım penceresinde EN DÜŞÜK hazır uygulama endpoint'i: $min_ep"
grafana_hint "02 · App RED → 5xx ; 01 · Pods & Resources → 'Pod fazları' (Pending)"
note "zorlamadan sonra: 5xx=$e5 · 404=$e404 (404'ler P01-01: yeni pod'un belleği boş)"
note "Sonuç: PDB ya bakımı kilitler ya da kesintiyi seyreder. Üçüncü seçenek YEDEKLİLİKTİR — 02."
note "Karşılaştırma: aynı script 02'de (3 replika, minAvailable=2) drain'i geçirir ve 5xx üretmez."
# DRAIN'İN ÇIKIŞ KODU DA KİRLİ BİR SİNYALDİR.
# EN: `kubectl drain` must evict EVERY pod on the node. At level 02 the same node also carries
#     the single Postgres, whose eviction can exceed the 40s timeout — the drain then "fails" for
#     a reason that has nothing to do with the APP's disruption budget, and a verdict built on the
#     exit code reads that as "no safe maintenance for the app". Ask the question directly: does the app's PDB
#     ALLOW a voluntary disruption, and did the app stay up while one happened? Everything else
#     (drain exit code, total 5xx) is context, not evidence.
# TR: `kubectl drain` node'daki HER pod'u tahliye etmek zorundadır. 02'de aynı node tek Postgres'i
#     de taşıyor ve onun tahliyesi 40 sn'lik süreyi aşabiliyor; drain o zaman UYGULAMANIN kesinti
#     bütçesiyle ilgisi olmayan bir sebepten "başarısız" oluyor ve çıkış koduna dayanan bir hüküm
#     bunu "uygulama için güvenli bakım yok" diye okur. Soruyu doğrudan sor: uygulamanın PDB'si gönüllü bir
#     kesintiye İZİN VERİYOR MU ve kesinti olurken uygulama ayakta kaldı mı? Gerisi (drain çıkış
#     kodu, toplam 5xx) kanıt değil bağlamdır.
note "drain sonucu: $([[ $blocked == true ]] && echo 'bloke/başarısız' || echo 'geçti') — bu, node'daki DİĞER pod'lardan da etkilenir, hükümde kanıt sayılmaz"
{ (( ${allowed:-0} == 0 )) || (( min_ep == 0 )); } \
  && reproduced "güvenli bakım YOK: PDB'nin izin verdiği kesinti=${allowed:-0}, bakım penceresinde hazır endpoint en düşük $min_ep (drain $([[ $blocked == true ]] && echo 'bloke' || echo 'geçti'), 5xx=$e5)"
not_reproduced "PDB ${allowed:-0} kesintiye izin veriyor ve uygulama hep ayakta kaldı (en düşük endpoint $min_ep) — yedeklilik var (02). Not: 5xx=$e5 olabilir; o zaman sebep uygulama değil, tek replikalı bağımlılıktır (P02-03)."
