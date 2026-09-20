package analytics

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

type fakeWriter struct {
	mu      sync.Mutex
	counts  map[string]int64
	batches int
	err     error
	delay   time.Duration
}

func newFakeWriter() *fakeWriter { return &fakeWriter{counts: map[string]int64{}} }

func (f *fakeWriter) WriteClicks(ctx context.Context, counts map[string]int64) error {
	if f.delay > 0 {
		select {
		case <-time.After(f.delay):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	f.batches++
	for k, v := range counts {
		f.counts[k] += v
	}
	return nil
}

func (f *fakeWriter) total() int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	var t int64
	for _, v := range f.counts {
		t += v
	}
	return t
}

func newCollector(t *testing.T, cfg Config, w Writer) *Collector {
	t.Helper()
	if cfg.WriteTimeout == 0 {
		cfg.WriteTimeout = time.Second
	}
	c := New(cfg, w, NewMetrics(prometheus.NewRegistry()), slog.New(slog.NewJSONHandler(io.Discard, nil)))
	c.Start()
	t.Cleanup(c.Stop)
	return c
}

// Asıl vaat: Record ASLA bloklamaz — kuyruk dolu olsa bile.
func TestRecordNeverBlocks(t *testing.T) {
	w := newFakeWriter()
	w.delay = 500 * time.Millisecond // yazıcı yavaş: kuyruk dolacak
	c := newCollector(t, Config{QueueSize: 10, BatchSize: 5, FlushInterval: time.Hour}, w)

	done := make(chan struct{})
	go func() {
		for i := 0; i < 10000; i++ {
			c.Record("hot")
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("Record bloklandı — redirect yolu yine veritabanını bekliyor demektir")
	}
}

// Dolu kuyruk DÜŞÜRÜR ve düşürmeyi SAYAR (görünmez kayıp yok).
func TestFullQueueDropsAndCounts(t *testing.T) {
	w := newFakeWriter()
	w.delay = time.Second
	reg := prometheus.NewRegistry()
	m := NewMetrics(reg)
	c := New(Config{QueueSize: 5, BatchSize: 100, FlushInterval: time.Hour, WriteTimeout: time.Second},
		w, m, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	c.Start()
	defer c.Stop()
	for i := 0; i < 500; i++ {
		c.Record("k")
	}
	dropped := counterValue(t, reg, "analytics_events_total", "dropped")
	if dropped == 0 {
		t.Fatal("kuyruk dolduğu hâlde düşürme sayılmadı — kayıp görünmez olur")
	}
}

// Toplama: aynı koda gelen N tıklama TEK satır güncellemesi olmalı (P02-08'in çözümü).
func TestAggregatesSameCodeIntoOneWrite(t *testing.T) {
	w := newFakeWriter()
	c := newCollector(t, Config{QueueSize: 1000, BatchSize: 1000, FlushInterval: 50 * time.Millisecond}, w)
	for i := 0; i < 500; i++ {
		c.Record("same")
	}
	waitFor(t, func() bool { return w.total() >= 500 })
	w.mu.Lock()
	batches := w.batches
	w.mu.Unlock()
	if batches > 5 {
		t.Fatalf("500 tıklama %d toplu yazma üretti — toplama çalışmıyor", batches)
	}
}

// Kapanışta kuyrukta kalanlar YAZILMALI (aksi hâlde her dağıtım veri kaybı demektir).
func TestStopDrainsPendingEvents(t *testing.T) {
	w := newFakeWriter()
	c := New(Config{QueueSize: 1000, BatchSize: 10000, FlushInterval: time.Hour, WriteTimeout: time.Second},
		w, NewMetrics(prometheus.NewRegistry()), slog.New(slog.NewJSONHandler(io.Discard, nil)))
	c.Start()
	for i := 0; i < 300; i++ {
		c.Record("drain-me")
	}
	c.Stop()
	if got := w.total(); got != 300 {
		t.Fatalf("drain sonrası %d tıklama yazıldı, 300 bekleniyordu — kapanışta kayıp var", got)
	}
}

// Yazma hatası olayları SESSİZCE yutmamalı.
func TestWriteErrorIsCounted(t *testing.T) {
	w := newFakeWriter()
	w.err = errors.New("db down")
	reg := prometheus.NewRegistry()
	m := NewMetrics(reg)
	c := New(Config{QueueSize: 100, BatchSize: 10, FlushInterval: 20 * time.Millisecond, WriteTimeout: time.Second},
		w, m, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	c.Start()
	for i := 0; i < 50; i++ {
		c.Record("k")
	}
	time.Sleep(200 * time.Millisecond)
	c.Stop()
	if counterValue(t, reg, "analytics_events_total", "write_error") == 0 {
		t.Fatal("yazma hatası sayılmadı")
	}
}

// TRAP: sınırsız kuyruk hiç düşürmez — ve bu iyi bir şey değil, bellek sınırsız büyür.
func TestUnboundedTrapNeverDropsButGrows(t *testing.T) {
	w := newFakeWriter()
	w.delay = time.Second
	reg := prometheus.NewRegistry()
	m := NewMetrics(reg)
	c := New(Config{QueueSize: 5, BatchSize: 100, FlushInterval: time.Hour, WriteTimeout: time.Second,
		Unbounded: true}, w, m, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	c.Start()
	defer c.Stop()
	for i := 0; i < 5000; i++ {
		c.Record("k")
	}
	if counterValue(t, reg, "analytics_events_total", "dropped") != 0 {
		t.Fatal("TRAP açıkken düşürme olmamalıydı")
	}
	if c.Depth() < 4000 {
		t.Fatalf("kuyruk büyümeliydi, derinlik %d — sınırsız kuyruk ertelenmiş çöküştür", c.Depth())
	}
}

func counterValue(t *testing.T, reg *prometheus.Registry, name, label string) float64 {
	t.Helper()
	fams, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range fams {
		if f.GetName() != name {
			continue
		}
		for _, mt := range f.GetMetric() {
			for _, l := range mt.GetLabel() {
				if l.GetValue() == label {
					return mt.GetCounter().GetValue()
				}
			}
		}
	}
	return 0
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("koşul zaman aşımına uğradı")
}
