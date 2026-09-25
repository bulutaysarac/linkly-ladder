#!/usr/bin/env bash
# Tam tur: 00 → 14, her seviyede rehberin sırası — kur, önceki seviyenin sorunlarını koş (verify-prev),
# kendi sorunlarını koş, kapat. Her adımın başlangıç/bitiş saati ve hükmü kaydedilir; rapor
# (tools/full-run-report.py) bu kayıttan, saat aralığı linke gömülü Grafana linkleriyle üretilir.
#
#   tools/full-run.sh                      00 → 14
#   tools/full-run.sh 05-async-analytics … yalnızca verilen seviyeler (sırayla)
#
# Veri yalnızca turun BAŞINDA silinir (make wipe); seviyeler FRESH=0 ile kurulur, yani bütün tur tek
# bir zaman ekseninde kalır ve sonradan Grafana'da saat aralığıyla incelenir (Prometheus 48 sa saklar).
# Çıktı: reports/tam-tur-<zaman>/ → runs.tsv (kayıt), logs/ (her adımın tam çıktısı), RAPOR.md.
# Uzun sürer (8-12 sa); Mac uyumasın diye caffeinate altında koşar. Koşarken kümede başka iş yapma.
# [Topic · Konu: Deney araçları]
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
STAMP=$(date +%Y%m%d-%H%M)
OUT=${OUT:-$R/reports/tam-tur-$STAMP}
mkdir -p "$OUT/logs"
TSV="$OUT/runs.tsv"
[[ -f "$TSV" ]] || printf 'level\tkind\tid\tstart\tend\tresult\texpected\tsummary\tlog\n' > "$TSV"
export CONFIRM=1
# Game day bu makinede 100 istek/sn ile geçerli ölçülür; 300'de küme kendi arızasını üretir.
export GAMEDAY_RATE=${GAMEDAY_RATE:-100}
PROM_URL=${PROM_URL:-http://prometheus.localtest.me}

if [[ -z "${CAFFEINATED:-}" ]] && command -v caffeinate >/dev/null; then
  CAFFEINATED=1 OUT="$OUT" exec caffeinate -i "$0" "$@"
fi

_kill_tree() { local p=$1 c; for c in $(pgrep -P "$p" 2>/dev/null); do _kill_tree "$c"; done; kill -KILL "$p" 2>/dev/null || true; }
# Bir adım asılırsa tur durmasın: süreç ağacını öldüren sert zaman sınırı. Arka plan çıktısı kapalı —
# açık kalan bir boru, bekleyen komut ikamesini sonsuza kadar asar.
hard_timeout() {
  local secs=$1; shift
  ( "$@" ) & local pid=$!
  ( sleep "$secs"; _kill_tree "$pid" ) >/dev/null 2>&1 & local wd=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true
  return "$rc"
}
# Seviye değil KÜME bozuksa bunu ayrı söyle: API sunucusu cevap veriyor, pod'lar Running ve
# Prometheus'un SORGU ucu çalışıyor mu? (Running bir Prometheus WAL oynatırken 503 döner.)
wait_platform() {
  local budget=900 waited=0 bad prom
  while (( waited < budget )); do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then
      bad=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | wc -l | tr -d ' ')
      prom=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -XPOST "$PROM_URL/api/v1/query" --data-urlencode 'query=sum(up)')
      [[ "$bad" == 0 && "$prom" == 200 ]] && return 0
    fi
    sleep 15; waited=$((waited + 15))
  done
  return 1
}
clean() { sed $'s/\033\\[[0-9;]*m//g'; }
verdict() {  # $1 = temiz çıktı dosyası, $2 = çıkış kodu → "SONUÇ<TAB>özet"
  local line
  line=$(grep -E '^(NOT-REPRODUCED|REPRODUCED)\b' "$1" | tail -1)
  if [[ -n "$line" ]]; then
    printf '%s\t%s' "${line%% *}" "$(echo "${line#* }" | sed 's/^[^—]*— //' | tr '\t' ' ' | cut -c1-300)"
  elif [[ "$2" == 2 ]]; then
    printf 'SKIPPED\t%s' "$(grep -E 'SKIPPED|ATLANDI|ölçülemedi|!' "$1" | tail -1 | tr '\t' ' ' | cut -c1-300)"
  else
    printf 'HATA(%s)\t%s' "$2" "$(grep -v '^\s*$' "$1" | tail -1 | tr '\t' ' ' | cut -c1-300)"
  fi
}
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$TSV"; }

run_step() {  # level kind id expected timeout cwd -- komut…
  local level=$1 kind=$2 id=$3 expected=$4 secs=$5 cwd=$6; shift 7
  local log="$OUT/logs/$level-$kind-$id.log" t0 t1 rc=0 v
  t0=$(date +%s)
  ( cd "$cwd" && hard_timeout "$secs" "$@" ) > "$log.raw" 2>&1 || rc=$?
  t1=$(date +%s)
  clean < "$log.raw" > "$log"; rm -f "$log.raw"
  if [[ "$kind" == up || "$kind" == down ]]; then
    v=$([[ $rc == 0 ]] && printf 'OK\t' || printf 'HATA(%s)\t%s' "$rc" "$(tail -1 "$log" | tr '\t' ' ' | cut -c1-200)")
  else
    v=$(verdict "$log" "$rc")
  fi
  record "$level" "$kind" "$id" "$t0" "$t1" "${v%%$'\t'*}" "$expected" "${v#*$'\t'}" "logs/$(basename "$log")"
  printf '  %s %-6s %-8s %-16s %4ss\n' "$(date +%H:%M:%S)" "$kind" "$id" "${v%%$'\t'*}" "$((t1 - t0))"
}

LEVELS=("$@")
[[ ${#LEVELS[@]} -gt 0 ]] || LEVELS=($(cd "$R" && ls -d [0-9][0-9]-* | sort))

echo "▶ tam tur → $OUT"
if [[ "${SKIP_WIPE:-0}" != 1 ]]; then
  echo "▶ veriler siliniyor (yalnızca turun başında)"
  ( cd "$R" && make wipe CONFIRM=1 ) > "$OUT/logs/wipe.log" 2>&1 || { echo "✘ wipe başarısız: $OUT/logs/wipe.log"; exit 1; }
fi

prev=""
for L in "${LEVELS[@]}"; do
  lvl=${L%%-*}; D="$R/$L"; NS=lvl$lvl
  echo "═══ $L  ($(date +%H:%M))"
  if ! wait_platform; then
    record "$lvl" platform - "$(date +%s)" "$(date +%s)" "HATA" "" "küme hazır değil (API, pod ya da Prometheus sorgu ucu)" ""
    echo "✘ platform hazır değil — tur durdu"; break
  fi
  run_step "$lvl" up up "" 1800 "$D" -- env FRESH=0 make up
  if ! tail -1 "$TSV" | cut -f6 | grep -q '^OK$'; then
    run_step "$lvl" down down "" 600 "$D" -- make down
    prev=$L; continue
  fi
  prevdir=$(cd "$R" && ls -d [0-9][0-9]-* | sort | awk -v cur="$L" '$0==cur{print p; exit}{p=$0}')
  if [[ -n "$prevdir" ]]; then
    for f in "$R/$prevdir"/problems/P*.sh; do
      id=$(basename "${f%.sh}")
      exp=""; grep -qx "$id" "$D/problems/SOLVES" 2>/dev/null && exp=NOT-REPRODUCED
      run_step "$lvl" prev "$id" "$exp" 1200 "$D" -- env NS="$NS" LEVEL="$lvl" BASE_URL="http://$NS.localtest.me" \
        PROM_URL="$PROM_URL" GRAFANA_URL=http://grafana.localtest.me LADDER_ROOT="$R" bash "$f"
    done
  fi
  for f in "$D"/problems/P"$lvl"-*.sh; do
    [[ -e "$f" ]] || continue
    id=$(basename "${f%.sh}")
    run_step "$lvl" own "$id" "" 1500 "$D" -- make repro P="$id"
  done
  run_step "$lvl" down down "" 900 "$D" -- make down
  python3 "$R/tools/full-run-report.py" "$OUT" >/dev/null 2>&1 || true
  prev=$L
done
python3 "$R/tools/full-run-report.py" "$OUT" && echo "✔ rapor: $OUT/RAPOR.md"
