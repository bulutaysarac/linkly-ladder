package store

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
)

//go:embed migrations/*.sql
var Migrations embed.FS

type Postgres struct {
	pool *pgxpool.Pool
	m    *DBMetrics
}

// DBMetrics — veritabanı erişimini ölçmek uygulamanın işi.
// EN: postgres_exporter tells you what the DATABASE sees. It cannot tell you how long YOUR request
//
//	waited for a connection from the pool — and at level 02 that wait is the thing that will hurt
//	you first (P02-02, P02-06). Measure both sides of the boundary.
//
// TR: postgres_exporter sana VERİTABANININ gördüğünü söyler. SENİN isteğinin havuzdan bağlantı
//
//	almak için ne kadar beklediğini söyleyemez — ve 02'de canını ilk yakacak şey tam olarak o
//	bekleme (P02-02, P02-06). Sınırın iki tarafını da ölç.
//
// [Topic · Konu: Gözlemlenebilirlik, bağlantı havuzu]
type DBMetrics struct {
	Queries      *prometheus.CounterVec   // op, result
	Duration     *prometheus.HistogramVec // op
	AcquireWait  prometheus.Histogram
	EmptyAcquire prometheus.Counter
}

func NewDBMetrics(reg prometheus.Registerer) *DBMetrics {
	m := &DBMetrics{
		Queries: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "db_queries_total", Help: "Veritabanı sorgusu"}, []string{"op", "result"}),
		Duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "db_query_duration_seconds", Help: "Sorgu süresi",
			Buckets: []float64{.0005, .001, .0025, .005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5}}, []string{"op"}),
		AcquireWait: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name: "db_pool_acquire_duration_seconds", Help: "Havuzdan bağlantı alma süresi",
			Buckets: []float64{.0001, .0005, .001, .005, .01, .05, .1, .5, 1, 5}}),
		EmptyAcquire: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "db_pool_empty_acquire_total", Help: "Havuz boşken beklenen alma sayısı"}),
	}
	reg.MustRegister(m.Queries, m.Duration, m.AcquireWait, m.EmptyAcquire)
	for _, op := range []string{"create", "get", "increment_clicks", "delete", "list", "count"} {
		for _, r := range []string{"ok", "error", "not_found", "conflict"} {
			m.Queries.WithLabelValues(op, r)
		}
	}
	return m
}

func Open(ctx context.Context, dsn string, maxConns int32, m *DBMetrics) (*Postgres, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("dsn: %w", err)
	}
	cfg.MaxConns = maxConns
	cfg.MinConns = 2
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	// EN: A per-statement timeout set on the SERVER side is the only one a runaway query cannot
	//     ignore: a context deadline cancels the client's wait, but without statement_timeout the
	//     backend keeps burning CPU and holding locks. Level 02 measures what happens without it
	//     (P02-06); set STATEMENT_TIMEOUT to turn it on.
	// TR: SUNUCU tarafında ayarlanan ifade timeout'u, kaçak bir sorgunun yok sayamayacağı tek şeydir:
	//     context deadline client'ın beklemesini iptal eder ama statement_timeout yoksa backend CPU
	//     yakmaya ve kilit tutmaya devam eder. 02, olmadığında ne olduğunu ölçüyor (P02-06).
	cfg.ConnConfig.RuntimeParams["application_name"] = "linkly"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("havuz: %w", err)
	}
	return &Postgres{pool: pool, m: m}, nil
}

func (p *Postgres) Pool() *pgxpool.Pool { return p.pool }
func (p *Postgres) Close()              { p.pool.Close() }

func (p *Postgres) Ping(ctx context.Context) error { return p.pool.Ping(ctx) }

// track — her sorguyu ölç: süre, sonuç ve havuz bekleme süresi.
func (p *Postgres) track(ctx context.Context, op string, fn func(context.Context) error) error {
	acquireStart := time.Now()
	stat := p.pool.Stat()
	if stat.IdleConns() == 0 && stat.TotalConns() >= stat.MaxConns() {
		p.m.EmptyAcquire.Inc()
	}
	start := time.Now()
	err := fn(ctx)
	p.m.AcquireWait.Observe(start.Sub(acquireStart).Seconds())
	p.m.Duration.WithLabelValues(op).Observe(time.Since(start).Seconds())
	switch {
	case err == nil:
		p.m.Queries.WithLabelValues(op, "ok").Inc()
	case errors.Is(err, ErrExists):
		p.m.Queries.WithLabelValues(op, "conflict").Inc()
	case errors.Is(err, ErrNotFound):
		p.m.Queries.WithLabelValues(op, "not_found").Inc()
	default:
		p.m.Queries.WithLabelValues(op, "error").Inc()
	}
	return err
}

// CreateUnique — 01'deki koşullu eklemenin SQL karşılığı.
// EN: ON CONFLICT DO NOTHING + RETURNING: one round trip, no read-then-write race. The check-then-insert
//
//	version ("SELECT, if absent INSERT") is wrong under concurrency no matter how careful you are —
//	two requests can both pass the check. The database, not the application, must arbitrate.
//
// TR: ON CONFLICT DO NOTHING + RETURNING: tek gidiş-geliş, oku-sonra-yaz yarışı yok. "Önce SELECT,
//
//	yoksa INSERT" sürümü ne kadar dikkatli olursan ol eşzamanlılıkta yanlıştır — iki istek de
//	kontrolü geçebilir. Hakemlik uygulamanın değil, veritabanının işi.
//
// [Topic · Konu: Yarış koşulları, atomiklik]
func (p *Postgres) CreateUnique(ctx context.Context, l *Link) error {
	return p.track(ctx, "create", func(ctx context.Context) error {
		var inserted string
		err := p.pool.QueryRow(ctx,
			`INSERT INTO links (code, url, tenant, created_at) VALUES ($1, $2, $3, $4)
			 ON CONFLICT (code) DO NOTHING RETURNING code`,
			l.Code, l.URL, l.Tenant, l.CreatedAt).Scan(&inserted)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrExists
		}
		return err
	})
}

func (p *Postgres) Get(ctx context.Context, code string) (*Link, error) {
	var l Link
	err := p.track(ctx, "get", func(ctx context.Context) error {
		err := p.pool.QueryRow(ctx,
			`SELECT code, url, tenant, clicks, created_at FROM links WHERE code = $1`, code).
			Scan(&l.Code, &l.URL, &l.Tenant, &l.Clicks, &l.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	return &l, nil
}

// IncrementClicks — BİLEREK senkron ve istek yolunda.
// EN: This is the level-01 mutex turned into a database row lock. On a hot link every redirect
//
//	serialises on the same row: the lock queue, not the CPU, sets your p99. It also generates a
//	new row version per click (MVCC), so the table bloats and autovacuum has to keep up.
//	P02-08 measures it; level 05 takes the write off the read path entirely.
//
// TR: Bu, 01'deki mutex'in veritabanı satır kilidine dönüşmüş hâli. Sıcak bir linkte her redirect
//
//	aynı satırda sıraya girer: p99'unu CPU değil, kilit kuyruğu belirler. Üstelik her tıklama yeni
//	bir satır sürümü üretir (MVCC), tablo şişer ve autovacuum yetişmek zorunda kalır.
//	P02-08 bunu ölçüyor; 05 yazmayı okuma yolundan tamamen çıkarıyor.
//
// [Topic · Konu: Satır kilidi, MVCC, okuma/yazma yolu]
func (p *Postgres) IncrementClicks(ctx context.Context, code string) error {
	return p.track(ctx, "increment_clicks", func(ctx context.Context) error {
		_, err := p.pool.Exec(ctx, `UPDATE links SET clicks = clicks + 1 WHERE code = $1`, code)
		return err
	})
}

func (p *Postgres) Delete(ctx context.Context, tenant, code string) error {
	return p.track(ctx, "delete", func(ctx context.Context) error {
		tag, err := p.pool.Exec(ctx, `DELETE FROM links WHERE code = $1 AND tenant = $2`, code, tenant)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}

// ListByTenant — BİLEREK index'siz (P02-05).
func (p *Postgres) ListByTenant(ctx context.Context, tenant string, limit int) ([]Link, error) {
	var out []Link
	err := p.track(ctx, "list", func(ctx context.Context) error {
		rows, err := p.pool.Query(ctx,
			`SELECT code, url, tenant, clicks, created_at FROM links
			 WHERE tenant = $1 ORDER BY created_at DESC LIMIT $2`, tenant, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var l Link
			if err := rows.Scan(&l.Code, &l.URL, &l.Tenant, &l.Clicks, &l.CreatedAt); err != nil {
				return err
			}
			out = append(out, l)
		}
		return rows.Err()
	})
	return out, err
}

func (p *Postgres) Count(ctx context.Context) (int64, error) {
	var n int64
	err := p.track(ctx, "count", func(ctx context.Context) error {
		return p.pool.QueryRow(ctx, `SELECT count(*) FROM links`).Scan(&n)
	})
	return n, err
}

// PoolStats — Prometheus'a havuz durumunu yayınla (collector olarak).
func (p *Postgres) PoolStats() (acquired, idle, total, max int32) {
	s := p.pool.Stat()
	return s.AcquiredConns(), s.IdleConns(), s.TotalConns(), s.MaxConns()
}

var _ Store = (*Postgres)(nil)
var _ = pgconn.PgError{}
