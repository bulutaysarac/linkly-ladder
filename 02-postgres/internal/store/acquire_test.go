package store

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Bağlantı alma süresi GERÇEK beklemeyi mi ölçüyor? Veritabanı GEREKTİRMEZ.
//
// EN: The "server" below accepts TCP and never answers, so acquiring a connection blocks until the
//
//	caller's deadline — a wait that happens entirely inside QueryRow. If the metric does not see
//	~300 ms here, it cannot see pool pressure either.
//
// TR: Aşağıdaki "sunucu" TCP'yi kabul eder ve hiç cevap vermez: bağlantı almak, çağıranın süresi
//
//	dolana kadar bekler — ve bu bekleme tamamen QueryRow'un İÇİNDE olur. Metrik burada ~300 ms
//	görmüyorsa havuz baskısını da göremez.
func TestAcquireWaitMeasuresTheRealWait(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		var held []net.Conn // kabul et, cevap verme, kapatma
		defer func() {
			for _, c := range held {
				_ = c.Close()
			}
		}()
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			held = append(held, c)
		}
	}()
	t.Cleanup(func() { _ = ln.Close() })

	reg := prometheus.NewRegistry()
	m := NewDBMetrics(reg)
	// connect_timeout: havuzun arka planda açmaya çalıştığı bağlantılar da sınırlı sürsün (Close beklemesin).
	db, err := Open(context.Background(), "postgres://u:p@"+ln.Addr().String()+"/db?sslmode=disable&connect_timeout=1", 4, m)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)

	const wait = 300 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	if _, err := db.Get(ctx, "abc1234"); err == nil {
		t.Fatal("cevap vermeyen sunucuda sorgu başarılı olmamalıydı")
	}

	var n uint64
	var sum float64
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() == "db_pool_acquire_duration_seconds" {
			n, sum = mf.GetMetric()[0].GetHistogram().GetSampleCount(), mf.GetMetric()[0].GetHistogram().GetSampleSum()
		}
	}
	if n != 1 {
		t.Fatalf("tek bir alım bekleniyordu, %d gözlem var", n)
	}
	if sum < (wait - 50*time.Millisecond).Seconds() {
		t.Fatalf("alım ~%v bekledi ama metrik %.4f sn gördü — beklemeyi ölçmüyor", wait, sum)
	}
}
