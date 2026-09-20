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

	DatabaseURL      string
	DBMaxConns       int32
	DBQueryTimeout   time.Duration
	StatementTimeout string // sunucu tarafı ifade timeout'u; boş = KAPALI (bkz. P02-06)
	MigrateTarget    int64  // hangi migration sürümüne kadar koşulsun (P02-05 alıştırması)
	ListLimit        int

	RedisAddr        string
	RedisTimeout     time.Duration
	KafkaBrokers         string
	KafkaTopic           string
	KafkaDLQTopic        string
	KafkaGroup           string
	ProducerMaxBuffered  int
	ConsumerBatchTimeout time.Duration
	QueueSize        int
	BatchSize        int
	FlushInterval    time.Duration
	ClickWriteTimeout time.Duration
	StatsDays        int
	CacheCapacity    int
	CacheTTL         time.Duration
	CacheNegativeTTL time.Duration

	// TRAP_* — seviye içi alıştırmalar. Varsayılan olarak KAPALI; README §7 açıklıyor.
	TrapMetricLabelCode bool // kısa kodu metrik label'ı yap → kardinalite patlaması
	TrapLivenessStrict  bool // sağlık uçlarını iş zincirine sok (hız sınırı + timeout) → yük altında restart fırtınası
	TrapReadyzChecksDB  bool // readiness'a DB kontrolü koy → DB kesintisinde TÜM pod'lar trafikten düşer (P02-10)
	TrapMigrateInMain   bool // migration'ı her pod kendi main'inde koşsun → N replikada yarış (P02-07)
	TrapNoSingleflight  bool // stampede koruması kapalı → TTL dolan sıcak anahtar DB'yi döver (P03-05)
	TrapNoNegative      bool // negatif önbellek kapalı → var olmayan kod taraması hep DB'ye iner (P03-06)
	TrapNoJitter        bool // TTL jitter kapalı → tüm anahtarlar aynı anda dolar (P04-04)
	TrapDebugKeys       bool // /debug/keys ucu KEYS * çalıştırsın → Redis'i tek komutla kilitle (P04-07)
	TrapUpdateDelayMs   int  // DB update ile önbellek silme arasına gecikme koy → cache-aside yarışı (P04-05)
	TrapUnboundedQueue  bool // sınırsız analitik kuyruğu → düşürme yerine OOM (P05-02)
	TrapRedirect301     bool // 302 yerine 301 → tarayıcı önbellekler, tıklama hiç sayılmaz (P05-06)
	TrapCommitBeforeWrite bool // offset'i yazmadan önce commit et → tüketici ölürse veri kaybı (P06-01)
	TrapNoDLQ             bool // bozuk mesajı DLQ'ya taşıma → crashloop ve sonsuz lag (P06-04)
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

		DatabaseURL:      env("DATABASE_URL", "postgres://linkly:linkly@postgres:5432/linkly?sslmode=disable"),
		DBMaxConns:       int32(envInt("DB_MAX_CONNS", 25)),
		DBQueryTimeout:   envDur("DB_QUERY_TIMEOUT", 3*time.Second),
		StatementTimeout: env("STATEMENT_TIMEOUT", ""), // BİLEREK boş: P02-06 bunun yokluğunu ölçüyor
		MigrateTarget:    int64(envInt("MIGRATE_TARGET", 1)), // 2 = tenant index'i (P02-05 çözümü)
		ListLimit:        envInt("LIST_LIMIT", 100),

		RedisAddr:        env("REDIS_ADDR", "redis:6379"),
		RedisTimeout:     envDur("REDIS_TIMEOUT", 500*time.Millisecond),
		KafkaBrokers:         env("KAFKA_BROKERS", "redpanda:9092"),
		KafkaTopic:           env("KAFKA_TOPIC", "clicks"),
		KafkaDLQTopic:        env("KAFKA_DLQ_TOPIC", "clicks-dlq"),
		KafkaGroup:           env("KAFKA_GROUP", "analytics"),
		ProducerMaxBuffered:  envInt("PRODUCER_MAX_BUFFERED", 50000),
		ConsumerBatchTimeout: envDur("CONSUMER_BATCH_TIMEOUT", 500*time.Millisecond),
		QueueSize:        envInt("ANALYTICS_QUEUE_SIZE", 20000),
		BatchSize:        envInt("ANALYTICS_BATCH_SIZE", 500),
		FlushInterval:    envDur("ANALYTICS_FLUSH_INTERVAL", time.Second),
		ClickWriteTimeout: envDur("ANALYTICS_WRITE_TIMEOUT", 5*time.Second),
		StatsDays:        envInt("STATS_DAYS", 30),
		CacheCapacity:    envInt("CACHE_CAPACITY", 50000),
		CacheTTL:         envDur("CACHE_TTL", 60*time.Second),
		CacheNegativeTTL: envDur("CACHE_NEGATIVE_TTL", 10*time.Second),

		TrapMetricLabelCode: envBool("TRAP_METRIC_LABEL_CODE", false),
		TrapLivenessStrict:  envBool("TRAP_LIVENESS_STRICT", false),
		TrapReadyzChecksDB:  envBool("TRAP_READYZ_CHECKS_DB", false),
		TrapMigrateInMain:   envBool("TRAP_MIGRATE_IN_MAIN", false),
		TrapNoSingleflight:  envBool("TRAP_NO_SINGLEFLIGHT", false),
		TrapNoNegative:      envBool("TRAP_NO_NEGATIVE_CACHE", false),
		TrapNoJitter:        envBool("TRAP_NO_TTL_JITTER", false),
		TrapDebugKeys:       envBool("TRAP_DEBUG_KEYS", false),
		TrapUpdateDelayMs:   envInt("TRAP_UPDATE_DELAY_MS", 0),
		TrapUnboundedQueue:  envBool("TRAP_UNBOUNDED_QUEUE", false),
		TrapRedirect301:     envBool("TRAP_REDIRECT_301", false),
		TrapCommitBeforeWrite: envBool("TRAP_COMMIT_BEFORE_WRITE", false),
		TrapNoDLQ:             envBool("TRAP_NO_DLQ", false),
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
