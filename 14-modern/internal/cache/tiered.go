package cache

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
)

// Tiered — L1 (pod içi) + L2 (Redis) + pub/sub ile geçersiz kılma yayını.
//
// EN: Level 03 had L1 and learned that N copies of the truth cannot be invalidated. Level 04 moved
//
//	to L2 and paid a network hop on every hit. This brings L1 back — and pays the debt that 03
//	left unpaid: EVERY COPY OWES AN INVALIDATION CHANNEL. The channel is Redis pub/sub, and it
//	is best-effort by design: a missed message means a stale entry for at most the L1 TTL,
//	which is why that TTL is short (seconds, not minutes).
//	The honest framing: this is not "L1 is free now". It is "L1 costs a channel, a short TTL
//	and a window of inconsistency you have measured and accepted".
//
// TR: 03'te L1 vardı ve gerçeğin N kopyasının geçersiz kılınamayacağını öğrendi. 04 L2'ye taşıdı
//
//	ve her isabette bir ağ adımı ödedi. Bu, L1'i geri getiriyor — ve 03'ün ödemediği borcu
//	ödüyor: HER KOPYA BİR GEÇERSİZ KILMA KANALI BORÇLANIR. Kanal Redis pub/sub ve tasarım
//	gereği en-iyi-çaba: kaçan bir mesaj, en fazla L1 TTL'i kadar bayat kayıt demek — bu yüzden
//	o TTL kısa (saniyeler, dakikalar değil).
//	Dürüst çerçeve: bu "L1 artık bedava" değil. Bu, "L1'in bedeli bir kanal, kısa bir TTL ve
//	ÖLÇÜP KABUL ETTİĞİN bir tutarsızlık penceresi".
//
// [Topic · Konu: Çok katmanlı önbellek, invalidation broadcast]
type Tiered[V any] struct {
	l1     *LRU[V]
	l2     *Redis[V]
	rdb    *redis.Client
	ch     string
	m      *Metrics
	nodeID string

	mu     sync.RWMutex
	closed bool
}

type TieredMetrics struct {
	Invalidations *prometheus.CounterVec // direction
	PubSubErrors  prometheus.Counter
}

func NewTieredMetrics(reg prometheus.Registerer) *TieredMetrics {
	m := &TieredMetrics{
		Invalidations: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "cache_invalidation_messages_total", Help: "Pub/sub geçersiz kılma mesajı"},
			[]string{"direction"}),
		PubSubErrors: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "cache_pubsub_errors_total", Help: "Pub/sub hatası"}),
	}
	reg.MustRegister(m.Invalidations, m.PubSubErrors)
	for _, d := range []string{"sent", "received"} {
		m.Invalidations.WithLabelValues(d)
	}
	return m
}

func NewTiered[V any](l1 *LRU[V], l2 *Redis[V], rdb *redis.Client, channel, nodeID string,
	m *Metrics, tm *TieredMetrics) *Tiered[V] {
	t := &Tiered[V]{l1: l1, l2: l2, rdb: rdb, ch: channel, m: m, nodeID: nodeID}
	go t.listen(tm)
	return t
}

type invalidationMsg struct {
	Key    string `json:"key"`
	NodeID string `json:"node"`
}

// listen — diğer pod'ların geçersiz kılma yayınlarını dinle.
func (t *Tiered[V]) listen(tm *TieredMetrics) {
	ctx := context.Background()
	sub := t.rdb.Subscribe(ctx, t.ch)
	defer sub.Close()
	for msg := range sub.Channel() {
		var m invalidationMsg
		if err := json.Unmarshal([]byte(msg.Payload), &m); err != nil {
			tm.PubSubErrors.Inc()
			continue
		}
		// Kendi yayınını yok say: zaten yerel olarak sildin.
		if m.NodeID == t.nodeID {
			continue
		}
		t.l1.Invalidate(m.Key)
		tm.Invalidations.WithLabelValues("received").Inc()
	}
}

func (t *Tiered[V]) GetOrLoad(ctx context.Context, key string, load func(context.Context) (V, bool, error)) (V, error) {
	// L1: pod belleği. En sıcak anahtarlar hiç ağa çıkmaz (P04-02, P04-03'ün cevabı).
	v, err := t.l1.GetOrLoad(ctx, key, func(ctx context.Context) (V, bool, error) {
		// L1 ıskası → L2'ye sor. L2 de ıskalarsa gerçek yükleyici çalışır.
		vv, lerr := t.l2.GetOrLoad(ctx, key, load)
		if errors.Is(lerr, ErrNegative) {
			return vv, false, nil
		}
		if lerr != nil {
			return vv, false, lerr
		}
		return vv, true, nil
	})
	return v, err
}

// Invalidate — yerel sil + diğerlerine YAYINLA.
func (t *Tiered[V]) Invalidate(ctx context.Context, key string, tm *TieredMetrics) {
	t.l1.Invalidate(key)
	t.l2.Invalidate(ctx, key)
	payload, _ := json.Marshal(invalidationMsg{Key: key, NodeID: t.nodeID})
	if err := t.rdb.Publish(ctx, t.ch, payload).Err(); err != nil {
		// Yayın başarısız: diğer pod'lar L1 TTL'i kadar bayat kalır. Sessizce geçme, SAY.
		tm.PubSubErrors.Inc()
		return
	}
	tm.Invalidations.WithLabelValues("sent").Inc()
}

func (t *Tiered[V]) Ping(ctx context.Context) error { return t.l2.Ping(ctx) }

// L1TTL — L1'in TTL'i kısa olmalı: yayın kaçarsa bayatlık penceresi bu kadar.
const RecommendedL1TTL = 10 * time.Second
