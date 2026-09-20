// Package config — ortam değişkenlerinden ayar. Varsayılanlar üretimde güvenli tarafta olmalı:
// bir ayarı vermeyi unutmak, korumayı KAPATMAK anlamına gelmemeli.
package config

import (
	"os"
	"strconv"
	"time"
)

type Config struct {
	Addr              string
	ReadHeaderTimeout time.Duration // EN: slowloris guard  TR: yarım bağlantı koruması [Topic · Konu: Timeout]
	ReadTimeout       time.Duration
	WriteTimeout      time.Duration
	IdleTimeout       time.Duration
	HandlerTimeout    time.Duration // istek başına üst sınır
	ShutdownGrace     time.Duration
	MaxBodyBytes      int64
	CodeLength        int
	CodeMaxAttempts   int
	RateLimitPerSec   float64
	RateLimitBurst    int

	// TRAP_* — seviye içi alıştırmalar. Varsayılan olarak KAPALI; README §7 açıklıyor.
	TrapMetricLabelCode bool // kısa kodu metrik label'ı yap → kardinalite patlaması
	TrapLivenessStrict  bool // sağlık uçlarını iş zincirine sok (hız sınırı + timeout) → yük altında restart fırtınası
}

func Load() Config {
	return Config{
		Addr:              env("ADDR", ":8080"),
		ReadHeaderTimeout: envDur("READ_HEADER_TIMEOUT", 3*time.Second),
		ReadTimeout:       envDur("READ_TIMEOUT", 10*time.Second),
		WriteTimeout:      envDur("WRITE_TIMEOUT", 15*time.Second),
		IdleTimeout:       envDur("IDLE_TIMEOUT", 60*time.Second),
		HandlerTimeout:    envDur("HANDLER_TIMEOUT", 5*time.Second),
		ShutdownGrace:     envDur("SHUTDOWN_GRACE", 20*time.Second),
		MaxBodyBytes:      int64(envInt("MAX_BODY_BYTES", 8*1024)),
		CodeLength:        envInt("CODE_LENGTH", 7),
		CodeMaxAttempts:   envInt("CODE_MAX_ATTEMPTS", 5),
		RateLimitPerSec:   float64(envInt("RATE_LIMIT_PER_SEC", 200)),
		RateLimitBurst:    envInt("RATE_LIMIT_BURST", 400),

		TrapMetricLabelCode: envBool("TRAP_METRIC_LABEL_CODE", false),
		TrapLivenessStrict:  envBool("TRAP_LIVENESS_STRICT", false),
	}
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envInt(k string, d int) int {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil {
		return v
	}
	return d
}

func envDur(k string, d time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(k)); err == nil {
		return v
	}
	return d
}

func envBool(k string, d bool) bool {
	if v, err := strconv.ParseBool(os.Getenv(k)); err == nil {
		return v
	}
	return d
}
