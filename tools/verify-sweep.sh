#!/usr/bin/env bash
# Doğrulama turu: profil → make up → verify-prev → kendi sorunları → make down.
# Kullanım: tools/verify-sweep.sh 08-rate-limiting 09-database-scaling ...
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)

# Bir adım asılırsa bütün tur kaybolmasın: süreç AĞACINI öldüren sert zaman sınırı.
# (macOS'ta `timeout` yok; alt kabuğa TERM göndermek, o kabuk ön plandaki çocuğunu
# beklerken iletilmiyor — bu yüzden çocuklar önce, ebeveyn sonra.)
_kill_tree() { local p=$1 c; for c in $(pgrep -P "$p" 2>/dev/null); do _kill_tree "$c"; done; kill -KILL "$p" 2>/dev/null || true; }
hard_timeout() {
  local secs=$1; shift
  ( "$@" ) & local pid=$!
  # >/dev/null ŞART: watchdog stdout'u MİRAS ALIR. Bu fonksiyon `$( )` içinde çağrıldığında
  # komut ikamesi EOF bekler ve watchdog borusu açık kaldığı için ASILI KALIR — komut çoktan
  # bitmiş olsa bile. Gece turu tam olarak burada durdu; P07-07'nin saatlerce asılması da
  # büyük ihtimalle buydu. Arka plana attığın her şeyin çıktısını KAPAT.
  ( sleep "$secs"; _kill_tree "$pid" ) >/dev/null 2>&1 & local wd=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true
  return "$rc"
}

run_level() {
  local L=$1 lvl=${1%%-*}
  "$R/platform/lib/profile.sh" "$lvl"
  cd "$R/$L" || return 1
  echo "═══ $L · make up"
  local upout; upout=$(hard_timeout "${UP_TIMEOUT:-1500}" make up 2>&1) || {
    echo "✘ $L ayağa kalkmadı"
    echo "$upout" | tail -12 | sed 's/^/         ! /'
    # TEMİZLE: başarısız kurulum namespace'i AYAKTA bırakıyordu ve bir sonraki seviye onun
    # üstüne kuruluyordu. Üç seviye aynı anda çalışınca etcd "request timed out" vermeye
    # başladı — yani bir seviyenin arızası, sonraki seviyelerin ölçümünü bozdu.
    echo "═══ $L · make down (başarısız kurulum temizleniyor)"
    make down >/dev/null 2>&1
    return 1
  }
  echo "═══ $L · verify-prev"
  # --line-buffered: yoksa grep çıktıyı tamponlar ve verify-prev'in TAMAMI bitene kadar tek
  # satır bile görünmez. Saatler süren bir turda "ilerliyor mu, asıldı mı?" ayrımını kaybedersin.
  CONFIRM=1 hard_timeout "${PREV_TIMEOUT:-5400}" make verify-prev 2>&1 | grep --line-buffered -E '^(ID|P[0-9]{2}-)' || echo "(önceki seviye yok)"
  echo "═══ $L · kendi sorunları"
  for f in problems/P${lvl}-*.sh; do
    [[ -e "$f" ]] || continue
    p=$(basename "${f%.sh}")
    rc=0
    out=$(CONFIRM=1 hard_timeout "${REPRO_TIMEOUT:-1200}" make repro P="$p" 2>&1) || rc=$?
    r=$(echo "$out" | grep -oE 'NOT-REPRODUCED|REPRODUCED' | tail -1)
    # ATLANDI ile HATA AYNI ŞEY DEĞİLDİR. Bir script, ölçmesi gereken şeyi ölçemediğini anlayıp
    # (metrik yok, yük sınıra dayanmadı, deney elle koşulmalı) bilerek 2 ile çıkabilir; bu bir
    # ÇÖKME değil, DÜRÜSTLÜKtür. İkisini tek kovaya atarsan rapor "8 script patladı" der ve
    # gerçekte doğru davranan scriptler hata gibi görünür — yani ölçüm disiplinini cezalandırmış
    # olursun. verify-prev tarafı bu ayrımı zaten yapıyordu; kendi sorunları tarafı yapmıyordu.
    # EN: SKIPPED and ERROR are not the same. A script may deliberately exit 2 after discovering
    # it cannot measure what it must (metric missing, load never reached the limit, experiment
    # needs a human) — that is honesty, not a crash. Bucketing both makes the report say "8
    # scripts blew up" and punishes exactly the scripts that behaved correctly.
    if [[ -z "$r" && "$rc" == "2" ]]; then r=SKIPPED; fi
    printf '%-8s %s\n' "$p" "${r:-HATA}"
    # ÖLÇÜLEN SAYILARI SAKLA: ilk hâl son 8/10 satırı basıyordu ve bu, kararı veren satırların
    # (ölçülen değerler) tam olarak kesildiği yerdi — sonuçta "NOT-REPRODUCED" görünüyor ama
    # NEYİN ölçüldüğü görünmüyordu, yani rapor teşhis edilemiyordu. Bir tur kaydı, tekrar
    # koşmayı gerektirmeyecek kadar bilgi taşımalı.
    if [[ "${r:-HATA}" == "HATA" || "${r:-}" == "SKIPPED" ]]; then echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -20 | sed 's/^/         ! /'
    else echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^(  |▶)' | sed 's/^/         · /'; fi
  done
  echo "═══ $L · make down"; make down >/dev/null 2>&1
  echo "═══ $L · bitti"
}
for L in "$@"; do run_level "$L"; done
