// Command api-svc — yönetim yolu: oluşturma, silme, listeleme, istatistik.
//
// EN: Low traffic, writes, and queries that are allowed to take 100 ms. Because it is a separate
//
//	deployment it can have a bigger connection pool per pod (it needs the database) and a much
//	smaller replica count (it does not need the throughput) — the exact opposite knobs from
//	redirect-svc. One binary could never have both settings at once.
//
// TR: Düşük trafik, yazma ve 100 ms sürmesine izin verilen sorgular. Ayrı bir deployment olduğu
//
//	için pod başına DAHA BÜYÜK bir bağlantı havuzu (veritabanına ihtiyacı var) ve çok DAHA AZ
//	replika (aktarım hızına ihtiyacı yok) alabiliyor — redirect-svc'nin tam tersi düğmeler.
//	Tek bir binary bu iki ayarı aynı anda taşıyamazdı.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/bulutaysarac/linkly-ladder/09-database-scaling/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/09-database-scaling/internal/config"
	"github.com/bulutaysarac/linkly-ladder/09-database-scaling/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/09-database-scaling/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/09-database-scaling/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/09-database-scaling/internal/store"
	"github.com/bulutaysarac/linkly-ladder/09-database-scaling/internal/stream"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
)

var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cfg := config.Load()
	met := metrics.New(cfg.TrapMetricLabelCode)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	dbMet := store.NewDBMetrics(met.Registry())
	// Okuma servisi DAHA KÜÇÜK bir havuzla yaşar: çoğu istek önbellekten dönüyor ve replika
	// sayısı yüksek olacak (HPA). Havuz × replika, Postgres'in max_connections'ını aşmamalı (P02-02).
	primary, err := store.OpenWithMode(ctx, cfg.DatabaseURL, cfg.DBMaxConns, dbMet, cfg.TrapPreparedStatements)
	if err != nil {
		log.Error("primary'ye bağlanılamadı", "err", err)
		os.Exit(1)
	}
	defer primary.Close()
	met.BindPoolStats(primary.PoolStats)

	rdb := redis.NewClient(&redis.Options{
		Addr: cfg.RedisAddr, DialTimeout: cfg.RedisTimeout,
		ReadTimeout: cfg.RedisTimeout, WriteTimeout: cfg.RedisTimeout, PoolSize: 20,
	})
	defer rdb.Close()

	// Okuma/yazma ayrımı: DATABASE_URL_RO verilmişse okumalar replikalara gider.
	// Sticky pencere, yazma sonrası okumaları primary'ye yapıştırarak read-your-writes'ı korur.
	// İşaret PAYLAŞILAN (Redis): oluşturma api-svc'de, yönlendirme redirect-svc'de olduğu için
	// süreç içi bir işaret iki servis arasında hiçbir zaman görünmezdi (bkz. store/recent.go).
	var db store.Store = primary
	if cfg.DatabaseURLRO != "" {
		replica, rerr := store.OpenWithMode(ctx, cfg.DatabaseURLRO, cfg.DBMaxConns, dbMet, cfg.TrapPreparedStatements)
		if rerr != nil {
			// Replika yoksa PRIMARY'ye düş: okuma ölçeklenmesini kaybederiz, hizmeti değil.
			log.Warn("replikaya bağlanılamadı, okumalar primary'den yapılacak", "err", rerr)
		} else {
			defer replica.Close()
			sticky := cfg.StickyWindow
			if cfg.TrapNoSticky {
				sticky = 0
			}
			recent := store.NewSharedRecent(rdb, "linkly:ryw:", 2*time.Minute)
			db = store.NewReadWrite(primary, replica, sticky, store.NewRWMetrics(met.Registry()), recent)
			log.Info("okuma/yazma ayrımı açık", "sticky_window", sticky, "isaret", "redis")
		}
	}
	l2 := cache.NewRedis[store.Link](rdb, cache.Config{
		TTL: cfg.CacheTTL, NegativeTTL: cfg.CacheNegativeTTL, Layer: "l2",
		NoSingleflight: cfg.TrapNoSingleflight, NoNegative: cfg.TrapNoNegative, NoJitter: cfg.TrapNoJitter,
	}, cache.NewMetrics(met.Registry(), "l2"), "linkly:link:")
	cached := store.NewCached(db, l2)

	clicks, err := stream.NewProducer(strings.Split(cfg.KafkaBrokers, ","), cfg.KafkaTopic,
		cfg.ProducerMaxBuffered, stream.NewProducerMetrics(met.Registry()), log)
	if err != nil {
		log.Error("kafka producer kurulamadı", "err", err)
		os.Exit(1)
	}
	defer clicks.Close()

	// Paylaşılan limiter: limit artık pod başına değil, SİSTEM genelinde geçerli.
	dist := ratelimit.NewDistributed(ctx, rdb, ratelimit.DistConfig{
		Window:      cfg.RateLimitWindow,
		PerIP:       cfg.RateLimitPerIP,
		PerTenant:   cfg.RateLimitPerTenant,
		FailOpen:    cfg.RateLimitFailOpen,
		FixedWindow: cfg.TrapFixedWindow,
	}, ratelimit.NewMetrics(met.Registry()))

	api := httpapi.New(cfg, log, met, cached, version)
	api.SetDistributedLimiter(dist)
	api.SetClicks(clicks)
	srv := api.Server(api.APIHandler(ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst)))

	errCh := make(chan error, 1)
	go func() {
		log.Info("api-svc dinleniyor", "addr", cfg.Addr, "version", version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()
	api.SetReady(true)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-errCh:
		log.Error("sunucu hatası", "err", err)
		os.Exit(1)
	case <-stop:
	}
	api.SetReady(false)
	time.Sleep(cfg.ShutdownGrace / 4)
	shutCtx, sc := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer sc()
	_ = srv.Shutdown(shutCtx)
	flushCtx, fc := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	_ = clicks.Flush(flushCtx)
	fc()
	log.Info("temiz kapandı")
}
