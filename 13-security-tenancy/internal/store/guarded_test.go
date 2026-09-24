package store

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"

	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/cache"
	"github.com/bulutaysarac/linkly-ladder/13-security-tenancy/internal/resilience"
)

// Redis KENDİ guard'ının arkasında: kesinti Redis devresini açar, degrade "no_cache" işaretlenir ve
// okumalar veritabanından cevaplanmaya devam eder; Postgres'in devresi ve degrade modu etkilenmez
// (P10-02).
func TestRedisOutageTripsItsOwnGuardAndFallsBackToDB(t *testing.T) {
	ctx := context.Background()
	reg := prometheus.NewRegistry()
	g := resilience.NewGuard(resilience.Config{
		Name: "redis", FailureThreshold: 3, OpenDuration: time.Hour, Timeout: 200 * time.Millisecond,
	}, resilience.NewMetrics(reg))
	var mu sync.Mutex
	modes := map[string]bool{}
	degrade := func(m string, on bool) { mu.Lock(); modes[m] = on; mu.Unlock() }

	// Kimsenin dinlemediği bir port: her çağrı "bağlantı reddedildi" ile hemen düşer.
	rdb := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", DialTimeout: 100 * time.Millisecond, MaxRetries: -1})
	defer rdb.Close()
	l2 := cache.NewRedis[Link](rdb, cache.Config{
		TTL: time.Minute, NegativeTTL: time.Second, Layer: "l2", Guard: GuardCall(g, "no_cache", degrade),
	}, cache.NewMetrics(reg, "l2"), "test:")
	db := NewFake()
	if err := db.CreateUnique(ctx, &Link{Code: "abc1234", URL: "https://e", Tenant: "t"}); err != nil {
		t.Fatal(err)
	}
	c := NewCached(db, l2)
	for i := 0; i < 6; i++ {
		l, err := c.Get(ctx, "abc1234")
		if err != nil || l.URL != "https://e" {
			t.Fatalf("Redis yokken veritabanına düşülmeliydi (fail-open): %v", err)
		}
	}
	if g.State() != resilience.Open {
		t.Fatalf("Redis kesintisi Redis devresini açmalıydı, durum: %v", g.State())
	}
	mu.Lock()
	defer mu.Unlock()
	if !modes["no_cache"] {
		t.Fatal(`degrade "no_cache" işaretlenmedi`)
	}
	if _, touched := modes["cache_only"]; touched {
		t.Fatal("Redis kesintisi Postgres'in degrade modunu değiştirmemeli")
	}
}
