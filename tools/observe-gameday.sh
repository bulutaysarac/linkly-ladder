#!/usr/bin/env bash
# Kullanım: NS=lvl14 N=90 tools/observe-gameday.sh | tee /tmp/observe.log   (deneyle AYNI ANDA koş)
# Game day gözlemcisi v2: istemcinin (k6) gördüğü ile uygulamanın saydığı YAN YANA, her 3 sn.
# Aradaki fark istemciyle uygulama arasındaki bir katmandır (ingress, limiter, endpoint yok).
NS=${NS:-lvl14}; P=http://prometheus.localtest.me; N=${N:-90}
q(){ curl -s -XPOST "$P/api/v1/query" --data-urlencode "query=$1" 2>/dev/null | jq -r '.data.result[0].value[1] // "-"'; }
f(){ [[ "$1" == "-" ]] && printf '%s' - || printf '%.0f' "$1"; }
printf '%-8s %-5s %-4s %-7s %-7s %-7s %-7s %-7s %-7s %-6s %-5s %-6s %-5s\n' \
  saat hazır kyv k6_rps k6_5xx app_rps app_5xx app_429 exempt infl brk shed dgr
for _ in $(seq 1 "$N"); do
  ep=$(kubectl -n $NS get endpointslice -l kubernetes.io/service-name=redirect \
        -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null | grep -c true)
  kyv=$(kubectl -n kyverno get deploy kyverno-admission-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  k6r=$(q "sum(rate(k6_http_reqs_total{level=\"$NS\"}[15s]))")
  k65=$(q "sum(rate(k6_http_reqs_total{level=\"$NS\",status=~\"5..|0\"}[15s]))")
  ar=$(q "sum(rate(http_requests_total{namespace=\"$NS\",service=~\"redirect|api\"}[30s]))")
  a5=$(q "sum(rate(http_requests_total{namespace=\"$NS\",service=~\"redirect|api\",code=~\"5..\"}[30s]))")
  a4=$(q "sum(rate(http_requests_total{namespace=\"$NS\",service=~\"redirect|api\",code=\"429\"}[30s]))")
  ex=$(q "sum(rate(ratelimit_decisions_total{namespace=\"$NS\",decision=\"exempt\"}[30s]))")
  inf=$(q "max(http_in_flight_requests{namespace=\"$NS\"})")
  br=$(q "max(breaker_state{namespace=\"$NS\"})")
  sh=$(q "sum(rate(load_shed_total{namespace=\"$NS\"}[30s]))")
  dg=$(q "max(degraded_mode{namespace=\"$NS\"})")
  printf '%-8s %-5s %-4s %-7s %-7s %-7s %-7s %-7s %-7s %-6s %-5s %-6s %-5s\n' "$(date +%H:%M:%S)" "${ep:-0}" "${kyv:-0}" \
    "$(f "$k6r")" "$(f "$k65")" "$(f "$ar")" "$(f "$a5")" "$(f "$a4")" "$(f "$ex")" "$(f "$inf")" "$(f "$br")" "$(f "$sh")" "$(f "$dg")"
  sleep 3
done
