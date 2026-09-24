package resilience

import (
	"context"
	"fmt"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

// netTimeout — go-redis'in soket süre sınırı aşıldığında döndürdüğü türden bir hata.
type netTimeout struct{}

func (netTimeout) Error() string   { return "i/o timeout" }
func (netTimeout) Timeout() bool   { return true }
func (netTimeout) Temporary() bool { return true }

// İstemcinin kendi süre sınırı (context.DeadlineExceeded DEĞİL, net.Error) da timeout sayılmalı;
// yoksa Redis timeout'ları "error" serisine düşer ve timeout serisi tam da o an sıfırda kalır.
func TestSocketTimeoutCountsAsTimeout(t *testing.T) {
	reg := prometheus.NewRegistry()
	g := NewGuard(Config{Name: "redis", FailureThreshold: 100}, NewMetrics(reg))
	_ = g.Do(context.Background(), func(context.Context) error { return fmt.Errorf("redis: %w", netTimeout{}) })
	if got := requests(t, reg, "redis", "timeout"); got != 1 {
		t.Fatalf("soket timeout'u timeout sayılmadı: %v", got)
	}
	if got := requests(t, reg, "redis", "error"); got != 0 {
		t.Fatalf("soket timeout'u error sayıldı: %v", got)
	}
}

func requests(t *testing.T, reg *prometheus.Registry, dep, result string) float64 {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() != "dependency_requests_total" {
			continue
		}
		for _, m := range mf.GetMetric() {
			l := map[string]string{}
			for _, lp := range m.GetLabel() {
				l[lp.GetName()] = lp.GetValue()
			}
			if l["dep"] == dep && l["result"] == result {
				return m.GetCounter().GetValue()
			}
		}
	}
	return 0
}
