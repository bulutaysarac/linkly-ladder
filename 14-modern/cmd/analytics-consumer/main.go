// Command analytics-consumer — tıklama olaylarını topic'ten okuyup veritabanına yazar.
//
// EN: A separate binary and a separate Deployment. This is what level 05's P05-03 asked for:
//
//	the writer no longer shares the redirect path's process, CPU limit or connection pool. It
//	can be scaled, restarted, rate limited and deployed on its own — and when it falls behind,
//	the only thing that suffers is analytics freshness.
//
// TR: Ayrı bir binary ve ayrı bir Deployment. 05'teki P05-03'ün istediği tam olarak buydu:
//
//	yazıcı artık redirect yolunun sürecini, CPU limitini ve bağlantı havuzunu paylaşmıyor.
//	Kendi başına ölçeklenebilir, yeniden başlatılabilir, sınırlanabilir ve dağıtılabilir —
//	geri kaldığında zarar gören tek şey analitiğin tazeliği olur.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/config"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/store"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/stream"
	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/tracing"
	_ "github.com/jackc/pgx/v5/stdlib"
)

var version = "dev"

// logLevel — LOG_LEVEL env'inden. debug seviyesi yüksek trafikte Loki'yi limitler (P11-05):
// gözlemlenebilirliğin de bir kapasitesi vardır ve onu aşmak, gözlemi tamamen kaybettirir.
func logLevel() slog.Level {
	switch os.Getenv("LOG_LEVEL") {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel()}))
	cfg := config.Load()
	met := metrics.New(false)

	// Tüketici de trace üretir: üreticinin header'a koyduğu bağlamı alır ve span'leri ona bağlar.
	// Asenkron sınırın iki yakası ancak böyle tek bir trace'te görünür (P11-02).
	shutdownTracing, terr := tracing.Setup(context.Background(), tracing.Config{
		Endpoint: cfg.OTLPEndpoint, ServiceName: "linkly-analytics",
		Version: version, SampleRatio: cfg.TraceSampleRatio, Enabled: cfg.TracingEnabled,
	})
	if terr != nil {
		log.Warn("tracing kurulamadı, izleme olmadan devam", "err", terr)
		shutdownTracing = func(context.Context) error { return nil }
	}
	defer func() {
		sctx, sc := context.WithTimeout(context.Background(), 5*time.Second)
		_ = shutdownTracing(sctx)
		sc()
	}()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	dbMet := store.NewDBMetrics(met.Registry())
	db, err := store.OpenWithMode(ctx, cfg.DatabaseURL, cfg.DBMaxConns, dbMet, cfg.TrapPreparedStatements)
	if err != nil {
		log.Error("veritabanına bağlanılamadı", "err", err)
		os.Exit(1)
	}
	defer db.Close()
	met.BindPoolStats(db.PoolStats)

	cons, err := stream.NewConsumer(stream.ConsumerConfig{
		Brokers:           strings.Split(cfg.KafkaBrokers, ","),
		Topic:             cfg.KafkaTopic,
		DLQTopic:          cfg.KafkaDLQTopic,
		Group:             cfg.KafkaGroup,
		BatchTimeout:      cfg.ConsumerBatchTimeout,
		WriteTimeout:      cfg.ClickWriteTimeout,
		CommitBeforeWrite: cfg.TrapCommitBeforeWrite,
		NoDLQ:             cfg.TrapNoDLQ,
	}, db, stream.NewConsumerMetrics(met.Registry()), log)
	if err != nil {
		log.Error("tüketici kurulamadı", "err", err)
		os.Exit(1)
	}
	defer cons.Close()

	// Tüketicinin de /metrics ve /healthz'i olmalı: gözlemlenemeyen bir arka plan süreci,
	// sessizce durduğunda kimsenin fark etmediği süreçtir.
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", met.Handler())
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	srv := &http.Server{Addr: cfg.Addr, Handler: mux, ReadHeaderTimeout: 3 * time.Second}
	go func() { _ = srv.ListenAndServe() }()

	if cfg.TrapCommitBeforeWrite {
		log.Warn("TRAP_COMMIT_BEFORE_WRITE açık: commit yazmadan önce → veri kaybı (README §7)")
	}
	if cfg.TrapNoDLQ {
		log.Warn("TRAP_NO_DLQ açık: bozuk mesaj DLQ'ya gitmeyecek (README §7)")
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		log.Info("tüketici başladı", "version", version, "topic", cfg.KafkaTopic,
			"group", cfg.KafkaGroup, "brokers", cfg.KafkaBrokers)
		if err := cons.Run(ctx); err != nil {
			log.Error("tüketici hatası", "err", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Info("kapatma sinyali, işlenmekte olan parti bitiriliyor")
	cancel()
	select {
	case <-done:
	case <-time.After(cfg.ShutdownGrace):
		log.Warn("tüketici zamanında durmadı")
	}
	shutCtx, sc := context.WithTimeout(context.Background(), 5*time.Second)
	defer sc()
	_ = srv.Shutdown(shutCtx)
	log.Info("temiz kapandı")
}
