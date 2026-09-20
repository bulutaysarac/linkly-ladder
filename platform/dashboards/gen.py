#!/usr/bin/env python3
"""Ladder dashboard üreteci → out/*.json. Tek set, tüm seviyeler; $level (namespace) değişkeni.
Metrik adları docs/API.md §Metrikler ile aynı — bir seviyede metrik yoksa panel boş kalır (bilerek)."""
import json, os, pathlib

DS = {"type": "prometheus", "uid": "prometheus"}
OUT = pathlib.Path(__file__).parent / "out"
NS = 'namespace="$level"'
# NOT: bu kurulumdaki cAdvisor (kind + Docker Desktop, cgroup v1) `container` label'ı ÜRETMİYOR.
# Standart `container!=""` filtresi burada HİÇBİR seri döndürmez; gerçek konteyner serilerini
# `image` label'ı üzerinden seçiyoruz (pause konteynerini eleyerek). `container` label'ı olan
# ortamlarda da doğru çalışır.
APP = 'namespace="$level",image!="",image!~".*pause.*"' 
_uid = [0]

def target(expr, legend=""):
    return {"datasource": DS, "expr": expr, "legendFormat": legend or "__auto", "refId": chr(65 + _uid[0] % 26)}

def panel(kind, title, targets, unit="short", w=12, h=8, desc="", extra=None):
    _uid[0] += 1
    p = {"id": _uid[0], "type": kind, "title": title, "description": desc, "datasource": DS,
         "gridPos": {"w": w, "h": h, "x": 0, "y": 0},
         "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "palette-classic"}}, "overrides": []},
         "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
         "targets": [] if kind == "text" else [dict(t, refId=chr(65 + i)) for i, t in enumerate(targets)]}
    if kind == "stat":
        p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value", "graphMode": "area"}
    if kind == "text":
        p["options"] = {"mode": "markdown", "content": targets}; p["targets"] = []
    if extra: p.update(extra)
    return p

def ts(title, exprs, unit="short", w=12, h=8, desc="", stacked=False):
    p = panel("timeseries", title, [target(e, l) for e, l in exprs], unit, w, h, desc)
    if stacked: p["fieldConfig"]["defaults"]["custom"] = {"stacking": {"mode": "normal"}, "fillOpacity": 20}
    return p

def stat(title, expr, unit="short", w=6, h=4, desc=""):
    return panel("stat", title, [target(expr)], unit, w, h, desc)

def text(md, w=24, h=3):
    return panel("text", "", md, w=w, h=h)

def row(title):
    _uid[0] += 1
    return {"id": _uid[0], "type": "row", "title": title, "collapsed": False, "gridPos": {"w": 24, "h": 1, "x": 0, "y": 0}, "panels": []}

def layout(panels):
    x = y = rowh = 0
    for p in panels:
        w, h = p["gridPos"]["w"], p["gridPos"]["h"]
        if p["type"] == "row" or x + w > 24:
            y += rowh; x = 0; rowh = 0
        p["gridPos"].update(x=x, y=y)
        x += w; rowh = max(rowh, h)
        if p["type"] == "row": y += 1; x = 0; rowh = 0
    return panels

def dashboard(uid, title, panels, with_level=True, tags=("ladder",)):
    templating = []
    if with_level:
        templating.append({"name": "level", "label": "level", "type": "query", "datasource": DS,
            "query": {"query": 'label_values(kube_namespace_created{namespace=~"lvl.*"}, namespace)', "refId": "v"},
            "definition": 'label_values(kube_namespace_created{namespace=~"lvl.*"}, namespace)',
            "refresh": 2, "sort": 1, "current": {"text": "lvl00", "value": "lvl00"}, "options": [], "includeAll": False})
    return {"uid": f"ladder-{uid}", "title": f"Ladder / {title}", "tags": list(tags), "timezone": "browser",
            "schemaVersion": 39, "version": 1, "editable": False, "graphTooltip": 1, "refresh": "10s",
            "time": {"from": "now-30m", "to": "now"}, "templating": {"list": templating}, "panels": layout(panels)}

RATE = lambda sel, rng="1m": f'sum(rate(http_requests_total{{{NS}{sel}}}[{rng}]))'
P = lambda q, rng="1m", by="": f'histogram_quantile({q}, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[{rng}])) by (le{by}))'

D = {}

D["00-overview"] = dashboard("overview", "00 · Overview (tüm seviyeler)", [
    text("**Merdivenin tamamı yan yana.** Her satır bir seviye (namespace `lvlNN`). Uygulama metriği olmayan seviyede (00) sadece pod/restart satırları dolar."),
    ts("Availability (1 − 5xx oranı)", [('1 - (sum(rate(http_requests_total{namespace=~"lvl.*",code=~"5.."}[2m])) by (namespace) / sum(rate(http_requests_total{namespace=~"lvl.*"}[2m])) by (namespace))', "{{namespace}}")], "percentunit", 12),
    ts("p99 latency", [('histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=~"lvl.*"}[2m])) by (le, namespace))', "{{namespace}}")], "s", 12),
    ts("rps", [('sum(rate(http_requests_total{namespace=~"lvl.*"}[1m])) by (namespace)', "{{namespace}}")], "reqps", 8),
    ts("Restart (container)", [('sum(kube_pod_container_status_restarts_total{namespace=~"lvl.*"}) by (namespace)', "{{namespace}}")], "short", 8),
    ts("Pod sayısı", [('count(kube_pod_info{namespace=~"lvl.*"}) by (namespace)', "{{namespace}}")], "short", 8),
    ts("k6 client hata oranı", [('k6_http_req_failed_rate{level=~"lvl.*"}', "{{level}}")], "percentunit", 12),
    ts("k6 client p99", [('k6_http_req_duration_p99{level=~"lvl.*"}', "{{level}}")], "ms", 12),
], with_level=False)

D["01-pods-resources"] = dashboard("pods", "01 · Pods & Resources", [
    text("cAdvisor + kube-state-metrics + (01'den itibaren) Go runtime. **00'da tek gördüğün burası.**"),
    ts("CPU kullanımı (core)", [(f'sum(rate(container_cpu_usage_seconds_total{{{APP}}}[2m])) by (pod)', "{{pod}}")], "short", 8),
    ts("CPU throttling (s/s)", [(f'sum(rate(container_cpu_cfs_throttled_seconds_total{{{APP}}}[2m])) by (pod)', "{{pod}}")], "short", 8, desc="07 · P07-04. UYARI: bu kurulumda (cgroup v1) cAdvisor throttling metriği yayınlamıyor — panel boş kalabilir, ortam sınırı"),
    ts("Bellek working set", [(f'sum by (pod) (container_memory_working_set_bytes{{{APP}}})', "{{pod}}"), (f'max(kube_pod_container_resource_limits{{{NS},resource="memory"}}) by (pod)', "limit {{pod}}")], "bytes", 8, desc="Limit çizgisine değince OOMKilled"),
    ts("Restart sayısı", [(f'kube_pod_container_status_restarts_total{{{NS}}}', "{{pod}}")], "short", 8),
    ts("Son sonlanma nedeni", [(f'kube_pod_container_status_last_terminated_reason{{{NS}}}', "{{pod}} {{reason}}")], "short", 8, desc="OOMKilled / Error / Completed"),
    ts("Pod fazları", [(f'sum(kube_pod_status_phase{{{NS}}}) by (phase)', "{{phase}}")], "short", 8, stacked=True),
    ts("Goroutine", [(f'go_goroutines{{{NS}}}', "{{pod}}")], "short", 8, desc="01+ · yarım bağlantılar, asılı istekler burada birikir"),
    ts("Heap alloc", [(f'go_memstats_heap_alloc_bytes{{{NS}}}', "{{pod}}")], "bytes", 8),
    ts("GC süresi (s/s)", [(f'rate(go_gc_duration_seconds_sum{{{NS}}}[2m])', "{{pod}}")], "short", 8),
    ts("Endpoint (hazır adres) sayısı", [(f'sum(kube_endpoint_address{{{NS},ready="true"}}) by (endpoint)', "{{endpoint}}")], "short", 12, desc="10 · P10-02: readiness bağımlılığa bağlıysa burası 0'a düşer"),
    ts("Network rx/tx", [(f'sum(rate(container_network_receive_bytes_total{{{NS}}}[2m])) by (pod)', "rx {{pod}}"), (f'sum(rate(container_network_transmit_bytes_total{{{NS}}}[2m])) by (pod)', "tx {{pod}}")], "Bps", 12),
])

D["02-app-red"] = dashboard("app-red", "02 · App RED", [
    text("Rate · Errors · Duration — route bazlı. Metrikler 01'den itibaren. Boşsa: uygulama `/metrics` sunmuyor ya da ServiceMonitor yok."),
    stat("rps", RATE(""), "reqps"), stat("5xx oranı", RATE(',code=~"5.."') + " / " + RATE(""), "percentunit"),
    stat("p99", P(0.99), "s"), stat("in-flight", f'sum(http_in_flight_requests{{{NS}}})', "short"),
    ts("rps by route", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (route)', "{{route}}")], "reqps", 12, stacked=True),
    ts("rps by status class", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (code)', "{{code}}")], "reqps", 12, stacked=True),
    ts("latency p50/p95/p99", [(P(0.5), "p50"), (P(0.95), "p95"), (P(0.99), "p99")], "s", 12),
    ts("p99 by route", [(P(0.99, by=", route"), "{{route}}")], "s", 12),
    ts("5xx by route", [(f'sum(rate(http_requests_total{{{NS},code=~"5.."}}[1m])) by (route)', "{{route}}")], "reqps", 8),
    ts("4xx by code", [(f'sum(rate(http_requests_total{{{NS},code=~"4.."}}[1m])) by (code)', "{{code}}")], "reqps", 8),
    ts("Panic / timeout", [(f'sum(rate(http_panics_total{{{NS}}}[1m]))', "panic"), (f'sum(rate(http_requests_total{{{NS},code="503",route="timeout"}}[1m]))', "timeout")], "reqps", 8),
    ts("rps by pod", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (pod)', "{{pod}}")], "reqps", 12, desc="LB dağılımı dengesiz mi?"),
    ts("p99 by pod", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, pod))', "{{pod}}")], "s", 12),
])

D["03-app-business"] = dashboard("app-business", "03 · App Business", [
    text("İş metrikleri: link sayısı, redirect sonuçları, kod üretimi, güvenlik reddi, read-your-writes."),
    stat("links_total (gauge)", f'sum(links_total{{{NS}}})', desc="02 öncesi: pod restartında sıfırlanır (P01-01)"),
    stat("redirect ok/s", f'sum(rate(redirect_total{{{NS},result="ok"}}[1m]))', "reqps"),
    stat("redirect 404/s", f'sum(rate(redirect_total{{{NS},result="not_found"}}[1m]))', "reqps"),
    stat("create ok/s", f'sum(rate(create_total{{{NS},result="ok"}}[1m]))', "reqps"),
    ts("redirect sonuçları", [(f'sum(rate(redirect_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True),
    ts("redirect 404 by pod", [(f'sum(rate(redirect_total{{{NS},result="not_found"}}[1m])) by (pod)', "{{pod}}")], "reqps", 12, desc="P01-02: bellek içi store + N replika → pod bazlı 404"),
    ts("create sonuçları", [(f'sum(rate(create_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True, desc="collision/exhausted: keyspace baskısı"),
    ts("links_total by pod", [(f'links_total{{{NS}}}', "{{pod}}")], "short", 12),
    ts("Güvenlik reddi (unsafe URL)", [(f'sum(rate(create_rejected_unsafe_total{{{NS}}}[1m])) by (reason)', "{{reason}}")], "reqps", 8),
    ts("Read-your-writes ihlali", [(f'sum(rate(ryw_violations_total{{{NS}}}[1m]))', "violations")], "reqps", 8, desc="09 · P09-01"),
    ts("İstek / tenant", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (tenant)', "{{tenant}}")], "reqps", 8, desc="13+ (label tenant; 11'de kardinalite uyarısı)"),
])

D["04-cache"] = dashboard("cache", "04 · Cache", [
    text("03: L1 (pod içi) · 04: L2 (Redis) · 14: L1+L2. Hit ratio **pod bazlı** — P03-04'ü burada görürsün."),
    stat("hit ratio (toplam)", f'sum(rate(cache_ops_total{{{NS},result=~"hit|negative_hit"}}[2m])) / sum(rate(cache_ops_total{{{NS}}}[2m]))', "percentunit"),
    stat("miss/s", f'sum(rate(cache_ops_total{{{NS},result="miss"}}[1m]))', "reqps"),
    stat("stampede wait/s", f'sum(rate(cache_stampede_wait_total{{{NS}}}[1m]))', "reqps", desc="Yükselmesi hata değil: koruma çalışıyor"),
    stat("entries", f'sum(cache_entries{{{NS}}})'),
    ts("hit ratio by pod", [(f'sum(rate(cache_ops_total{{{NS},result=~"hit|negative_hit"}}[2m])) by (pod) / sum(rate(cache_ops_total{{{NS}}}[2m])) by (pod)', "{{pod}}")], "percentunit", 12),
    ts("ops by result & layer", [(f'sum(rate(cache_ops_total{{{NS}}}[1m])) by (layer, result)', "{{layer}} {{result}}")], "reqps", 12, stacked=True),
    ts("cache miss vs DB qps", [(f'sum(rate(cache_ops_total{{{NS},result="miss"}}[1m]))', "miss"), (f'sum(rate(db_queries_total{{{NS}}}[1m]))', "db queries")], "reqps", 12, desc="Miss ≈ DB sorgusu olmalı; değilse başka biri DB'ye gidiyor"),
    ts("eviction / expired / invalidate", [(f'sum(rate(cache_evictions_total{{{NS}}}[1m])) by (reason)', "{{reason}}")], "reqps", 12),
    ts("entries by pod", [(f'cache_entries{{{NS}}}', "{{pod}}")], "short", 12, desc="P03-03: N pod × aynı içerik"),
    ts("cache load error", [(f'sum(rate(cache_errors_total{{{NS}}}[1m])) by (op)', "{{op}}")], "reqps", 12, desc="P04-06: Redis OOM → SET hataları"),
])

D["05-postgres"] = dashboard("postgres", "05 · Postgres", [
    text("02: postgres-exporter sidecar · 09: CNPG (replication, failover). App tarafı: pgx pool metrikleri."),
    stat("connections", f'sum(pg_stat_activity_count{{{NS}}})'), stat("max_connections", f'max(pg_settings_max_connections{{{NS}}})'),
    stat("tps", f'sum(rate(pg_stat_database_xact_commit{{{NS}}}[1m]))', "ops"), stat("cache hit ratio", f'sum(rate(pg_stat_database_blks_hit{{{NS}}}[2m])) / (sum(rate(pg_stat_database_blks_hit{{{NS}}}[2m])) + sum(rate(pg_stat_database_blks_read{{{NS}}}[2m])))', "percentunit"),
    ts("connections vs max", [(f'sum(pg_stat_activity_count{{{NS}}}) by (state)', "{{state}}"), (f'max(pg_settings_max_connections{{{NS}}})', "max")], "short", 12, stacked=False, desc="P02-02: tavana yapışınca `too many clients`"),
    ts("DB CPU (container)", [(f'sum(rate(container_cpu_usage_seconds_total{{{NS},pod=~".*postgres.*|.*pg.*"}}[2m])) by (pod)', "{{pod}}")], "short", 12, desc="P02-01: her redirect DB'ye"),
    ts("App pool: acquire wait p99", [(f'histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{{{NS}}}[1m])) by (le, pod))', "{{pod}}")], "s", 12, desc="Havuz doluysa burası büyür"),
    ts("App pool: empty acquire/s", [(f'sum(rate(db_pool_empty_acquire_total{{{NS}}}[1m])) by (pod)', "{{pod}}")], "reqps", 12),
    ts("DB queries by op", [(f'sum(rate(db_queries_total{{{NS}}}[1m])) by (op)', "{{op}}")], "reqps", 12, stacked=True),
    ts("DB query p99 by op", [(f'histogram_quantile(0.99, sum(rate(db_query_duration_seconds_bucket{{{NS}}}[1m])) by (le, op))', "{{op}}")], "s", 12),
    ts("seq scan / idx scan", [(f'sum(rate(pg_stat_user_tables_seq_scan{{{NS}}}[1m])) by (relname)', "seq {{relname}}"), (f'sum(rate(pg_stat_user_tables_idx_scan{{{NS}}}[1m])) by (relname)', "idx {{relname}}")], "ops", 12, desc="P02-05"),
    ts("locks", [(f'sum(pg_locks_count{{{NS}}}) by (mode)', "{{mode}}")], "short", 12, desc="P02-08: hot link satır kilidi"),
    ts("dead tuples", [(f'sum(pg_stat_user_tables_n_dead_tup{{{NS}}}) by (relname)', "{{relname}}")], "short", 12, desc="P09-06"),
    ts("replication lag", [(f'max(cnpg_pg_replication_lag{{{NS}}}) by (pod)', "{{pod}}"), (f'max(pg_replication_lag_seconds{{{NS}}}) by (pod)', "{{pod}}")], "s", 12, desc="09 · P09-01"),
])

D["06-redis"] = dashboard("redis", "06 · Redis", [
    text("04+: redis_exporter sidecar."),
    stat("ops/s", f'sum(rate(redis_commands_processed_total{{{NS}}}[1m]))', "ops"), stat("clients", f'sum(redis_connected_clients{{{NS}}})'),
    stat("memory", f'sum(redis_memory_used_bytes{{{NS}}})', "bytes"), stat("maxmemory", f'max(redis_memory_max_bytes{{{NS}}})', "bytes"),
    ts("keyspace hit/miss", [(f'sum(rate(redis_keyspace_hits_total{{{NS}}}[1m]))', "hit"), (f'sum(rate(redis_keyspace_misses_total{{{NS}}}[1m]))', "miss")], "ops", 12, stacked=True),
    ts("memory vs maxmemory", [(f'sum(redis_memory_used_bytes{{{NS}}})', "used"), (f'max(redis_memory_max_bytes{{{NS}}})', "max")], "bytes", 12, desc="P04-06"),
    ts("evicted / expired keys", [(f'sum(rate(redis_evicted_keys_total{{{NS}}}[1m]))', "evicted"), (f'sum(rate(redis_expired_keys_total{{{NS}}}[1m]))', "expired")], "ops", 12),
    ts("Redis CPU", [(f'sum(rate(container_cpu_usage_seconds_total{{{NS},pod=~".*redis.*"}}[2m])) by (pod)', "{{pod}}")], "short", 12, desc="P04-03: hot key tek çekirdek"),
    ts("commands by type", [(f'sum(rate(redis_commands_total{{{NS}}}[1m])) by (cmd)', "{{cmd}}")], "ops", 12, stacked=True, desc="P04-07: KEYS görünürse alarm"),
    ts("App → Redis latency p99", [(f'histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{{{NS},dep="redis"}}[1m])) by (le))', "p99")], "s", 12),
    ts("redis_up", [(f'redis_up{{{NS}}}', "{{pod}}")], "short", 12, desc="P04-01"),
])

D["07-analytics"] = dashboard("analytics", "07 · Analytics", [
    text("05: süreç içi kuyruk · 06: broker. **k6 tıklama − DB tıklama** farkı at-most-once kaybını gösterir."),
    stat("enqueued/s", f'sum(rate(analytics_events_total{{{NS},result="enqueued"}}[1m]))', "reqps"),
    stat("dropped/s", f'sum(rate(analytics_events_total{{{NS},result="dropped"}}[1m]))', "reqps"),
    stat("written/s", f'sum(rate(analytics_events_total{{{NS},result="written"}}[1m]))', "reqps"),
    stat("queue depth", f'sum(analytics_queue_depth{{{NS}}})'),
    ts("events by result", [(f'sum(rate(analytics_events_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True),
    ts("queue depth by pod", [(f'analytics_queue_depth{{{NS}}}', "{{pod}}"), (f'max(analytics_queue_capacity{{{NS}}})', "capacity")], "short", 12, desc="P05-02 back pressure"),
    ts("Tıklama farkı: k6 redirect (kümülatif) − DB'ye yazılan", [(f'sum(increase(k6_http_reqs_total{{level="$level",name="GET /{{code}}"}}[$__range]))', "k6 redirects"), (f'sum(increase(analytics_events_total{{{NS},result="written"}}[$__range]))', "written")], "short", 24, h=9, desc="P05-01: rollout sırasında aradaki fark = kaybolan tıklamalar"),
    ts("batch write latency p99", [(f'histogram_quantile(0.99, sum(rate(analytics_batch_duration_seconds_bucket{{{NS}}}[1m])) by (le))', "p99")], "s", 12),
    ts("stats endpoint p99", [(P(0.99, by=", route").replace(f'{{{NS}}}', f'{{{NS},route="/api/links/{{code}}/stats"}}'), "stats")], "s", 12, desc="P05-04 count(*)"),
])

D["08-stream"] = dashboard("stream", "08 · Stream (Redpanda)", [
    text("06+: producer buffer, consumer lag, duplicate, DLQ."),
    stat("produce/s", f'sum(rate(producer_records_total{{{NS},result="ok"}}[1m]))', "reqps"),
    stat("producer buffer", f'sum(producer_buffered_records{{{NS}}})'),
    stat("consumer lag (max)", f'max(redpanda_kafka_max_offset{{{NS}}} - on(redpanda_topic, redpanda_partition) group_left redpanda_kafka_consumer_group_committed_offset{{{NS}}})'),
    stat("DLQ/s", f'sum(rate(consumer_records_total{{{NS},result="dlq"}}[1m]))', "reqps"),
    ts("consumer lag by partition", [(f'sum(redpanda_kafka_max_offset{{{NS}}} - on(redpanda_topic, redpanda_partition) group_left redpanda_kafka_consumer_group_committed_offset{{{NS}}}) by (redpanda_partition)', "p{{redpanda_partition}}")], "short", 12, desc="P06-02/03"),
    ts("consumer records by result", [(f'sum(rate(consumer_records_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True, desc="duplicate: P06-01"),
    ts("producer buffer & drops", [(f'sum(producer_buffered_records{{{NS}}}) by (pod)', "buffered {{pod}}"), (f'sum(rate(producer_records_total{{{NS},result="dropped"}}[1m]))', "dropped/s")], "short", 12, desc="P06-05"),
    ts("consumer commit/s & pods", [(f'sum(rate(consumer_commits_total{{{NS}}}[1m]))', "commits/s"), (f'count(kube_pod_info{{{NS},pod=~".*analytics.*"}})', "consumer pods")], "short", 12),
    ts("broker up", [(f'up{{{NS},job=~".*redpanda.*"}}', "{{pod}}")], "short", 12),
    ts("Tıklama: produced vs consumed vs written (kümülatif)", [(f'sum(increase(producer_records_total{{{NS},result="ok"}}[$__range]))', "produced"), (f'sum(increase(consumer_records_total{{{NS},result="ok"}}[$__range]))', "consumed"), (f'sum(increase(analytics_events_total{{{NS},result="written"}}[$__range]))', "written")], "short", 12),
])

D["09-autoscaling"] = dashboard("autoscaling", "09 · Autoscaling", [
    text("07+: HPA / KEDA. desired vs current vs target; Pending pod'lar; node kapasitesi."),
    ts("HPA desired / current", [(f'kube_horizontalpodautoscaler_status_desired_replicas{{{NS}}}', "desired {{horizontalpodautoscaler}}"), (f'kube_horizontalpodautoscaler_status_current_replicas{{{NS}}}', "current {{horizontalpodautoscaler}}"), (f'kube_horizontalpodautoscaler_spec_max_replicas{{{NS}}}', "max {{horizontalpodautoscaler}}")], "short", 12, desc="P07-01 gecikme / flapping"),
    ts("rps (sunucu) vs pod sayısı", [(RATE(""), "rps"), (f'count(kube_pod_info{{{NS}}})', "pods")], "short", 12),
    ts("Pending pod", [(f'sum(kube_pod_status_phase{{{NS},phase="Pending"}})', "pending")], "short", 8, desc="P07-05"),
    ts("Node CPU allocatable vs requests", [('sum(kube_node_status_allocatable{resource="cpu"})', "allocatable"), ('sum(kube_pod_container_resource_requests{resource="cpu"})', "requested")], "short", 8),
    ts("Pod yaşı vs p99 (yeni pod soğuk)", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, pod))', "{{pod}}")], "s", 8, desc="P07-03"),
    ts("Pod dağılımı / node", [(f'count(kube_pod_info{{{NS}}}) by (node)', "{{node}}")], "short", 12, desc="P07-07: hepsi aynı node'daysa…"),
    ts("KEDA scaler metric", [(f'keda_scaler_metrics_value{{{NS}}}', "{{scaledObject}} {{metric}}")], "short", 12),
])

D["10-ratelimit"] = dashboard("ratelimit", "10 · Rate limit", [
    text("01: süreç içi per-IP · 08: Redis'te dağıtık. Normal client p99 vs abuser — koruma işe yarıyor mu?"),
    stat("allow/s", f'sum(rate(ratelimit_decisions_total{{{NS},decision="allow"}}[1m]))', "reqps"),
    stat("reject/s", f'sum(rate(ratelimit_decisions_total{{{NS},decision="reject"}}[1m]))', "reqps"),
    stat("429 oranı", RATE(',code="429"') + " / " + RATE(""), "percentunit"),
    stat("limiter backend hata/s", f'sum(rate(ratelimit_errors_total{{{NS}}}[1m]))', "reqps", desc="P08-01 fail-open/closed"),
    ts("decisions by key type", [(f'sum(rate(ratelimit_decisions_total{{{NS}}}[1m])) by (key_type, decision)', "{{key_type}} {{decision}}")], "reqps", 12, stacked=True),
    ts("allow by pod (P02-04: N pod × limit)", [(f'sum(rate(ratelimit_decisions_total{{{NS},decision="allow"}}[1m])) by (pod)', "{{pod}}")], "reqps", 12),
    ts("k6: normal client p99 vs abuser", [('k6_normal_client_latency_p99{level="$level"}', "normal p99"), ('k6_http_req_duration_p99{level="$level",scenario="abuser"}', "abuser p99")], "ms", 12),
    ts("Kabul edilen rps (sınır testi)", [(f'sum(rate(http_requests_total{{{NS},code!="429",route="GET /{{code}}"}}[10s]))', "accepted")], "reqps", 12, desc="P08-04 pencere sınırında 2× burst"),
])

D["11-resilience"] = dashboard("resilience", "11 · Resilience", [
    text("10+: breaker, shedding, retry, bağımlılık gecikmesi, endpoint sayısı."),
    ts("breaker state by dep (0 closed · 1 half · 2 open)", [(f'max(breaker_state{{{NS}}}) by (dep)', "{{dep}}")], "short", 12),
    ts("dependency p99 by dep", [(f'histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, dep))', "{{dep}}")], "s", 12),
    ts("dependency errors/s", [(f'sum(rate(dependency_requests_total{{{NS},result="error"}}[1m])) by (dep)', "{{dep}}")], "reqps", 8),
    ts("retry/s by dep", [(f'sum(rate(retry_total{{{NS}}}[1m])) by (dep)', "{{dep}}")], "reqps", 8, desc="P10-01 retry fırtınası"),
    ts("load shed/s", [(f'sum(rate(load_shed_total{{{NS}}}[1m]))', "shed")], "reqps", 8, desc="P10-06"),
    ts("in-flight by pod", [(f'http_in_flight_requests{{{NS}}}', "{{pod}}")], "short", 12, desc="P10-05 yavaş bağımlılık → birikme"),
    ts("hazır endpoint sayısı", [(f'sum(kube_endpoint_address{{{NS},ready="true"}}) by (endpoint)', "{{endpoint}}")], "short", 12, desc="P10-02"),
    ts("degrade modu", [(f'max(degraded_mode{{{NS}}}) by (mode)', "{{mode}}")], "short", 12),
    ts("kabul edilen isteklerin p99 (503 hariç)", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS},code!="503"}}[1m])) by (le))', "p99")], "s", 12),
])

D["12-slo"] = dashboard("slo", "12 · SLO", [
    text("11+: Sloth. redirect availability 99.9 · latency p99 < 300 ms. Burn-rate alarmları."),
    ts("SLI error ratio (5m)", [(f'slo:sli_error:ratio_rate5m{{{NS}}}', "{{sloth_slo}}")], "percentunit", 12),
    ts("error budget remaining", [(f'slo:period_error_budget_remaining:ratio{{{NS}}}', "{{sloth_slo}}")], "percentunit", 12),
    ts("burn rate 1h / 6h", [(f'slo:sli_error:ratio_rate1h{{{NS}}} / on(sloth_id) group_left slo:error_budget:ratio{{{NS}}}', "1h {{sloth_slo}}"), (f'slo:sli_error:ratio_rate6h{{{NS}}} / on(sloth_id) group_left slo:error_budget:ratio{{{NS}}}', "6h {{sloth_slo}}")], "short", 12),
    ts("Alarmlar (firing)", [('ALERTS{alertstate="firing",namespace=~"lvl.*"}', "{{alertname}} {{namespace}}")], "short", 12, desc="P11-04"),
])

D["13-rollout"] = dashboard("rollout", "13 · Rollout", [
    text("12+: Argo Rollouts. stable vs canary yan yana."),
    ts("rps by version", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (version)', "{{version}}")], "reqps", 12, stacked=True),
    ts("5xx oranı by version", [(f'sum(rate(http_requests_total{{{NS},code=~"5.."}}[1m])) by (version) / sum(rate(http_requests_total{{{NS}}}[1m])) by (version)', "{{version}}")], "percentunit", 12, desc="P12-01"),
    ts("p99 by version", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, version))', "{{version}}")], "s", 12),
    ts("Rollout fazı / canary ağırlığı", [(f'rollout_info{{{NS}}}', "{{name}} {{phase}}"), (f'rollout_info_replicas_desired{{{NS}}}', "desired")], "short", 12),
    ts("Argo CD sync durumu", [('argocd_app_info{sync_status!="Synced"}', "{{name}} {{sync_status}}")], "short", 12, desc="P12-03 drift"),
])

D["14-security"] = dashboard("security", "14 · Security", [
    text("13+: kimlik, tenant, policy, unsafe URL."),
    ts("401 / 403 /s", [(f'sum(rate(http_requests_total{{{NS},code=~"401|403"}}[1m])) by (code)', "{{code}}")], "reqps", 12),
    ts("unsafe URL reddi by reason", [(f'sum(rate(create_rejected_unsafe_total{{{NS}}}[1m])) by (reason)', "{{reason}}")], "reqps", 12, desc="P13-05"),
    ts("Kyverno policy sonuçları", [('sum(rate(kyverno_policy_results_total{policy_result="fail"}[5m])) by (policy_name)', "{{policy_name}}")], "reqps", 12, desc="P13-07"),
    ts("NetworkPolicy drop (calico)", [('sum(rate(felix_int_dataplane_failures[5m]))', "dataplane failures")], "reqps", 12),
    ts("404 taraması (scan) /s", [(f'sum(rate(redirect_total{{{NS},result="not_found"}}[1m]))', "404/s")], "reqps", 12, desc="P13-06 enumeration"),
])

D["15-k6"] = dashboard("k6", "15 · k6 (client tarafı)", [
    text("k6 → Prometheus remote-write. `level` tag'i ile seviyeye bağlı. Sunucu panelleriyle **aynı zaman ekseni** — aynı anı karşılaştır."),
    stat("rps (client)", 'sum(rate(k6_http_reqs_total{level="$level"}[1m]))', "reqps"),
    stat("failed rate", 'k6_http_req_failed_rate{level="$level"}', "percentunit"),
    stat("p99", 'k6_http_req_duration_p99{level="$level"}', "ms"),
    stat("VUs", 'k6_vus{level="$level"}'),
    ts("rps by name", [('sum(rate(k6_http_reqs_total{level="$level"}[1m])) by (name)', "{{name}}")], "reqps", 12, stacked=True),
    ts("failed rate", [('k6_http_req_failed_rate{level="$level"}', "failed")], "percentunit", 12),
    ts("latency p50/p95/p99", [('k6_http_req_duration_p50{level="$level"}', "p50"), ('k6_http_req_duration_p95{level="$level"}', "p95"), ('k6_http_req_duration_p99{level="$level"}', "p99")], "ms", 12),
    ts("status codes", [('sum(rate(k6_http_reqs_total{level="$level"}[1m])) by (status)', "{{status}}")], "reqps", 12, stacked=True),
    ts("VUs", [('k6_vus{level="$level"}', "vus")], "short", 12),
    ts("özel metrikler (ryw, normal client)", [('k6_ryw_violations_total{level="$level"}', "ryw violations"), ('k6_normal_client_latency_p99{level="$level"}', "normal p99")], "short", 12),
])

OUT.mkdir(exist_ok=True)
for f in OUT.glob("*.json"): f.unlink()
for name, d in D.items():
    (OUT / f"{name}.json").write_text(json.dumps(d, ensure_ascii=False, indent=1))
print(f"{len(D)} dashboard → {OUT}")
