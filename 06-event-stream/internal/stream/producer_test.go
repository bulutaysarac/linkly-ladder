package stream

import (
	"io"
	"log/slog"
	"net"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Broker cevap vermiyorken Record() BLOKLAMAMALI ve sınırı UYGULAMANIN sayacı koymalı.
//
// EN: the limit here (20,000) is deliberately ABOVE franz-go's default of 10,000. If the client
//
//	kept its default, the 10,001st Record() would block inside Produce forever — the redirect
//	request would hang — and the app's own drop counter would never fire. The "broker" accepts
//	TCP and never answers, so nothing leaves the buffer during the test.
//
// TR: buradaki sınır (20.000) bilerek franz-go'nun varsayılanı olan 10.000'in ÜSTÜNDE. İstemci
//
//	varsayılanında kalsaydı 10.001. Record() Produce'un içinde sonsuza kadar bloklanırdı —
//	redirect isteği asılı kalırdı — ve uygulamanın düşürme sayacı hiç tetiklenmezdi. "Broker"
//	TCP'yi kabul eder ve hiç cevap vermez; test boyunca tampondan hiçbir şey çıkmaz.
func TestRecordNeverBlocksAndAppLimitIsTheEffectiveOne(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		var held []net.Conn
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

	const limit, extra = 20000, 50
	reg := prometheus.NewRegistry()
	p, err := NewProducer([]string{ln.Addr().String()}, "clicks", limit, NewProducerMetrics(reg),
		slog.New(slog.NewJSONHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < limit+extra; i++ {
			p.Record("abc1234")
		}
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatalf("Record() bloklandı: %d kayıttan sonra ilerlemiyor — istek yolu bekler", p.Buffered())
	}
	if got := p.Buffered(); got != limit {
		t.Fatalf("tamponda %d kayıt bekleniyordu (uygulamanın sınırı), %d var", limit, got)
	}
	if got := counter(t, reg, "producer_records_total", "dropped"); got != extra {
		t.Fatalf("sınırı aşan %d kayıt düşürülmeliydi, dropped=%v", extra, got)
	}
}
