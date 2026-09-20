# API kontratı — her seviyede aynı

Seviyeler arasında **API değişmez**; sonradan eklenen uçlar işaretlidir. Böylece aynı k6 senaryoları ve aynı
reproduce scriptleri 00'dan 14'e kadar aynı şekilde çalışır.

| Uç | Seviye | İstek | Yanıt |
|---|---|---|---|
| `POST /api/links` | 00+ | `{"url": "https://…"}` — header `X-Tenant-ID` (02–12; kimlik DEĞİLDİR) | `201 {"code","short_url","url"}` |
| `GET /{code}` | 00+ | — | 00: `301` · 01+: `302` + `Cache-Control: no-store` · `404` yoksa |
| `GET /api/links/{code}` | 00+ | — | `200 {"code","url","clicks","created_at"}` |
| `DELETE /api/links/{code}` | 00+ | — | `204` |
| `GET /api/links` | 02+ | `?limit=` | `200 {"links":[…]}` (tenant'a göre) |
| `GET /api/links/{code}/stats` | 05+ | — | `200 {"clicks", "by_day":[…]}` |
| `GET /healthz` | 01+ | — | `200` süreç canlı (liveness) |
| `GET /readyz` | 01+ | — | `200` trafik alabilir (readiness) — 10'dan itibaren **sadece kendi** durumu |
| `GET /metrics` | 01+ | — | Prometheus metin formatı |
| Kimlik | 13+ | `Authorization: Bearer <api-key>` | tenant key'den türer; `X-Tenant-ID` yok sayılır |

Hata gövdesi (01+): `{"error": "<kısa kod>", "request_id": "<id>"}`.

## Metrik adları — her seviyede aynı (dashboard'lar buna göre)

Bir seviyede metrik üretilmiyorsa panel boş kalır; README "Gözlemlenebilirlik" bölümü nedenini söyler.

| Metrik | Tip | Label'lar | Seviye |
|---|---|---|---|
| `http_requests_total` | counter | `route, method, code` (+`version` 12+, `tenant` 13+) | 01+ |
| `http_request_duration_seconds` | histogram | `route` | 01+ |
| `http_in_flight_requests` | gauge | — | 01+ |
| `http_panics_total` | counter | — | 01+ |
| `links_total` | gauge | — (bellek içi store'da pod başına) | 01+ |
| `redirect_total` | counter | `result=ok|not_found|gone` | 01+ |
| `create_total` | counter | `result=ok|collision|exhausted|invalid` | 01+ |
| `create_rejected_unsafe_total` | counter | `reason` | 01+ |
| `ratelimit_decisions_total` | counter | `decision=allow|reject, key_type` | 01+ |
| `ratelimit_errors_total` | counter | — | 08+ |
| `db_queries_total`, `db_query_duration_seconds` | counter, histogram | `op` | 02+ |
| `db_pool_acquire_duration_seconds`, `db_pool_empty_acquire_total` | histogram, counter | — | 02+ |
| `cache_ops_total` | counter | `layer=l1|l2, result=hit|miss|negative_hit` | 03+ |
| `cache_stampede_wait_total`, `cache_evictions_total{reason}`, `cache_entries`, `cache_errors_total{op}` | … | | 03+ |
| `analytics_events_total` | counter | `result=enqueued|dropped|written|write_error` | 05+ |
| `analytics_queue_depth`, `analytics_queue_capacity` | gauge | — | 05+ |
| `analytics_batch_duration_seconds` | histogram | — | 05+ |
| `producer_records_total{result}`, `producer_buffered_records` | counter, gauge | | 06+ |
| `consumer_records_total{result=ok|duplicate|dlq|error}`, `consumer_commits_total` | counter | | 06+ |
| `dependency_requests_total{dep,result}`, `dependency_request_duration_seconds{dep}` | counter, histogram | | 04+ |
| `retry_total{dep}`, `breaker_state{dep}`, `load_shed_total`, `degraded_mode{mode}` | … | | 10+ |
| `ryw_violations_total` | counter | — | 09+ |

**Her sayaç başlangıçta sıfırla kaydedilir** — "hiç olmadı" ile "raporlamıyor" ayırt edilebilsin (alarm kuralı yazılabilsin).
Kısa kod, URL, IP gibi **sınırsız değerler asla label olmaz** (P01-06, P11-06).
