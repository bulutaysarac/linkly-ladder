package store

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// ReadWrite — yazmayı primary'ye, okumayı replikalara yönlendiren Store.
//
// EN: Splitting reads from writes is the cheapest way to scale a database — and the first place
//     where the application must understand REPLICATION LAG. A replica is not a slower copy of
//     the primary; it is a copy of the primary AS OF SOME EARLIER MOMENT. Every read you send
//     there is a read from the past, and the application is the only layer that knows whether
//     that is acceptable for this particular request.
// TR: Okumayı yazmadan ayırmak bir veritabanını ölçeklemenin en ucuz yolu — ve uygulamanın
//     REPLİKASYON GECİKMESİNİ anlamak zorunda kaldığı ilk yer. Replika, primary'nin daha yavaş
//     bir kopyası değildir; primary'nin DAHA ÖNCEKİ BİR ANA ait kopyasıdır. Oraya gönderdiğin
//     her okuma geçmişten bir okumadır ve bunun bu istek için kabul edilebilir olup olmadığını
//     bilen tek katman uygulamadır.
// [Topic · Konu: Okuma/yazma ayrımı, replikasyon gecikmesi]
type ReadWrite struct {
	primary Store
	replica Store
	m       *RWMetrics
	// stickyWindow: bir kiracı yazdıktan sonra bu süre boyunca okumaları da primary'den yap.
	// read-your-writes garantisinin en ucuz gerçekleştirimi (P09-01'in çözümü).
	stickyWindow time.Duration
	recent       *recentWrites
}

type RWMetrics struct {
	Routed        *prometheus.CounterVec // target
	RYWViolations prometheus.Counter
	StickyReads   prometheus.Counter
}

func NewRWMetrics(reg prometheus.Registerer) *RWMetrics {
	m := &RWMetrics{
		Routed: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "db_reads_routed_total", Help: "Okuma nereye yönlendirildi"}, []string{"target"}),
		RYWViolations: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "ryw_violations_total", Help: "Kendi yazdığını okuyamama"}),
		StickyReads: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "db_sticky_reads_total", Help: "Yazma sonrası primary'ye yapışan okuma"}),
	}
	reg.MustRegister(m.Routed, m.RYWViolations, m.StickyReads)
	for _, t := range []string{"primary", "replica"} {
		m.Routed.WithLabelValues(t)
	}
	return m
}

func NewReadWrite(primary, replica Store, stickyWindow time.Duration, m *RWMetrics) *ReadWrite {
	return &ReadWrite{primary: primary, replica: replica, m: m,
		stickyWindow: stickyWindow, recent: newRecentWrites()}
}

// reader — bu okuma nereden yapılmalı?
func (rw *ReadWrite) reader(code string) Store {
	if rw.replica == nil {
		return rw.primary
	}
	if rw.stickyWindow > 0 && rw.recent.wroteRecently(code, rw.stickyWindow) {
		rw.m.StickyReads.Inc()
		rw.m.Routed.WithLabelValues("primary").Inc()
		return rw.primary
	}
	rw.m.Routed.WithLabelValues("replica").Inc()
	return rw.replica
}

func (rw *ReadWrite) CreateUnique(ctx context.Context, l *Link) error {
	err := rw.primary.CreateUnique(ctx, l)
	if err == nil {
		rw.recent.mark(l.Code)
	}
	return err
}

func (rw *ReadWrite) Get(ctx context.Context, code string) (*Link, error) {
	return rw.reader(code).Get(ctx, code)
}

func (rw *ReadWrite) IncrementClicks(ctx context.Context, code string) error {
	return rw.primary.IncrementClicks(ctx, code)
}

func (rw *ReadWrite) Delete(ctx context.Context, tenant, code string) error {
	err := rw.primary.Delete(ctx, tenant, code)
	if err == nil {
		rw.recent.mark(code)
	}
	return err
}

// ListByTenant — liste okumaları replikaya gidebilir; yeni oluşturulan bir linkin listede
// birkaç yüz milisaniye gecikmeli görünmesi kabul edilebilir bir tazeliktir.
func (rw *ReadWrite) ListByTenant(ctx context.Context, tenant string, limit int) ([]Link, error) {
	if rw.replica == nil {
		return rw.primary.ListByTenant(ctx, tenant, limit)
	}
	rw.m.Routed.WithLabelValues("replica").Inc()
	return rw.replica.ListByTenant(ctx, tenant, limit)
}

func (rw *ReadWrite) Count(ctx context.Context) (int64, error) { return rw.primary.Count(ctx) }

func (rw *ReadWrite) WriteClicks(ctx context.Context, counts map[string]int64) error {
	return rw.primary.WriteClicks(ctx, counts)
}

func (rw *ReadWrite) WriteClicksIdempotent(ctx context.Context, counts map[string]int64, ids []string) (int, error) {
	return rw.primary.WriteClicksIdempotent(ctx, counts, ids)
}

func (rw *ReadWrite) Stats(ctx context.Context, code string, days int) (*Stats, error) {
	if rw.replica == nil {
		return rw.primary.Stats(ctx, code, days)
	}
	rw.m.Routed.WithLabelValues("replica").Inc()
	return rw.replica.Stats(ctx, code, days)
}

func (rw *ReadWrite) Ping(ctx context.Context) error { return rw.primary.Ping(ctx) }

func (rw *ReadWrite) Close() {
	rw.primary.Close()
	if rw.replica != nil {
		rw.replica.Close()
	}
}

// RecordRYWViolation — handler, kendi yazdığını okuyamadığında çağırır.
func (rw *ReadWrite) RecordRYWViolation() { rw.m.RYWViolations.Inc() }

var _ Store = (*ReadWrite)(nil)
