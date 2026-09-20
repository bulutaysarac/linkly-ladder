// Command api-svc — yönetim yolu: oluşturma, silme, listeleme, istatistik.
//
// EN: Low traffic, writes, and queries that are allowed to take 100 ms. Because it is a separate
//     deployment it can have a bigger connection pool per pod (it needs the database) and a much
//     smaller replica count (it does not need the throughput) — the exact opposite knobs from
//     redirect-svc. One binary could never have both settings at once.
// TR: Düşük trafik, yazma ve 100 ms sürmesine izin verilen sorgular. Ayrı bir deployment olduğu
//     için pod başına DAHA BÜYÜK bir bağlantı havuzu (veritabanına ihtiyacı var) ve çok DAHA AZ
//     replika (aktarım hızına ihtiyacı yok) alabiliyor — redirect-svc'nin tam tersi düğmeler.
//     Tek bir binary bu iki ayarı aynı anda taşıyamazdı.
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

	"github.com/bulutaysarac/linkly-ladder/07-services-autoscaling/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/07-services-autoscaling/internal/config"
	"github.com/bulutaysarac/linkly-ladder/07-services-autoscaling/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/07-services-autoscaling/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/07-services-autoscaling/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/07-services-autoscaling/internal/store"
	"github.com/bulutaysarac/linkly-ladder/07-services-autoscaling/internal/stream"
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
	db, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns, dbMet)
	if err != nil {
		log.Error("veritabanına bağlanılamadı", "err", err)
		os.Exit(1)
	}
	defer db.Close()
	met.BindPoolStats(db.PoolStats)

	rdb := redis.NewClient(&redis.Options{
		Addr: cfg.RedisAddr, DialTimeout: cfg.RedisTimeout,
		ReadTimeout: cfg.RedisTimeout, WriteTimeout: cfg.RedisTimeout, PoolSize: 20,
	})
	defer rdb.Close()
	l2 := cache.NewRedis[store.Link](rdb, cache.Config{
		TTL: cfg.CacheTTL, NegativeTTL: cfg.CacheNegativeTTL, Layer: "l2",
		NoNegative: cfg.TrapNoNegative, NoJitter: cfg.TrapNoJitter,
	}, cache.NewMetrics(met.Registry(), "l2"), "linkly:link:")
	cached := store.NewCached(db, l2)

	clicks, err := stream.NewProducer(strings.Split(cfg.KafkaBrokers, ","), cfg.KafkaTopic,
		cfg.ProducerMaxBuffered, stream.NewProducerMetrics(met.Registry()), log)
	if err != nil {
		log.Error("kafka producer kurulamadı", "err", err)
		os.Exit(1)
	}
	defer clicks.Close()

	api := httpapi.New(cfg, log, met, cached, version)
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
