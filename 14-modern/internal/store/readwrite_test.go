package store

import (
	"context"
	"errors"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

// Read-your-writes ihlali = replikaya giden okuma az önce yazılan kodu BULAMADI (404).
// Replikanın hata vermesi (zaman aşımı, bağlantı) başka bir arızadır ve ihlal sayılmamalı:
// yavaş replika ile bayat replika farklı şeylerdir (P09-01).
func TestRYWViolationCountsOnlyNotFound(t *testing.T) {
	primary, replica := NewFake(), NewFake()
	reg := prometheus.NewRegistry()
	m := NewRWMetrics(reg)
	rw := NewReadWrite(primary, replica, 0, m, NewLocalRecent()) // yapışkan okuma KAPALI
	ctx := context.Background()
	if err := rw.CreateUnique(ctx, &Link{Code: "abc1234", URL: "https://e", Tenant: "t"}); err != nil {
		t.Fatal(err)
	}
	// Replika satırı henüz almadı → 404 → ihlal.
	if _, err := rw.Get(ctx, "abc1234"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("replikada satır yokken ErrNotFound bekleniyordu: %v", err)
	}
	if got := counterValue(t, reg, "ryw_violations_total"); got != 1 {
		t.Fatalf("bayat okuma ihlal sayılmalıydı: %v", got)
	}
	// Replika YAVAŞ (zaman aşımı) → hata, ama ihlal DEĞİL.
	replica.FailWith = context.DeadlineExceeded
	if _, err := rw.Get(ctx, "abc1234"); err == nil {
		t.Fatal("replika hatası yutuldu")
	}
	if got := counterValue(t, reg, "ryw_violations_total"); got != 1 {
		t.Fatalf("zaman aşımı RYW ihlali sayıldı (sayaç=%v): yavaş replika bayat replika değildir", got)
	}
}

// counterValue — kayıtlı bir sayacın değeri (testutil'in ek bağımlılıklarını çekmemek için elle).
func counterValue(t *testing.T, reg *prometheus.Registry, name string) float64 {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() == name {
			return mf.GetMetric()[0].GetCounter().GetValue()
		}
	}
	t.Fatalf("%s kayıtlı değil", name)
	return 0
}
