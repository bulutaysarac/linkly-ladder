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
    t = {"datasource": DS, "expr": expr, "legendFormat": legend or "__auto", "refId": chr(65 + _uid[0] % 26)}
    # Gecikme histogramlarında exemplar AÇIK: 11+ bu noktalara trace kimliği iliştirir, tıklayınca Tempo açılır.
    if "http_request_duration_seconds_bucket" in expr:
        t["exemplar"] = True
    return t

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

# İşlemci, BİR ÇEKİRDEĞİN YÜZDESİ olarak gösterilir (top gibi): %100 = bir çekirdeğin tamamı,
# iki çekirdek kullanan süreç %200. Kubernetes'in birimiyle karşılığı: 50m = %5, 1 = %100.
CPU_PCT = "percent"

# SAYMA PANELLERİ: pod, restart, replika, kullanıcı gibi değerler tam sayıdır. Eksen tam sayı
# gösterir ve çizgi basamaklıdır: 1'den 0'a inen bir değer arada 0.5 olmaz, o anda iner.
COUNTS = {
    "Yeniden başlatma (toplam)", "Pod sayısı", "Yeniden başlatma sayısı",
    "Pod durumları", "Hazır pod adresi (endpoint) sayısı", "Goroutine sayısı",
    "Kayıtlı link sayısı (pod'a göre)", "Önbellekteki kayıt (pod'a göre)", "Kuyruk doluluğu (pod'a göre)",
    "Redis ayakta mı", "Broker ayakta mı", "Otomatik ölçekleyici: istenen / mevcut pod", "Yer bekleyen pod",
    "Düğüm başına pod", "Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)", "Şu an işlenen istek (pod'a göre)",
    "Dağıtım aşaması (Argo Rollouts)", "Sanal kullanıcı (zaman içinde)",
    "Sanal kullanıcı", "Açık bağlantı", "Şu an işlenen istek", "Önbellekteki kayıt", "Kayıtlı link sayısı",
}

def as_count(p):
    d = p["fieldConfig"]["defaults"]
    d["decimals"] = 0
    if p["type"] == "timeseries":
        d["min"] = 0
        d.setdefault("custom", {})["lineInterpolation"] = "stepAfter"
    return p

# EKSEN SIFIRDAN BAŞLAR. Grafana ekseni verinin aralığına sığdırır: 4.63 → 4.72 MiB'lik %2'lik
# oynama uçurum, 0.002 → 0.005 m'lik gürültü dalga gibi görünür. Büyüklük gösteren her panel
# 0'dan başlar; yalnızca 1'e yakın oranlar (küçük düşüşün kendisi haberdir) ve eksiye inebilen
# değerler yakınlaştırılır.
ZOOMED = {"Erişilebilirlik (5xx olmayan isteklerin oranı)", "Kalan hata bütçesi"}
# İşlemci panelleri en az %10'luk eksenle çizilir: boştaki binde birlik gürültü düz görünür,
# gerçek yük (yüzde onlar) eksenin kendisini büyütür.
CPU_SOFT_MAX = 10

def ts(title, exprs, unit="short", w=12, h=8, desc="", stacked=False):
    p = panel("timeseries", title, [target(e, l) for e, l in exprs], unit, w, h, desc)
    d = p["fieldConfig"]["defaults"]
    if stacked: d["custom"] = {"stacking": {"mode": "normal"}, "fillOpacity": 20}
    if title not in ZOOMED: d["min"] = 0
    if unit == CPU_PCT and "CPU" in title: d.setdefault("custom", {})["axisSoftMax"] = CPU_SOFT_MAX
    return as_count(p) if title in COUNTS else p

def stat(title, expr, unit="short", w=6, h=4, desc=""):
    p = panel("stat", title, [target(expr)], unit, w, h, desc)
    return as_count(p) if title in COUNTS else p

def threshold_pct(p, warn, crit):
    """0-100 ölçeği ve kesikli eşik çizgileri: 'sınıra ne kadar yakın' tek bakışta okunur."""
    d = p["fieldConfig"]["defaults"]
    d.update(min=0, max=100, thresholds={"mode": "absolute", "steps": [
        {"color": "green", "value": None}, {"color": "yellow", "value": warn}, {"color": "red", "value": crit}]})
    d.setdefault("custom", {})["thresholdsStyle"] = {"mode": "dashed"}
    return p

def reasons(p):
    """Değeri hep 1 olan 'sebep' serilerini çizgi yerine ad olarak göster: 'pod: Error'."""
    p["options"].update(textMode="name", graphMode="none", colorMode="background", justifyMode="center")
    p["fieldConfig"]["defaults"]["color"] = {"mode": "fixed", "fixedColor": "orange"}
    p["fieldConfig"]["overrides"] += [{"matcher": {"id": "byRegexp", "options": f".*: {r}"},
        "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
        for r, c in (("OOMKilled", "red"), ("Completed", "green"))]
    return p

def colors(p, by_name):
    """Seri adına sabit renk: aynı anlam her dashboard'da aynı renkte görünür."""
    p["fieldConfig"]["overrides"] += [{"matcher": {"id": "byName", "options": n},
        "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]} for n, c in by_name.items()]
    return p

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
# İki ayrı dışa aktarıcıdan biri: 02-08 postgres-exporter (pg_*), 09+ CloudNativePG (cnpg_*).
# `A or B`: hangisi varsa o çizilir — tek bir dışa aktarıcıya bağlı sorgu, diğer aralıkta boş kalır.
PG = lambda a, b: f'({a}) or ({b})'
# Postgres ve Redis pod'larının CPU'su: `image` filtresi ŞART, yoksa pod toplamı konteynerlerle
# birlikte ikinci kez sayılır (cAdvisor pod düzeyinde de bir seri üretir).
DBPODS = f'{APP},pod=~".*postgres.*|pg-[0-9]+|pg-pooler.*"'
REDISPODS = f'{APP},pod=~".*redis.*"'

D = {}

# ADLANDIRMA: başlıklar sade Türkçe; kısaltma yerine ne ölçtüğü. Her panelin (i) açıklaması üç
# soruyu cevaplar: bu ne · normali neye benzer · neye dikkat (hangi sorun). README'ler panelleri
# TAM başlığıyla anar; başlık değişirse tools/lint-grafana.py README'yi hata sayar.

D["00-overview"] = dashboard("overview", "00 · Overview (tüm seviyeler)", [
    text("**Merdivenin tamamı yan yana.** Her çizgi bir seviye (`lvl00` … `lvl14`). Uygulama metriği olmayan 00'da yalnızca pod ve yeniden başlatma satırları dolar. Bir seviyeyi ayrıntılı incelemek için diğer dashboard'lar."),
    ts("Erişilebilirlik (5xx olmayan isteklerin oranı)", [('1 - (sum(rate(http_requests_total{namespace=~"lvl.*",code=~"5.."}[2m])) by (namespace) / sum(rate(http_requests_total{namespace=~"lvl.*"}[2m])) by (namespace))', "{{namespace}}")], "percentunit", 12,
       desc="Uygulamanın kendi saydığı isteklerin yüzde kaçı sunucu hatası (5xx) DEĞİL. %100 = hiç hata yok. Ingress'in ürettiği hatalar burada görünmez; onlar için 15 · k6."),
    ts("İsteklerin %99'unun süresi (p99)", [('histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=~"lvl.*"}[2m])) by (le, namespace))', "{{namespace}}")], "s", 12,
       desc="İsteklerin %99'u bu süreden kısa sürdü. Ortalama değil 'yavaş uç': kullanıcıların şikâyet ettiği gecikme budur."),
    ts("Saniyedeki istek sayısı", [('sum(rate(http_requests_total{namespace=~"lvl.*"}[1m])) by (namespace)', "{{namespace}}")], "reqps", 8,
       desc="Uygulamanın saniyede cevapladığı istek. Yük verilmezken 0'a yakın."),
    ts("Yeniden başlatma (toplam)", [('sum(kube_pod_container_status_restarts_total{namespace=~"lvl.*"}) by (namespace)', "{{namespace}}")], "short", 8,
       desc="Seviyenin tüm konteynerlerinin kaç kez yeniden başladığı. Her artış bir çöküş ya da öldürme."),
    ts("Pod sayısı", [('count(kube_pod_info{namespace=~"lvl.*"}) by (namespace)', "{{namespace}}")], "short", 8,
       desc="Seviyede çalışan pod sayısı (uygulama + veritabanı + önbellek …)."),
    ts("İstemcinin gördüğü hata oranı (k6)", [('k6_http_req_failed_rate{level=~"lvl.*"}', "{{level}}")], "percentunit", 12,
       desc="Yük üreticisi k6'nın başarısız saydığı isteklerin oranı. Uygulama hiç görmese bile (ingress'in cevabı) burada sayılır."),
    ts("İstemcinin gördüğü p99 süre (k6)", [('k6_http_req_duration_p99{level=~"lvl.*"}', "{{level}}")], "ms", 12,
       desc="İstemci tarafında ölçülen gecikme: ağ + ingress + uygulama."),
], with_level=False)

D["01-pods-resources"] = dashboard("pods", "01 · Pods & Resources", [
    text("Pod'lar yaşıyor mu, ne kadar kaynak yiyor? Veri uygulamadan değil Kubernetes'ten gelir; bu yüzden **00'da da doludur** (Go çalışma zamanı satırları 01'den itibaren). Her panelin (i) simgesi ne göstereceğini anlatır."),
    ts("CPU kullanımı (bir çekirdeğin %'si)", [(f'sum(rate(container_cpu_usage_seconds_total{{{APP}}}[2m])) by (pod) * 100', "{{pod}}")], CPU_PCT, 8,
       desc="Pod başına kullanılan işlemci, bir çekirdeğin yüzdesi: %100 = bir çekirdeğin tamamı, iki çekirdek kullanan pod %200. Kubernetes birimiyle 50m = %5. Yükle birlikte yükselir; boşta %0 civarı normaldir. Son 2 dakikanın ortalamasıdır ve küme metrikleri 30 sn'de bir toplanır: 30 sn'den kısa yaşayan bir konteynerin CPU'su hiç görünmez."),
    ts("CPU kısıtlama (throttling)", [(f'sum(rate(container_cpu_cfs_throttled_seconds_total{{{APP}}}[2m])) by (pod)', "{{pod}}")], "short", 8,
       desc="Pod CPU sınırına dayandığı için bekletildiği süre (saniye/saniye). UYARI: bu kurulumda (cgroup v1) bu metrik üretilmiyor — panel boş kalır (P07-04, ortam sınırı)."),
    ts("Bellek kullanımı", [(f'sum by (pod) (container_memory_working_set_bytes{{{APP}}})', "{{pod}}")], "bytes", 8,
       desc="Pod'un gerçekten kullandığı bellek (Kubernetes'te 'working set'). Eksen kullanıma göre ölçeklenir, büyüme şekli burada okunur; sınıra ne kadar yakın olduğu 'Bellek: sınırın yüzde kaçı' panelinde."),
    threshold_pct(ts("Bellek: sınırın yüzde kaçı", [(f'100 * sum by (pod) (container_memory_working_set_bytes{{{APP}}}) / sum by (pod) (kube_pod_container_resource_limits{{{NS},resource="memory"}})', "{{pod}}")], "percent", 8,
       desc="Kullanılan bellek, pod'un bellek sınırının yüzde kaçı. %100'e değen konteyner OOMKilled ile öldürülür (bkz. 'Son sonlanma nedeni'); sarı çizgi %80, kırmızı %100. Sınır tanımlı değilse panel boş kalır."), 80, 100),
    ts("Yeniden başlatma sayısı", [(f'kube_pod_container_status_restarts_total{{{NS}}}', "{{pod}}")], "short", 8,
       desc="Konteynerin kaç kez yeniden başladığı. Basamak basamak artıyorsa pod ölüp diriliyor; sebebi yandaki panelde ve pod'un --previous logunda."),
    reasons(panel("stat", "Son sonlanma nedeni", [target(f'kube_pod_container_status_last_terminated_reason{{{NS}}}', "{{pod}}: {{reason}}")], "short", 8, 8,
       desc="Her pod en son NEDEN öldü, düz metin: Error = süreç kendisi çöktü (turuncu) · OOMKilled = bellek sınırı aşıldı (kırmızı) · Completed = düzgün kapandı, ör. rollout ya da silme (yeşil). Hiç ölmemiş pod burada görünmez.")),
    colors(ts("Pod durumları", [(f'sum(kube_pod_status_phase{{{NS}}}) by (phase) > 0', "{{phase}}")], "short", 8,
       desc="Kaç pod hangi aşamada; yalnızca o an pod'u olan aşamalar çizilir: Running (çalışıyor) · Pending (başlamayı bekliyor) · Failed · Succeeded (iş bitti, ör. migration Job'ı). Dikkat: çöküp yeniden başlatılan (CrashLoopBackOff) bir pod burada hâlâ Running görünür — aşama pod'un, çöküş konteynerin durumudur; çöküşü 'Yeniden başlatma sayısı' ve 'Son sonlanma nedeni' gösterir."),
       {"Running": "green", "Pending": "yellow", "Failed": "red", "Succeeded": "blue", "Unknown": "purple"}),
    ts("Goroutine sayısı", [(f'go_goroutines{{{NS}}}', "{{pod}}")], "short", 8,
       desc="Go uygulamasının eşzamanlı iş parçacığı sayısı (01+). Sürekli artıyorsa asılı kalan bağlantılar/istekler birikiyor."),
    ts("Heap bellek (Go)", [(f'go_memstats_heap_alloc_bytes{{{NS}}}', "{{pod}}")], "bytes", 8,
       desc="Go'nun ayırdığı nesne belleği (01+). 'Bellek kullanımı'nın uygulama içindeki kısmı."),
    ts("Çöp toplama süresi (Go)", [(f'rate(go_gc_duration_seconds_sum{{{NS}}}[2m])', "{{pod}}")], "short", 8,
       desc="Saniyede çöp toplamaya harcanan süre (01+). Bellek sınırına yaklaşınca yükselir ve CPU'yu yer."),
    ts("Hazır pod adresi (endpoint) sayısı", [(f'sum(kube_endpointslice_endpoints{{{NS},ready="true"}}) by (endpointslice) or (sum(kube_endpointslice_endpoints{{{NS}}}) by (endpointslice) * 0)', "{{endpointslice}}")], "short", 12,
       desc="Servisin trafik gönderebileceği HAZIR pod sayısı. 0 = istekler gidecek yer bulamaz, ingress anında 503 döner (pod çöküşü, readiness hatası)."),
    ts("Ağ trafiği (gelen / giden)", [(f'sum(rate(container_network_receive_bytes_total{{{NS}}}[2m])) by (pod)', "gelen: {{pod}}"), (f'sum(rate(container_network_transmit_bytes_total{{{NS}}}[2m])) by (pod)', "giden: {{pod}}")], "Bps", 12,
       desc="Pod'a gelen (istekler) ve pod'dan giden (cevaplar) veri, bayt/saniye. Yük sırasında tepe yapar; yük yokken ~0."),
])

D["02-app-red"] = dashboard("app-red", "02 · App RED", [
    text("**R**ate (kaç istek) · **E**rrors (kaçı hatalı) · **D**uration (ne kadar sürüyor) — uygulamanın KENDİ saydığı. 01'den itibaren dolar; **00'da boştur** (`/metrics` yok, P00-09). İstemcinin gördüğüyle karşılaştır: 15 · k6."),
    stat("Saniyedeki istek", RATE(""), "reqps", desc="Uygulamanın son 1 dakikada saniyede cevapladığı istek."),
    stat("Sunucu hatası oranı (5xx)", RATE(',code=~"5.."') + " / " + RATE(""), "percentunit", desc="İsteklerin yüzde kaçı 5xx (sunucu hatası) ile döndü."),
    stat("p99 süre", P(0.99), "s", desc="İsteklerin %99'u bu süreden kısa."),
    stat("Şu an işlenen istek", f'sum(http_in_flight_requests{{{NS}}})', "short", desc="Şu anda cevabı bekleyen istek sayısı. Bağımlılık yavaşlarsa birikir."),
    ts("İstek / saniye (uç noktaya göre)", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (route)', "{{route}}")], "reqps", 12, stacked=True,
       desc="/{code} = kısa link yönlendirmesi · /api/links = oluşturma/listeleme."),
    ts("İstek / saniye (durum koduna göre)", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (code)', "{{code}}")], "reqps", 12, stacked=True,
       desc="302 = yönlendirme · 201 = oluşturuldu · 404 = yok · 429 = hız sınırı · 5xx = sunucu hatası. Kodların anlamı: kök README → Grafana'yı okumak."),
    ts("Gecikme (p50 / p95 / p99)", [(P(0.5), "p50 (tipik)"), (P(0.95), "p95"), (P(0.99), "p99 (yavaş uç)")], "s", 12,
       desc="p50 = isteklerin yarısı bundan hızlı; p99 = %99'u. p50 düşük ama p99 yüksekse bazı istekler takılıyor."),
    ts("p99 süre (uç noktaya göre)", [(P(0.99, by=", route"), "{{route}}")], "s", 12, desc="Hangi uç nokta yavaş?"),
    ts("5xx (uç noktaya göre)", [(f'sum(rate(http_requests_total{{{NS},code=~"5.."}}[1m])) by (route)', "{{route}}")], "reqps", 8, desc="Sunucu hataları hangi uç noktada?"),
    ts("4xx (koda göre)", [(f'sum(rate(http_requests_total{{{NS},code=~"4.."}}[1m])) by (code)', "{{code}}")], "reqps", 8, desc="İstemci hataları: 400 geçersiz istek · 401 kimlik yok · 404 yok · 429 hız sınırı."),
    ts("Panik / zaman aşımı", [(f'sum(rate(http_panics_total{{{NS}}}[1m]))', "panik"), (f'sum(rate(http_requests_total{{{NS},code="503",route="timeout"}}[1m]))', "zaman aşımı")], "reqps", 8,
       desc="Panik = kodda yakalanan çökme; zaman aşımı = istek süre bütçesini aştı."),
    ts("İstek / saniye (pod'a göre)", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (pod)', "{{pod}}")], "reqps", 12, desc="Yük pod'lara eşit dağılıyor mu?"),
    ts("p99 süre (pod'a göre)", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, pod))', "{{pod}}")], "s", 12, desc="Tek bir pod mu yavaş?"),
])

D["03-app-business"] = dashboard("app-business", "03 · App Business", [
    text("İş sayıları: kaç link var, yönlendirmeler ne sonuçlandı, oluşturma başarılı mı, güvenlik reddi, read-your-writes. 01'den itibaren dolar."),
    stat("Kayıtlı link sayısı", f'sum(links_total{{{NS}}})', desc="Uygulamanın bildiği link sayısı. 02 öncesi bellekte tutulur: pod yeniden başlayınca 0'a düşer (P01-01)."),
    stat("Başarılı yönlendirme / sn", f'sum(rate(redirect_total{{{NS},result="ok"}}[1m]))', "reqps", desc="Kısa link bulundu ve yönlendirildi."),
    stat("Bulunamayan link / sn (404)", f'sum(rate(redirect_total{{{NS},result="not_found"}}[1m]))', "reqps", desc="İstenen kısa kod yok."),
    stat("Başarılı oluşturma / sn", f'sum(rate(create_total{{{NS},result="ok"}}[1m]))', "reqps", desc="Yeni kısa link oluşturuldu."),
    ts("Yönlendirme sonuçları", [(f'sum(rate(redirect_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True,
       desc="ok = bulundu · not_found = yok · error = arka plan hatası."),
    ts("404 (pod'a göre)", [(f'sum(rate(redirect_total{{{NS},result="not_found"}}[1m])) by (pod)', "{{pod}}")], "reqps", 12,
       desc="Hangi pod 'yok' diyor? Bellek içi depo + birden çok pod'da her pod yalnız kendi linklerini bilir (P01-02)."),
    ts("Oluşturma sonuçları", [(f'sum(rate(create_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True,
       desc="ok · collision = üretilen kod zaten vardı · exhausted = boş kod bulunamadı · rejected = geçersiz URL."),
    ts("Kayıtlı link sayısı (pod'a göre)", [(f'links_total{{{NS}}}', "{{pod}}")], "short", 12, desc="Pod'lar aynı sayıyı mı görüyor? Farklıysa her pod kendi deposunu tutuyor."),
    ts("Güvenlik reddi (tehlikeli URL)", [(f'sum(rate(create_rejected_unsafe_total{{{NS}}}[1m])) by (reason)', "{{reason}}")], "reqps", 8,
       desc="Reddedilen URL'ler ve sebebi (javascript:, iç ağ adresi …)."),
    ts("Read-your-writes ihlali", [(f'sum(rate(ryw_violations_total{{{NS}}}[1m]))', "ihlal")], "reqps", 8,
       desc="Oluşturduğun linki hemen okuyamadın (replika henüz görmedi). 09+ (P09-01)."),
    ts("İstek / kiracı", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (tenant)', "{{tenant}}")], "reqps", 8,
       desc="Kiracı (tenant) başına istek — yalnızca TRAP_TENANT_LABEL açıkken dolar (kardinalite dersi, 11/13)."),
])

D["04-cache"] = dashboard("cache", "04 · Cache", [
    text("Önbellek: 03 pod içi (L1) · 04 Redis (L2) · 14 ikisi birden. İsabet oranı **pod bazında** — P03-04'ü burada görürsün."),
    stat("İsabet oranı (toplam)", f'sum(rate(cache_ops_total{{{NS},result=~"hit|negative_hit"}}[2m])) / sum(rate(cache_ops_total{{{NS}}}[2m]))', "percentunit",
         desc="İsteklerin yüzde kaçı önbellekten cevaplandı (veritabanına gitmeden)."),
    stat("Iska / sn", f'sum(rate(cache_ops_total{{{NS},result="miss"}}[1m]))', "reqps", desc="Önbellekte olmadığı için veritabanına giden istek."),
    stat("Bekletilen eşzamanlı ıska / sn", f'sum(rate(cache_stampede_wait_total{{{NS}}}[1m]))', "reqps",
         desc="Aynı anahtar için DB'ye gitmek yerine ilk isteğin sonucunu bekleyenler (singleflight). Yükselmesi hata değil: izdiham koruması çalışıyor."),
    stat("Önbellekteki kayıt", f'sum(cache_entries{{{NS}}})', desc="Tüm pod'lardaki önbellek kayıtlarının toplamı."),
    ts("İsabet oranı (pod'a göre)", [(f'sum(rate(cache_ops_total{{{NS},result=~"hit|negative_hit"}}[2m])) by (pod) / sum(rate(cache_ops_total{{{NS}}}[2m])) by (pod)', "{{pod}}")], "percentunit", 12,
       desc="Her pod'un kendi isabet oranı. Yeni açılan pod soğuk başlar (düşük)."),
    ts("Önbellek işlemleri (katman ve sonuca göre)", [(f'sum(rate(cache_ops_total{{{NS}}}[1m])) by (layer, result)', "{{layer}} {{result}}")], "reqps", 12, stacked=True,
       desc="l1 = pod içi · l2 = Redis; hit = bulundu · miss = yok · negative_hit = 'bu kod yok' cevabı önbellekten."),
    ts("Önbellek ıskası ve veritabanı sorguları", [(f'sum(rate(cache_ops_total{{{NS},result="miss"}}[1m]))', "önbellek ıskası"), (f'sum(rate(db_queries_total{{{NS}}}[1m]))', "veritabanı sorgusu (hepsi)")], "reqps", 12,
       desc="İkisi birbirine yakın gitmeli. DB çizgisi TÜM sorguları sayar (tıklama güncellemesi dahil); yalnız okuma için 05 · Postgres → 'Veritabanı sorguları (türe göre)' → get."),
    ts("Önbellekten çıkarılma sebepleri", [(f'sum(rate(cache_evictions_total{{{NS}}}[1m])) by (reason)', "{{reason}}")], "reqps", 12,
       desc="capacity = yer açmak için atıldı · ttl = süresi doldu · invalidate = silindiği için temizlendi."),
    ts("Önbellekteki kayıt (pod'a göre)", [(f'cache_entries{{{NS}}}', "{{pod}}")], "short", 12, desc="Her pod aynı içeriği ayrı ayrı tutuyor mu? (P03-03)"),
    ts("Önbellek yazma/okuma hatası", [(f'sum(rate(cache_errors_total{{{NS}}}[1m])) by (op)', "{{op}}")], "reqps", 12, desc="Redis dolunca SET hataları (P04-06)."),
])

D["05-postgres"] = dashboard("postgres", "05 · Postgres", [
    text("Veritabanı. 02-08: postgres-exporter · 09+: CloudNativePG (panellerin çoğu ikisinden hangisi varsa onu çizer; ölü satır, tablo tarama ve kilit yalnızca 02-08'de). Uygulama tarafı: bağlantı havuzu ve sorgular."),
    stat("Açık bağlantı", PG(f'sum(pg_stat_activity_count{{{NS}}})', f'sum(cnpg_backends_total{{{NS}}})'), desc="Veritabanına açık bağlantı sayısı."),
    stat("Bağlantı üst sınırı", PG(f'max(pg_settings_max_connections{{{NS}}})', f'max(cnpg_pg_settings_setting{{{NS},name="max_connections"}})'), desc="Postgres'in kabul ettiği en fazla bağlantı (max_connections)."),
    stat("İşlem / sn", PG(f'sum(rate(pg_stat_database_xact_commit{{{NS}}}[1m]))', f'sum(rate(cnpg_pg_stat_database_xact_commit{{{NS}}}[1m]))'), "ops", desc="Saniyede tamamlanan işlem (transaction)."),
    stat("Bellekten okuma oranı", PG(f'sum(rate(pg_stat_database_blks_hit{{{NS}}}[2m])) / (sum(rate(pg_stat_database_blks_hit{{{NS}}}[2m])) + sum(rate(pg_stat_database_blks_read{{{NS}}}[2m])))',
                                     f'sum(rate(cnpg_pg_stat_database_blks_hit{{{NS}}}[2m])) / (sum(rate(cnpg_pg_stat_database_blks_hit{{{NS}}}[2m])) + sum(rate(cnpg_pg_stat_database_blks_read{{{NS}}}[2m])))'), "percentunit",
         desc="Okunan blokların yüzde kaçı diskten değil Postgres'in belleğinden geldi. %99+ normal."),
    ts("Bağlantılar ve üst sınır", [(PG(f'sum(pg_stat_activity_count{{{NS}}}) by (state)', f'sum(cnpg_backends_total{{{NS}}}) by (state)'), "{{state}}"),
                                   (PG(f'max(pg_settings_max_connections{{{NS}}})', f'max(cnpg_pg_settings_setting{{{NS},name="max_connections"}})'), "üst sınır")], "short", 12, stacked=False,
       desc="Duruma göre bağlantılar (active = sorgu çalıştırıyor · idle = boşta) ve üst sınır. Sınıra yapışınca yeni bağlantılar 'too many clients' ile reddedilir (P02-02)."),
    ts("Veritabanı CPU", [(f'sum(rate(container_cpu_usage_seconds_total{{{DBPODS}}}[2m])) by (pod) * 100', "{{pod}}")], CPU_PCT, 12,
       desc="Postgres (ve 09+'da bağlantı havuzu) pod'larının işlemci kullanımı, bir çekirdeğin yüzdesi (%100 = bir çekirdek). Her yönlendirme DB'ye gidiyorsa yükle birlikte tırmanır (P02-01)."),
    ts("Uygulama havuzu: bağlantı bekleme (p99)", [(f'histogram_quantile(0.99, sum(rate(db_pool_acquire_duration_seconds_bucket{{{NS}}}[1m])) by (le, pod))', "{{pod}}")], "s", 12,
       desc="Uygulamanın havuzdan boş bağlantı almak için beklediği süre. Havuz doluysa büyür."),
    ts("Uygulama havuzu: boş bağlantı bulunamadı / sn", [(f'sum(rate(db_pool_empty_acquire_total{{{NS}}}[1m])) by (pod)', "{{pod}}")], "reqps", 12,
       desc="Havuzda boş bağlantı olmadığı için beklemek zorunda kalınan istek."),
    ts("Veritabanı sorguları (türe göre)", [(f'sum(rate(db_queries_total{{{NS}}}[1m])) by (op)', "{{op}}")], "reqps", 12, stacked=True,
       desc="get = link okuma · create = oluşturma · increment_clicks / write_clicks = tıklama yazma · list = listeleme."),
    ts("Sorgu süresi p99 (türe göre)", [(f'histogram_quantile(0.99, sum(rate(db_query_duration_seconds_bucket{{{NS}}}[1m])) by (le, op))', "{{op}}")], "s", 12, desc="Hangi sorgu türü yavaş?"),
    ts("Tablo tarama: tam tarama / indeksli", [(f'sum(rate(pg_stat_user_tables_seq_scan{{{NS}}}[1m])) by (relname)', "tam tarama: {{relname}}"), (f'sum(rate(pg_stat_user_tables_idx_scan{{{NS}}}[1m])) by (relname)', "indeksli: {{relname}}")], "ops", 12,
       desc="Tam tarama = tablonun her satırını okumak (indeks yok ya da kullanılmıyor, P02-05). 02-08'de dolu; 09+'da boş (CNPG bu metriği yayınlamaz)."),
    ts("Kilitler (türe göre)", [(f'sum(pg_locks_count{{{NS}}}) by (mode)', "{{mode}}")], "short", 12, desc="Tutulan kilitler. Popüler bir linkin satırına çok yazma = kilit kuyruğu (P02-08). 02-08'de dolu; 09+'da boş."),
    ts("Ölü satırlar (vacuum bekleyen)", [(f'sum(pg_stat_user_tables_n_dead_tup{{{NS}}}) by (relname)', "{{relname}}")], "short", 12, desc="Silinmiş/güncellenmiş ama henüz temizlenmemiş satırlar. 02-08'de dolu; 09+'da boş."),
    ts("Replikasyon gecikmesi", [(f'max(cnpg_pg_replication_lag{{{NS}}}) by (pod)', "{{pod}}"), (f'max(pg_replication_lag_seconds{{{NS}}}) by (pod)', "{{pod}}")], "s", 12,
       desc="Replikanın primary'nin kaç saniye gerisinde olduğu (09+). Yüksekse replikadan okunan veri eski (P09-01)."),
])

D["06-redis"] = dashboard("redis", "06 · Redis", [
    text("Paylaşılan önbellek (04+). Redis'in kendi sayıları (redis_exporter)."),
    stat("Komut / sn", f'sum(rate(redis_commands_processed_total{{{NS}}}[1m]))', "ops", desc="Redis'in saniyede işlediği komut."),
    stat("Bağlı istemci", f'sum(redis_connected_clients{{{NS}}})', desc="Redis'e bağlı uygulama bağlantısı."),
    stat("Kullanılan bellek", f'sum(redis_memory_used_bytes{{{NS}}})', "bytes", desc="Redis'in kullandığı bellek."),
    stat("Bellek üst sınırı", f'max(redis_memory_max_bytes{{{NS}}})', "bytes", desc="maxmemory ayarı. Dolunca politika devreye girer (sil ya da reddet)."),
    ts("Redis'te bulundu / bulunamadı", [(f'sum(rate(redis_keyspace_hits_total{{{NS}}}[1m]))', "bulundu"), (f'sum(rate(redis_keyspace_misses_total{{{NS}}}[1m]))', "bulunamadı")], "ops", 12, stacked=True,
       desc="Redis'e sorulan anahtarların kaçı vardı."),
    ts("Bellek ve üst sınır", [(f'sum(redis_memory_used_bytes{{{NS}}})', "kullanılan"), (f'max(redis_memory_max_bytes{{{NS}}})', "üst sınır")], "bytes", 12, desc="Kullanım sınıra değince yeni yazmalar reddedilebilir (P04-06)."),
    ts("Silinen / süresi dolan anahtar", [(f'sum(rate(redis_evicted_keys_total{{{NS}}}[1m]))', "yer açmak için silindi"), (f'sum(rate(redis_expired_keys_total{{{NS}}}[1m]))', "süresi doldu")], "ops", 12,
       desc="Yer açmak için atılanlar ve TTL'i dolanlar."),
    ts("Redis CPU", [(f'sum(rate(container_cpu_usage_seconds_total{{{REDISPODS}}}[2m])) by (pod) * 100', "{{pod}}")], CPU_PCT, 12,
       desc="Redis pod'unun işlemci kullanımı, bir çekirdeğin yüzdesi. Redis komutları tek çekirdekte işler: %100'e yaklaşınca tavandadır (sıcak anahtar, P04-03)."),
    ts("Komutlar (türe göre)", [(f'sum(rate(redis_commands_total{{{NS}}}[1m])) by (cmd)', "{{cmd}}")], "ops", 12, stacked=True,
       desc="get / set / del … KEYS görünüyorsa alarm: tüm anahtarları tarar ve Redis'i kilitler (P04-07)."),
    ts("Uygulama → Redis gecikmesi (p99)", [(f'histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{{{NS},dep="redis"}}[1m])) by (le))', "p99")], "s", 12,
       desc="Uygulamanın gözünden Redis çağrılarının süresi. Bu metrik 10'dan önce yok (04-09'da boş)."),
    ts("Redis ayakta mı", [(f'redis_up{{{NS}}}', "{{pod}}")], "short", 12, desc="1 = ayakta. Redis pod'u ölünce exporter de ölür: 0 değil BOŞLUK görürsün (P04-01)."),
])

D["07-analytics"] = dashboard("analytics", "07 · Analytics", [
    text("Tıklama sayma: 05 süreç içi kuyruk · 06+ olay akışı (broker). **k6'nın gönderdiği yönlendirme − veritabanına yazılan tıklama** farkı kaybolan tıklamalardır."),
    stat("Kuyruğa alınan / sn", f'sum(rate(analytics_events_total{{{NS},result="enqueued"}}[1m]))', "reqps", desc="Kaydedilmek üzere kuyruğa giren tıklama."),
    stat("Atılan / sn", f'sum(rate(analytics_events_total{{{NS},result="dropped"}}[1m]))', "reqps", desc="Kuyruk dolu olduğu için ATILAN tıklama — kayıp."),
    stat("Yazılan / sn", f'sum(rate(analytics_events_total{{{NS},result="written"}}[1m]))', "reqps", desc="Veritabanına yazılan tıklama."),
    stat("Kuyrukta bekleyen", f'sum(analytics_queue_depth{{{NS}}})', desc="Henüz yazılmamış tıklama."),
    ts("Tıklama olayları (sonuca göre)", [(f'sum(rate(analytics_events_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True,
       desc="enqueued = kuyruğa alındı · written = yazıldı · dropped = atıldı."),
    ts("Kuyruk doluluğu (pod'a göre)", [(f'analytics_queue_depth{{{NS}}}', "{{pod}}"), (f'max(analytics_queue_capacity{{{NS}}})', "kapasite")], "short", 12,
       desc="Kuyruk kapasiteye dayanırsa yeni tıklamalar atılır ya da istek bekler (P05-02)."),
    ts("Kaybolan tıklamalar: k6'nın gönderdiği − veritabanına yazılan", [(f'sum(increase(k6_http_reqs_total{{level="$level",name="GET /{{code}}"}}[$__range]))', "k6'nın gönderdiği yönlendirme"), (f'sum(increase(analytics_events_total{{{NS},result="written"}}[$__range]))', "veritabanına yazılan tıklama")], "short", 24, h=9,
       desc="İki çizgi arasındaki fark = kaybolan tıklamalar (P05-01). Yalnızca yük k6 ile verildiyse anlamlı; curl ile verilen tıklamalar k6 çizgisinde yoktur."),
    ts("Toplu yazma süresi (p99)", [(f'histogram_quantile(0.99, sum(rate(analytics_batch_duration_seconds_bucket{{{NS}}}[1m])) by (le))', "p99")], "s", 12, desc="Birikmiş tıklamaları tek seferde yazmanın süresi."),
    ts("İstatistik ucu süresi (p99)", [(P(0.99, by=", route").replace(f'{{{NS}}}', f'{{{NS},route="/api/links/{{code}}/stats"}}'), "stats")], "s", 12,
       desc="GET /api/links/{code}/stats süresi. Tıklama sayısı her istekte baştan sayılırsa link büyüdükçe yavaşlar (P05-04)."),
])

D["08-stream"] = dashboard("stream", "08 · Stream (Redpanda)", [
    text("Olay akışı (06+): üretici tamponu, tüketici gecikmesi (lag), tekrar işlenen ve ölü mektup kutusuna (DLQ) giden kayıtlar."),
    stat("Üretilen kayıt / sn", f'sum(rate(producer_records_total{{{NS},result="ok"}}[1m]))', "reqps", desc="Broker'a başarıyla gönderilen tıklama olayı."),
    stat("Üretici tamponunda bekleyen", f'sum(producer_buffered_records{{{NS}}})', desc="Gönderilmeyi bekleyen kayıt. Broker yavaş/kapalıysa birikir."),
    stat("Tüketici gecikmesi (en büyük)", f'max(redpanda_kafka_max_offset{{{NS}}} - on(redpanda_topic, redpanda_partition) group_left redpanda_kafka_consumer_group_committed_offset{{{NS}}})',
         desc="Tüketicinin henüz işlemediği kayıt sayısı (lag). Sürekli büyüyorsa tüketici yetişemiyor."),
    stat("Ölü mektup kutusuna giden / sn", f'sum(rate(consumer_records_total{{{NS},result="dlq"}}[1m]))', "reqps", desc="İşlenemeyip ayrı bir konuya (DLQ) konan bozuk kayıt."),
    ts("Tüketici gecikmesi (bölüme göre)", [(f'sum(redpanda_kafka_max_offset{{{NS}}} - on(redpanda_topic, redpanda_partition) group_left redpanda_kafka_consumer_group_committed_offset{{{NS}}}) by (redpanda_partition)', "bölüm {{redpanda_partition}}")], "short", 12,
       desc="Her bölüm (partition) için işlenmemiş kayıt. Tek bölüm büyüyorsa yük dengesiz (P06-02/03)."),
    ts("Tüketilen kayıtlar (sonuca göre)", [(f'sum(rate(consumer_records_total{{{NS}}}[1m])) by (result)', "{{result}}")], "reqps", 12, stacked=True,
       desc="ok = işlendi · duplicate = daha önce işlenmişti (tekrar teslim, P06-01) · dlq = bozuk · error = hata."),
    ts("Üretici tamponu ve atılanlar", [(f'sum(producer_buffered_records{{{NS}}}) by (pod)', "tamponda: {{pod}}"), (f'sum(rate(producer_records_total{{{NS},result="dropped"}}[1m]))', "atılan / sn")], "short", 12,
       desc="Broker kapalıyken tampon dolar; dolunca kayıtlar atılır (P06-05)."),
    ts("Onaylama / sn ve tüketici pod sayısı", [(f'sum(rate(consumer_commits_total{{{NS}}}[1m]))', "onaylama / sn"), (f'count(kube_pod_info{{{NS},pod=~".*analytics.*"}})', "tüketici pod")], "short", 12,
       desc="Tüketicinin 'buraya kadar işledim' deme (commit) hızı ve kaç tüketici pod'u var."),
    ts("Broker ayakta mı", [(f'up{{{NS},job=~".*redpanda.*"}}', "{{pod}}")], "short", 12, desc="1 = Prometheus broker'a ulaşabiliyor."),
    ts("Üretilen ve tüketilen olaylar (toplam)", [(f'sum(increase(producer_records_total{{{NS},result="ok"}}[$__range]))', "üretilen"), (f'sum(increase(consumer_records_total{{{NS},result="ok"}}[$__range]))', "tüketilen")], "short", 12,
       desc="Seçili zaman aralığında üretilen ve tüketilen olay. Üst üste binmeli; tüketilen geride kalıyorsa lag var."),
])

D["09-autoscaling"] = dashboard("autoscaling", "09 · Autoscaling", [
    text("Otomatik ölçekleme (07+): HPA/KEDA ne istedi, ne oldu? Yer bekleyen pod'lar; düğüm kapasitesi."),
    ts("Otomatik ölçekleyici: istenen / mevcut pod", [(f'kube_horizontalpodautoscaler_status_desired_replicas{{{NS}}}', "istenen: {{horizontalpodautoscaler}}"), (f'kube_horizontalpodautoscaler_status_current_replicas{{{NS}}}', "mevcut: {{horizontalpodautoscaler}}"), (f'kube_horizontalpodautoscaler_spec_max_replicas{{{NS}}}', "en fazla: {{horizontalpodautoscaler}}")], "short", 12,
       desc="Otomatik ölçekleyicinin istediği ve gerçekten çalışan pod sayısı. 'mevcut' 'istenen'in gerisinde kalıyorsa gecikme (P07-01)."),
    ts("İstek / sn ve pod sayısı", [(RATE(""), "istek / sn"), (f'count(kube_pod_info{{{NS}}})', "pod sayısı")], "short", 12, desc="Yük artınca pod sayısı arkasından geliyor mu?"),
    ts("Yer bekleyen pod", [(f'sum(kube_pod_status_phase{{{NS},phase="Pending"}})', "bekleyen")], "short", 8, desc="Düğümlerde yer olmadığı için başlayamayan pod (P07-05)."),
    ts("Düğüm CPU: ayrılabilir / istenen", [('sum(kube_node_status_allocatable{resource="cpu"})', "ayrılabilir"), ('sum(kube_pod_container_resource_requests{resource="cpu"})', "pod'ların istediği")], "short", 8,
       desc="Kümede ayrılabilir işlemci ve pod'ların rezerve ettiği. İkisi birleşince yeni pod'lar Pending'de kalır."),
    ts("p99 süre (pod'a göre; yeni pod soğuk)", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, pod))', "{{pod}}")], "s", 8,
       desc="Yeni açılan pod'un ilk istekleri yavaştır (önbellek boş, bağlantılar yeni, P07-03)."),
    ts("Düğüm başına pod", [(f'count(kube_pod_info{{{NS}}}) by (node)', "{{node}}")], "short", 12, desc="Pod'lar hangi düğümde? Hepsi aynı düğümdeyse o düğüm düşünce hepsi gider (P07-07)."),
    ts("KEDA ölçekleme ölçüsü", [(f'keda_scaler_metrics_value{{{NS}}}', "{{scaledObject}} {{metric}}")], "short", 12, desc="KEDA'nın ölçekleme kararında kullandığı değer (ör. tüketici gecikmesi)."),
])

D["10-ratelimit"] = dashboard("ratelimit", "10 · Rate limit", [
    text("Hız sınırı: 01 pod içi (IP başına) · 08 Redis'te paylaşılan. Normal kullanıcı, kötü niyetli kullanıcıdan etkileniyor mu?"),
    stat("İzin verilen / sn", f'sum(rate(ratelimit_decisions_total{{{NS},decision="allow"}}[1m]))', "reqps", desc="Sınırdan geçen istek."),
    stat("Reddedilen / sn", f'sum(rate(ratelimit_decisions_total{{{NS},decision="reject"}}[1m]))', "reqps", desc="429 ile reddedilen istek."),
    stat("429 oranı", RATE(',code="429"') + " / " + RATE(""), "percentunit", desc="Tüm isteklerin yüzde kaçı hız sınırına takıldı."),
    stat("Sınırlayıcı arka uç hatası / sn", f'sum(rate(ratelimit_errors_total{{{NS}}}[1m]))', "reqps",
         desc="Sınırlayıcının Redis'e ulaşamadığı istek. Bu durumda ya herkes geçer (fail-open) ya kimse (fail-closed) — P08-01."),
    ts("Kararlar (anahtar türüne göre)", [(f'sum(rate(ratelimit_decisions_total{{{NS}}}[1m])) by (key_type, decision)', "{{key_type}} {{decision}}")], "reqps", 12, stacked=True,
       desc="ip / tenant = neye göre sınırlandı · allow/reject · exempt = yük testi muafiyeti."),
    ts("İzin verilen (pod'a göre)", [(f'sum(rate(ratelimit_decisions_total{{{NS},decision="allow"}}[1m])) by (pod)', "{{pod}}")], "reqps", 12,
       desc="Pod içi sınırlayıcıda her pod kendi sınırını uygular: N pod = N kat izin (P02-04)."),
    ts("Normal ve kötü niyetli kullanıcının gecikmesi (k6)", [('k6_normal_client_latency_p99{level="$level"}', "normal kullanıcı p99"), ('k6_http_req_duration_p99{level="$level",scenario="abuser"}', "kötü niyetli kullanıcı p99")], "ms", 12,
       desc="Kötü niyetli kullanıcı yüklenirken normal kullanıcının gecikmesi artıyor mu? (P08-06)"),
    ts("Sınırdan geçen istek / sn (10 sn çözünürlük)", [(f'sum(rate(http_requests_total{{{NS},code!="429",route="/{{code}}"}}[10s]))', "kabul edilen")], "reqps", 12,
       desc="Sınırdan geçen yönlendirme hızı, 10 sn çözünürlükle. Sabit pencerede pencere sınırında iki katına sıçrar (P08-04)."),
])

D["11-resilience"] = dashboard("resilience", "11 · Resilience", [
    text("Dayanıklılık (10+): devre kesici (breaker), yük atma, yeniden deneme, bağımlılık gecikmesi, hazır pod sayısı, degrade modu."),
    ts("Devre kesici durumu (0 kapalı · 1 yarı açık · 2 açık)", [(f'max(breaker_state{{{NS}}}) by (dep)', "{{dep}}")], "short", 12,
       desc="Devre kesici: 0 = kapalı (normal, istekler geçer) · 1 = yarı açık (deneme isteği) · 2 = açık (bağımlılık bozuk, istekler hemen reddedilir). Trafik yokken son durumunda donar."),
    ts("Bağımlılık gecikmesi p99", [(f'histogram_quantile(0.99, sum(rate(dependency_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, dep))', "{{dep}}")], "s", 12,
       desc="Uygulamanın bağımlılık (postgres …) çağrılarının p99 süresi. 10-11'de Redis çağrıları da 'postgres' etiketiyle sayılır."),
    ts("Bağımlılık hatası / sn", [(f'sum(rate(dependency_requests_total{{{NS},result="error"}}[1m])) by (dep)', "{{dep}}")], "reqps", 8, desc="Başarısız bağımlılık çağrısı."),
    ts("Yeniden deneme / sn", [(f'sum(rate(retry_total{{{NS}}}[1m])) by (dep)', "{{dep}}")], "reqps", 8, desc="Hata sonrası tekrar denenen çağrı. Herkes aynı anda yeniden denerse 'fırtına' (P10-01)."),
    ts("Atılan yük / sn", [(f'sum(rate(load_shed_total{{{NS}}}[1m]))', "atılan")], "reqps", 8,
       desc="Aşırı yükte bilerek hemen reddedilen istek (503). Eşik: aynı anda işlenen istek sayısı (P10-06)."),
    ts("Şu an işlenen istek (pod'a göre)", [(f'http_in_flight_requests{{{NS}}}', "{{pod}}")], "short", 12, desc="Bağımlılık yavaşlayınca cevabı bekleyen istekler birikir (P10-05)."),
    ts("Hazır pod adresi (endpoint) sayısı", [(f'sum(kube_endpointslice_endpoints{{{NS},ready="true"}}) by (endpointslice) or (sum(kube_endpointslice_endpoints{{{NS}}}) by (endpointslice) * 0)', "{{endpointslice}}")], "short", 12,
       desc="Trafik alabilen hazır pod sayısı. Readiness bir bağımlılığa bağlıysa, bağımlılık düşünce HEPSİ birden 0'a iner (P10-02)."),
    ts("Azaltılmış mod (degrade)", [(f'max(degraded_mode{{{NS}}}) by (mode)', "{{mode}}")], "short", 12,
       desc="1 = uygulama azaltılmış modda (ör. cache_only: yalnızca önbellekten cevap). Postgres breaker'ı açılınca devreye girer."),
    ts("Kabul edilen isteklerin p99 süresi", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[1m])) by (le))', "p99")], "s", 12,
       desc="İşlenen isteklerin p99 süresi. Yük atma, reddedilenleri ölçüme hiç sokmaz: kabul edilenler hızlı kalmalı (P10-06)."),
])

D["12-slo"] = dashboard("slo", "12 · SLO", [
    text("Hizmet hedefi (11+): yönlendirmelerin %99.9'u başarılı olsun. Hata bütçesi ne kadar kaldı, ne hızla yanıyor, alarm var mı? NOT: Prometheus 6 saat tutuyor — '30 günlük' bütçe fiilen son 6 saate göre hesaplanır."),
    ts("Hata oranı (son 5 dk)", [(f'slo:sli_error:ratio_rate5m{{{NS}}}', "{{sloth_slo}}")], "percentunit", 12,
       desc="Son 5 dakikada yönlendirmelerin yüzde kaçı 5xx. Hedef: %0.1'in altı."),
    ts("Kalan hata bütçesi", [(f'slo:period_error_budget_remaining:ratio{{{NS}}}', "{{sloth_slo}}")], "percentunit", 12,
       desc="Hata bütçesinin kalanı. 1 (=%100) hiç harcanmamış; 0 tükenmiş; negatif = hedef aşıldı."),
    ts("Bütçe yanma hızı (1 sa / 6 sa)", [(f'slo:sli_error:ratio_rate1h{{{NS}}} / on(sloth_slo, namespace) group_left slo:error_budget:ratio{{{NS}}}', "1 saat: {{sloth_slo}}"), (f'slo:sli_error:ratio_rate6h{{{NS}}} / on(sloth_slo, namespace) group_left slo:error_budget:ratio{{{NS}}}', "6 saat: {{sloth_slo}}")], "short", 12,
       desc="Bütçe yanma hızı: 1 = tam hedef hızında · 14.4 = bütçenin %2'si 1 saatte gider (sayfa atılır)."),
    ts("Çalan alarmlar", [(f'ALERTS{{alertstate="firing",{NS}}}', "{{alertname}}")], "short", 12, desc="Şu anda çalan SLO alarmları (P11-04)."),
])

D["13-rollout"] = dashboard("rollout", "13 · Rollout", [
    text("Kademeli dağıtım (12+, Argo Rollouts). Çizgiler sürüm başına: etiket, pod'un `rollouts-pod-template-hash`'i. Hangisi stable? `kubectl -n $level get rollout redirect -o jsonpath='{.status.stableRS}'`."),
    ts("İstek / sn (sürüme göre)", [(f'sum(rate(http_requests_total{{{NS}}}[1m])) by (rollouts_pod_template_hash)', "{{rollouts_pod_template_hash}}")], "reqps", 12, stacked=True,
       desc="Sürüm (pod şablonu) başına istek. Canary yayılırken yeni sürümün payı artar."),
    ts("Hata oranı (sürüme göre)", [(f'sum(rate(http_requests_total{{{NS},code=~"5.."}}[1m])) by (rollouts_pod_template_hash) / sum(rate(http_requests_total{{{NS}}}[1m])) by (rollouts_pod_template_hash)', "{{rollouts_pod_template_hash}}")], "percentunit", 12,
       desc="Sürüm başına hata oranı. Kötü sürüm canary'deyken kendi çizgisinde yükselir (P12-01)."),
    ts("p99 süre (sürüme göre)", [(f'histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{{{NS}}}[1m])) by (le, rollouts_pod_template_hash))', "{{rollouts_pod_template_hash}}")], "s", 12, desc="Sürüm başına gecikme."),
    ts("Dağıtım aşaması (Argo Rollouts)", [('rollout_info{exported_namespace="$level"} or rollout_info{namespace="$level"}', "{{name}}: {{phase}}"), ('rollout_info_replicas_desired{exported_namespace="$level"} or rollout_info_replicas_desired{namespace="$level"}', "istenen replika")], "short", 12,
       desc="Rollout'un aşaması (Progressing / Paused / Healthy / Degraded). Argo Rollouts metrikleri `make -C platform argo` ile açılır. (Metriğin kendi `namespace` etiketi Prometheus'ta `exported_namespace` olur; sorgu ikisine de bakar.)"),
    ts("Git ile uyumsuz uygulamalar (Argo CD)", [('argocd_app_info{sync_status!="Synced",dest_namespace="$level"}', "{{name}}: {{sync_status}}")], "short", 12,
       desc="Git ile kümesi farklılaşan (OutOfSync) uygulamalar. Boş = her şey Git'teki gibi (P12-03)."),
])

D["14-security"] = dashboard("security", "14 · Security", [
    text("Güvenlik (13+): kimlik reddi, tehlikeli URL reddi, politika ihlalleri, var olmayan kod taraması."),
    ts("Kimlik reddi / sn (401 / 403)", [(f'sum(rate(http_requests_total{{{NS},code=~"401|403"}}[1m])) by (code)', "{{code}}")], "reqps", 12,
       desc="401 = kimlik yok/geçersiz (API anahtarı) · 403 = kimlik var ama yetki yok."),
    ts("Tehlikeli URL reddi (sebebe göre)", [(f'sum(rate(create_rejected_unsafe_total{{{NS}}}[1m])) by (reason)', "{{reason}}")], "reqps", 12,
       desc="Reddedilen URL'ler: iç ağ adresi, DNS ile gizlenmiş iç adres, yasak şema (P13-05)."),
    ts("Politika ihlalleri (Kyverno)", [('sum(rate(kyverno_policy_results_total{policy_result="fail"}[5m])) by (policy_name)', "{{policy_name}}")], "reqps", 12,
       desc="Politikaya uymadığı için reddedilen/raporlanan kaynaklar (P13-07)."),
    ts("Ağ politikası hataları (Calico)", [('sum(rate(felix_int_dataplane_failures[5m]))', "veri düzlemi hatası")], "reqps", 12,
       desc="UYARI: Calico metrikleri bu kurulumda toplanmıyor; panel boş kalır. Ağ politikasının etkisini terminalde gör (P13-03)."),
    ts("Var olmayan kod istekleri / sn (tarama)", [(f'sum(rate(redirect_total{{{NS},result="not_found"}}[1m]))', "404 / sn")], "reqps", 12,
       desc="Var olmayan kodlara yapılan istek. Tarama saldırısında tırmanır (P13-06)."),
])

D["15-k6"] = dashboard("k6", "15 · k6 (client tarafı)", [
    text("Yük üreticisi k6'nın gözünden: ne gönderildi, ne döndü. Uygulamanın göremediği cevaplar (ingress'in 502/503'ü) BURADA görünür. Sunucu panelleriyle aynı zaman ekseninde karşılaştır. Kodların anlamı: kök README → Grafana'yı okumak."),
    stat("Gönderilen istek / sn", 'sum(rate(k6_http_reqs_total{level="$level"}[1m]))', "reqps", desc="k6'nın saniyede gönderdiği istek."),
    stat("Başarısız oran", 'k6_http_req_failed_rate{level="$level"}', "percentunit", desc="k6'nın başarısız saydığı isteklerin oranı (4xx/5xx/bağlantı hatası)."),
    stat("p99 süre", 'k6_http_req_duration_p99{level="$level"}', "ms", desc="İstemcinin ölçtüğü p99 gecikme."),
    stat("Sanal kullanıcı", 'k6_vus{level="$level"}', desc="Eşzamanlı sanal kullanıcı sayısı."),
    ts("İstek / sn (isteğe göre)", [('sum(rate(k6_http_reqs_total{level="$level"}[1m])) by (name)', "{{name}}")], "reqps", 12, stacked=True,
       desc="GET /{code} = yönlendirme · POST /api/links = oluşturma."),
    ts("Başarısız oran (zaman içinde)", [('k6_http_req_failed_rate{level="$level"}', "başarısız oran")], "percentunit", 12, desc="Zaman içinde başarısız isteklerin oranı."),
    ts("Gecikme (p50 / p95 / p99)", [('k6_http_req_duration_p50{level="$level"}', "p50 (tipik)"), ('k6_http_req_duration_p95{level="$level"}', "p95"), ('k6_http_req_duration_p99{level="$level"}', "p99 (yavaş uç)")], "ms", 12,
       desc="İstemcinin ölçtüğü gecikme dağılımı."),
    ts("Dönen durum kodları", [('sum(rate(k6_http_reqs_total{level="$level"}[1m])) by (status)', "{{status}}")], "reqps", 12, stacked=True,
       desc="Dönen HTTP kodları: 201/302 başarı · 404 yok · 429 hız sınırı · 502 bağlantı koptu · 503 hazır pod yok. Hatalar anında döndüğü için sayıca şişer — SÜRESİNE bak."),
    ts("Sanal kullanıcı (zaman içinde)", [('k6_vus{level="$level"}', "sanal kullanıcı")], "short", 12, desc="Yük boyunca eşzamanlı sanal kullanıcı."),
    ts("Senaryoya özel ölçüler", [('k6_ryw_violations_total{level="$level"}', "read-your-writes ihlali"), ('k6_normal_client_latency_p99{level="$level"}', "normal kullanıcı p99")], "short", 12,
       desc="Belirli senaryoların özel ölçüleri: read-your-writes ihlali (09) ve normal kullanıcının gecikmesi (08)."),
])

# COUNTS'taki bir başlık yazım hatasıyla hiçbir panele denk gelmezse tam sayı biçimi sessizce kaybolur.
_titles = {q["title"] for d in D.values() for q in d["panels"]}
assert COUNTS <= _titles, f"COUNTS'ta panelsiz başlık: {sorted(COUNTS - _titles)}"

OUT.mkdir(exist_ok=True)
for f in OUT.glob("*.json"): f.unlink()
for name, d in D.items():
    (OUT / f"{name}.json").write_text(json.dumps(d, ensure_ascii=False, indent=1))
print(f"{len(D)} dashboard → {OUT}")
