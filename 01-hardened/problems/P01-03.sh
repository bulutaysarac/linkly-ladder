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
node=$(kubectl -n "$NS" get pod -l "$APP_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}')
allowed=$(kubectl -n "$NS" get pdb linkly -o jsonpath='{.status.disruptionsAllowed}')
step "PDB ne vaat ediyor?"
note "minAvailable=$(kubectl -n "$NS" get pdb linkly -o jsonpath='{.spec.minAvailable}') · izin verilen kesinti=$allowed · replika=$(replicas_of) · pod node'u=$node"
[[ "$allowed" == "0" ]] && note "izin verilen kesinti 0: PDB şu an her gönüllü tahliyeyi REDDEDECEK"

need_confirm "node cordon+drain denenecek (deney sonunda uncordon edilir)"
# Script nerede hata verirse versin node cordon'lu KALMAMALI (bkz. platform/lib/repro.sh · run_cleanup).
on_cleanup "kubectl uncordon '$node'"
( k6run redirect --vus 1 --duration 90s >/tmp/p0103.k6 2>&1 ) & kpid=$!
sleep 10

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
wait_ready >/dev/null 2>&1 || true
wait $kpid || true
e5=$(k6_5xx); e404=$(k6_404)
grafana_hint "02 · App RED → 5xx ; 01 · Pods & Resources → 'Pod fazları' (Pending)"
note "zorlamadan sonra: 5xx=$e5 · 404=$e404 (404'ler P01-01: yeni pod'un belleği boş)"
note "Sonuç: PDB ya bakımı kilitler ya da kesintiyi seyreder. Üçüncü seçenek YEDEKLİLİKTİR — 02."
note "Karşılaştırma: aynı script 02'de (3 replika, minAvailable=2) drain'i geçirir ve 5xx üretmez."
{ [[ "$blocked" == true ]] || (( e5 > 0 )); } \
  && reproduced "tek replikada güvenli bakım YOK: drain $([[ $blocked == true ]] && echo 'bloke oldu' || echo 'geçti'), zorlayınca $e5 istek 5xx aldı"
not_reproduced "drain sorunsuz geçti ve kesinti olmadı — yedeklilik var (02)"
