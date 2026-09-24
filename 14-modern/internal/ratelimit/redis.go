package ratelimit

import (
	"context"
	"errors"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
)

// Distributed — Redis'te paylaşılan sliding window sayacı.
//
// EN: Why Lua and not GET-then-SET? Because rate limiting is a read-modify-write on shared state,
//     and a client-side check is a race by construction: N pods can all read "9 of 10 used" and
//     all decide to allow. The script runs atomically inside Redis — the limit becomes a fact
//     rather than an opinion held by each pod.
// TR: Neden Lua, neden GET-sonra-SET değil? Çünkü hız sınırlama, paylaşılan durum üzerinde bir
//     oku-değiştir-yaz işlemidir ve client tarafındaki kontrol yapısı gereği bir yarıştır: N pod
//     da "10'un 9'u kullanılmış" okuyup hepsi izin vermeye karar verebilir. Script Redis'in
//     İÇİNDE atomik çalışır — limit, her pod'un ayrı ayrı sahip olduğu bir kanaat olmaktan
//     çıkıp bir OLGU hâline gelir.
// [Topic · Konu: Dağıtık hız sınırlama, atomiklik]

// Sliding window log yerine "iki pencereli sayaç" (sliding window counter):
// tam log tutmak bellek açısından pahalı, sabit pencere ise sınırda 2x burst geçirir (P08-04).
// Bu yöntem ikisinin ortası: iki sabit pencere ve ağırlıklı toplam.
const slidingWindowLua = `
local key_cur  = KEYS[1]
local key_prev = KEYS[2]
local limit    = tonumber(ARGV[1])
local window   = tonumber(ARGV[2])   -- saniye
local elapsed  = tonumber(ARGV[3])   -- mevcut pencerede geçen saniye
local prev = tonumber(redis.call('GET', key_prev) or '0')
local cur  = tonumber(redis.call('GET', key_cur)  or '0')
-- Önceki pencerenin ağırlığı: pencerede ne kadar ilerlediysek o kadar azalır.
local weight = (window - elapsed) / window
local estimated = prev * weight + cur
if estimated + 1 > limit then
  return {0, math.floor(estimated)}
end
cur = redis.call('INCR', key_cur)
if cur == 1 then
  redis.call('EXPIRE', key_cur, window * 2)
end
return {1, math.floor(estimated) + 1}
`

// TRAP_FIXED_WINDOW — sabit pencere sayacı: önceki pencereyi HİÇ hesaba katmaz.
//
// EN: P08-04 claims "a fixed window lets 2x through at the boundary"; this script is what makes
//
//	the claim testable. Without it the experiment could only measure the sliding window and
//	could never fail — a trap that is not wired to code is a comment pretending to be an
//	experiment.
//	The failure it models is real and famous: with a 10s/300 limit, 300 requests at t=9.9s and
//	300 more at t=10.1s both pass. 600 requests in 0.2 seconds, and every single check said
//	"within the limit", because each one looked at a different window.
//
// TR: P08-04 "sabit pencere sınırda 2x geçirir" diyor; bu betik iddiayı sınanabilir kılan şey.
//
//	O olmadan deney yalnızca kayan pencereyi ölçebilir ve hiç düşemezdi — koda bağlanmamış bir
//	tuzak, deney taklidi yapan bir yorumdur.
//	Modellediği arıza gerçek ve meşhur: 10 sn/300 limitte, t=9.9'da 300 ve t=10.1'de 300 daha
//	geçer. 0.2 saniyede 600 istek ve her kontrol "limit içinde" dedi, çünkü her biri BAŞKA bir
//	pencereye baktı.
const fixedWindowLua = `
local key_cur = KEYS[1]
local limit   = tonumber(ARGV[1])
local window  = tonumber(ARGV[2])
local cur = tonumber(redis.call('GET', key_cur) or '0')
if cur + 1 > limit then
  return {0, cur}
end
cur = redis.call('INCR', key_cur)
if cur == 1 then
  redis.call('EXPIRE', key_cur, window)
end
return {1, cur}
`

type Metrics struct {
	Decisions *prometheus.CounterVec // decision, key_type
	Errors    prometheus.Counter
	Latency   prometheus.Histogram
}

func NewMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		Decisions: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "ratelimit_decisions_total", Help: "Hız sınırı kararı"}, []string{"decision", "key_type"}),
		Errors: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "ratelimit_errors_total", Help: "Limiter backend hatası"}),
		Latency: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "ratelimit_check_duration_seconds", Help: "Limit kontrolü süresi",
			Buckets: []float64{.0001, .0005, .001, .0025, .005, .01, .025, .05, .1}}),
	}
	// AYNI METRİĞİ İKİ PAKET SAHİPLENİYOR: `ratelimit_decisions_total` hem burada (dağıtık
	// limiter) hem internal/metrics'te (süreç içi yedek limiter, Redis yokken kullanılıyor)
	// tanımlı. MustRegister ikinci kayıtta PANİKLERDİ ve api-svc açılmazdı
	// ("duplicate metrics collector registration attempted"). Prometheus'un bunun için bir
	// sözleşmesi var: kayıt hatası AlreadyRegisteredError ise VAR OLAN collector'ı kullan.
	// Ders: bir metriğin adı bir SÖZLEŞMEDİR; iki sahip varsa çakışmayı yutup tek seriye yaz.
	register := func(c prometheus.Collector) prometheus.Collector {
		if err := reg.Register(c); err != nil {
			var are prometheus.AlreadyRegisteredError
			if errors.As(err, &are) {
				return are.ExistingCollector
			}
			panic(err)
		}
		return c
	}
	m.Decisions = register(m.Decisions).(*prometheus.CounterVec)
	m.Errors = register(m.Errors).(prometheus.Counter)
	m.Latency = register(m.Latency).(prometheus.Histogram)
	for _, d := range []string{"allow", "reject"} {
		for _, k := range []string{"ip", "tenant", "global"} {
			m.Decisions.WithLabelValues(d, k)
		}
	}
	return m
}

type DistConfig struct {
	Window    time.Duration
	PerIP     int
	PerTenant int
	// FailOpen: Redis erişilemezse İZİN VER (true) ya da REDDET (false).
	// EN: There is no safe default here, only a choice you must make consciously. fail-open means
	//     a cache outage removes your protection exactly when load is highest; fail-closed means a
	//     cache outage becomes a full outage. We choose fail-open and ALERT — losing a protection
	//     is recoverable, losing the service is not. P08-01 measures both sides.
	// TR: Burada güvenli bir varsayılan yok, yalnızca bilinçli yapman gereken bir seçim var.
	//     fail-open: önbellek kesintisi korumanı tam da yükün en yüksek olduğu anda kaldırır;
	//     fail-closed: önbellek kesintisi tam kesintiye dönüşür. Biz fail-open seçip ALARM
	//     kuruyoruz — korumayı kaybetmek telafi edilebilir, hizmeti kaybetmek edilemez.
	//     P08-01 iki tarafı da ölçüyor.
	FailOpen bool
	// FixedWindow: kayan pencere yerine sabit pencere (TRAP_FIXED_WINDOW, P08-04).
	FixedWindow bool
}

type Distributed struct {
	rdb  *redis.Client
	cfg  DistConfig
	m    *Metrics
	sha  string
	dead bool
}

func NewDistributed(ctx context.Context, rdb *redis.Client, cfg DistConfig, m *Metrics) *Distributed {
	d := &Distributed{rdb: rdb, cfg: cfg, m: m}
	lua := slidingWindowLua
	if cfg.FixedWindow {
		lua = fixedWindowLua
	}
	if sha, err := rdb.ScriptLoad(ctx, lua).Result(); err == nil {
		d.sha = sha
	}
	return d
}

type Decision struct {
	Allowed    bool
	KeyType    string
	Used       int64
	Limit      int
	RetryAfter time.Duration
}

// Exempt — limiter'ı bilinçli olarak atlayan isteği say (httpapi.loadTestExempt). Sayılmayan bir
// muafiyet, Grafana'da kapatılmış bir korumadan ayırt edilemez.
func (d *Distributed) Exempt() { d.m.Decisions.WithLabelValues("exempt", "loadtest").Inc() }

func (d *Distributed) Allow(ctx context.Context, keyType, key string, limit int) Decision {
	if limit <= 0 {
		return Decision{Allowed: true, KeyType: keyType, Limit: limit}
	}
	start := time.Now()
	defer func() { d.m.Latency.Observe(time.Since(start).Seconds()) }()

	win := int64(d.cfg.Window.Seconds())
	if win <= 0 {
		win = 1
	}
	now := time.Now().Unix()
	bucket := now / win
	elapsed := now % win
	cur := "rl:" + keyType + ":" + key + ":" + itoa(bucket)
	prev := "rl:" + keyType + ":" + key + ":" + itoa(bucket-1)

	res, err := d.eval(ctx, []string{cur, prev}, limit, win, elapsed)
	if err != nil {
		d.m.Errors.Inc()
		// Limiter'ın kendi bağımlılığı düştü. Kararı burada veriyoruz ve GÖRÜNÜR kılıyoruz.
		if d.cfg.FailOpen {
			d.m.Decisions.WithLabelValues("allow", keyType).Inc()
			return Decision{Allowed: true, KeyType: keyType, Limit: limit}
		}
		d.m.Decisions.WithLabelValues("reject", keyType).Inc()
		return Decision{Allowed: false, KeyType: keyType, Limit: limit, RetryAfter: d.cfg.Window}
	}
	allowed := len(res) > 0 && res[0] == 1
	var used int64
	if len(res) > 1 {
		used = res[1]
	}
	if allowed {
		d.m.Decisions.WithLabelValues("allow", keyType).Inc()
		return Decision{Allowed: true, KeyType: keyType, Used: used, Limit: limit}
	}
	d.m.Decisions.WithLabelValues("reject", keyType).Inc()
	return Decision{Allowed: false, KeyType: keyType, Used: used, Limit: limit,
		RetryAfter: time.Duration(win-elapsed) * time.Second}
}

func (d *Distributed) eval(ctx context.Context, keys []string, limit int, win, elapsed int64) ([]int64, error) {
	var (
		raw any
		err error
	)
	if d.sha != "" {
		raw, err = d.rdb.EvalSha(ctx, d.sha, keys, limit, win, elapsed).Result()
		if err != nil && isNoScript(err) {
			d.sha = ""
		}
	}
	if d.sha == "" {
		raw, err = d.rdb.Eval(ctx, slidingWindowLua, keys, limit, win, elapsed).Result()
	}
	if err != nil {
		return nil, err
	}
	arr, ok := raw.([]any)
	if !ok {
		return nil, nil
	}
	out := make([]int64, 0, len(arr))
	for _, v := range arr {
		if n, ok := v.(int64); ok {
			out = append(out, n)
		}
	}
	return out, nil
}

func isNoScript(err error) bool {
	return err != nil && len(err.Error()) >= 8 && err.Error()[:8] == "NOSCRIPT"
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
