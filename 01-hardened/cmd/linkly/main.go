// Command linkly — seviye 01, "tek süreç ama düzgün".
//
// EN: Same single process, same in-memory store as level 00 — but with the disciplines that stop it
//     from crashing, lying, or losing requests. The most instructive part of this file is the last
//     twenty lines: the shutdown ORDER. Everything above is construction; below Shutdown is where
//     requests get dropped if you get the order wrong.
// TR: 00 ile aynı tek süreç, aynı bellek içi store — ama çökmesini, yalan söylemesini ve istek
//     kaybetmesini engelleyen disiplinlerle. Bu dosyanın en öğretici kısmı son yirmi satırı:
//     kapatma SIRASI. Yukarısı kurulum; Shutdown'ın altı, sırayı yanlış yaparsan isteklerin
//     düştüğü yer.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/config"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/httpapi"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/metrics"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/ratelimit"
	"github.com/bulutaysarac/linkly-ladder/01-hardened/internal/store"
)

var version = "dev"

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cfg := config.Load()
	met := metrics.New(cfg.TrapMetricLabelCode)
	st := store.NewMemory()
	rl := ratelimit.New(cfg.RateLimitPerSec, cfg.RateLimitBurst)

	api := httpapi.New(cfg, log, met, st, version)
	srv := api.Server(api.Handler(rl))

	if cfg.TrapMetricLabelCode {
		log.Warn("TRAP_METRIC_LABEL_CODE açık: kısa kod metrik label'ı — kardinalite patlayacak (README §7)")
	}
	if cfg.TrapLivenessStrict {
		log.Warn("TRAP_LIVENESS_STRICT açık: liveness readiness gibi davranacak (README §7)")
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("dinleniyor", "addr", cfg.Addr, "version", version)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	// Sunucu soketi açıldıktan SONRA hazır ilan et: readyz "trafik alabilirim" demek.
	api.SetReady(true)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-errCh:
		log.Error("sunucu hatası", "err", err)
		os.Exit(1)
	case sig := <-stop:
		log.Info("kapatma sinyali", "signal", sig.String())
	}

	// ---- Kapatma sırası ----
	// EN: 1) Fail readiness FIRST and keep serving. Kubernetes removes the pod from Endpoints
	//        asynchronously; if you stop serving before that propagates, in-flight and freshly
	//        routed requests get connection-refused. The sleep is not laziness — it is the
	//        propagation window. This is exactly the 5xx burst measured in P00-04.
	//     2) THEN Shutdown: stop accepting new connections, let in-flight requests finish.
	//     3) Only then exit.
	// TR: 1) ÖNCE readiness'i düşür ama hizmet vermeye DEVAM et. Kubernetes pod'u Endpoints'ten
	//        asenkron çıkarır; bu yayılmadan hizmeti kesersen işlenmekte olan ve yeni yönlenen
	//        istekler bağlantı reddi alır. Buradaki bekleme tembellik değil, yayılma penceresidir.
	//        P00-04'te ölçülen 5xx dalgası tam olarak budur.
	//     2) SONRA Shutdown: yeni bağlantı kabul etmeyi bırak, işlenmekteki istekleri bitir.
	//     3) Ancak ondan sonra çık.
	// [Topic · Konu: Graceful shutdown, endpoint yayılımı]
	api.SetReady(false)
	log.Info("readiness düşürüldü, endpoint yayılımı bekleniyor", "wait", cfg.ShutdownGrace/4)
	time.Sleep(cfg.ShutdownGrace / 4)

	ctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Error("graceful shutdown tamamlanamadı", "err", err)
		os.Exit(1)
	}
	log.Info("temiz kapandı", "links", st.Len())
}
