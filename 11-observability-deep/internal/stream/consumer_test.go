package stream

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/twmb/franz-go/pkg/kgo"
)

// counter — kayıt defterinden `name{result="..."}` değerini oku (go.mod'a yeni bağımlılık eklemeden).
func counter(t *testing.T, reg *prometheus.Registry, name, result string) float64 {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() != name {
			continue
		}
		for _, m := range mf.GetMetric() {
			for _, l := range m.GetLabel() {
				if l.GetName() == "result" && l.GetValue() == result {
					return m.GetCounter().GetValue()
				}
			}
		}
	}
	return 0
}

// TRAP_NO_DLQ: bozuk kayıt boru hattını REHİN ALMALI — ne atlanmalı ne de ötesine geçilmeli.
// Kaydı `error` sayıp dönmek, tüketiciyi sıradaki partiye geçirir ve P06-04'ün
// "tek bozuk kayıt her şeyi durdurur" iddiasını üretilemez kılar.
func TestNoDLQBlocksOnPoisonUntilShutdown(t *testing.T) {
	reg := prometheus.NewRegistry()
	m := NewConsumerMetrics(reg)
	c := &Consumer{cfg: ConsumerConfig{NoDLQ: true}, m: m,
		log: slog.New(slog.NewJSONHandler(io.Discard, nil)), poisonRetry: 10 * time.Millisecond}
	recs := []*kgo.Record{{Value: []byte("bu-json-degil"), Partition: 0, Offset: 42}}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	if c.handlePoison(ctx, recs) {
		t.Fatal("DLQ kapalıyken tüketici bozuk kaydın ötesine geçmemeli")
	}
	if el := time.Since(start); el < 180*time.Millisecond {
		t.Fatalf("handlePoison %v sonra döndü — kapanışa kadar takılı kalmalıydı", el)
	}
	// Aynı kayıt tekrar tekrar denendi: `error` sayacı kayıt sayısının katları kadar büyür.
	if got := counter(t, reg, "consumer_records_total", "error"); got < 5 {
		t.Fatalf("bozuk kayıt yeniden denenmedi: error=%v", got)
	}
	if got := counter(t, reg, "consumer_records_total", "dlq"); got != 0 {
		t.Fatalf("DLQ kapalıyken dlq=%v", got)
	}
}

// fakeKafka — broker'sız istemci. Partileri sırayla verir ve her commit'te, CommitUncommittedOffsets'in
// o an commit edeceği HER kaydın (o ana kadar okunan her şeyin) veritabanına yazılmış olup olmadığını
// kaydeder. Yazılmamış bir kaydın ötesine geçen commit, o kaydın bir daha okunmaması demektir.
type fakeKafka struct {
	mu        sync.Mutex
	batches   [][]*kgo.Record
	polled    []*kgo.Record
	commits   int
	written   func(id string) bool
	unwritten []string // commit edildiği anda veritabanında olmayan olay kimlikleri
}

func (f *fakeKafka) PollFetches(ctx context.Context) kgo.Fetches {
	f.mu.Lock()
	if len(f.batches) == 0 {
		f.mu.Unlock()
		<-ctx.Done()
		return kgo.NewErrFetch(ctx.Err())
	}
	b := f.batches[0]
	f.batches = f.batches[1:]
	f.polled = append(f.polled, b...)
	f.mu.Unlock()
	return kgo.Fetches{{Topics: []kgo.FetchTopic{{Topic: "clicks",
		Partitions: []kgo.FetchPartition{{Partition: 0, Records: b}}}}}}
}

func (f *fakeKafka) CommitUncommittedOffsets(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.commits++
	for _, r := range f.polled {
		var ev ClickEvent
		_ = json.Unmarshal(r.Value, &ev)
		if !f.written(ev.EventID) {
			f.unwritten = append(f.unwritten, ev.EventID)
		}
	}
	return nil
}

func (f *fakeKafka) Produce(context.Context, *kgo.Record, func(*kgo.Record, error)) {}
func (f *fakeKafka) Close()                                                         {}

// flakySink — `failID`'yi içeren partiyi ilk `failTimes` denemede reddeden veritabanı (kesinti).
type flakySink struct {
	mu        sync.Mutex
	failID    string
	failTimes int
	attempts  map[string]int // partinin ilk olay kimliği → yazma denemesi
	written   map[string]bool
}

func (s *flakySink) WriteClicksIdempotent(_ context.Context, _ map[string]int64, ids []string) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.attempts[ids[0]]++
	for _, id := range ids {
		if id == s.failID && s.failTimes > 0 {
			s.failTimes--
			return 0, errors.New("veritabanına ulaşılamıyor")
		}
	}
	n := 0
	for _, id := range ids {
		if !s.written[id] {
			s.written[id] = true
			n++
		}
	}
	return n, nil
}

func (s *flakySink) has(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.written[id]
}

func batchOf(t *testing.T, first int64, ids ...string) []*kgo.Record {
	t.Helper()
	recs := make([]*kgo.Record, 0, len(ids))
	for i, id := range ids {
		v, err := ClickEvent{Version: CurrentVersion, EventID: id, Code: "abc1234", At: time.Now().UTC()}.Marshal()
		if err != nil {
			t.Fatal(err)
		}
		recs = append(recs, &kgo.Record{Topic: "clicks", Partition: 0, Offset: first + int64(i), Value: v})
	}
	return recs
}

// runConsumer — tüketiciyi `until` doğru olana (ya da 2 sn dolana) kadar koştur, sonra kapat.
func runConsumer(t *testing.T, c *Consumer, until func() bool) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	deadline := time.Now().Add(2 * time.Second)
	for !until() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func newTestConsumer(cfg ConsumerConfig, cl kafkaClient, sink Sink, reg *prometheus.Registry) *Consumer {
	cfg.WriteTimeout = time.Second
	return &Consumer{cl: cl, cfg: cfg, sink: sink, m: NewConsumerMetrics(reg),
		log: slog.New(slog.NewJSONHandler(io.Discard, nil)), writeRetry: 5 * time.Millisecond}
}

// Yazılamayan parti YERİNDE yeniden denenir ve hiçbir commit onun ötesine geçmez.
// CommitUncommittedOffsets o ana kadar okunan her şeyi commit eder: başarısız partiyi atlayıp
// sonrakini okuyan bir tüketici, sonraki sağlam partiyle başarısız olanı da commit eder ve o
// tıklamalar bir daha gelmez. Burada ilk parti iki kez reddediliyor; ikinci parti hazır bekliyor.
func TestFailedWriteIsRetriedAndNeverCommittedPast(t *testing.T) {
	sink := &flakySink{failID: "e1", failTimes: 2, attempts: map[string]int{}, written: map[string]bool{}}
	kc := &fakeKafka{batches: [][]*kgo.Record{
		batchOf(t, 0, "e1", "e2", "e3"),
		batchOf(t, 3, "e4", "e5", "e6"),
	}, written: sink.has}
	reg := prometheus.NewRegistry()
	c := newTestConsumer(ConsumerConfig{}, kc, sink, reg)

	runConsumer(t, c, func() bool { return sink.has("e6") })

	if len(kc.unwritten) > 0 {
		t.Fatalf("commit, veritabanına yazılmamış kayıtların ötesine geçti: %v — bu tıklamalar bir daha gelmez", kc.unwritten)
	}
	for _, id := range []string{"e1", "e2", "e3", "e4", "e5", "e6"} {
		if !sink.has(id) {
			t.Fatalf("%s hiç yazılmadı: başarısız parti yeniden denenmedi", id)
		}
	}
	if got := sink.attempts["e1"]; got != 3 {
		t.Fatalf("ilk parti 2 hata + 1 başarı = 3 denemede yazılmalıydı, %d deneme", got)
	}
	if kc.commits < 2 {
		t.Fatalf("iki partinin ikisi de yazıldıktan sonra commit edilmeliydi, commit=%d", kc.commits)
	}
	if got := counter(t, reg, "consumer_records_total", "error"); got != 6 {
		t.Fatalf("iki başarısız deneme × 3 kayıt = 6 error bekleniyordu, %v", got)
	}
	if got := counter(t, reg, "consumer_records_total", "ok"); got != 6 {
		t.Fatalf("6 kayıt ok bekleniyordu, %v", got)
	}
}

// Kapanış yeniden denemeyi keser ve yazılmamış parti commit EDİLMEZ: yeniden başlayan tüketici
// onu commit edilmiş offset'ten tekrar okur.
func TestShutdownDuringRetryDoesNotCommit(t *testing.T) {
	sink := &flakySink{failID: "e1", failTimes: 1 << 30, attempts: map[string]int{}, written: map[string]bool{}}
	kc := &fakeKafka{batches: [][]*kgo.Record{batchOf(t, 0, "e1", "e2")}, written: sink.has}
	c := newTestConsumer(ConsumerConfig{}, kc, sink, prometheus.NewRegistry())

	runConsumer(t, c, func() bool {
		sink.mu.Lock()
		defer sink.mu.Unlock()
		return sink.attempts["e1"] >= 3
	})

	if kc.commits != 0 {
		t.Fatalf("parti hiç yazılamadı ama %d commit yapıldı", kc.commits)
	}
}

// TRAP_COMMIT_BEFORE_WRITE: offset yazmadan ÖNCE commit edilir; yazma başarısız olursa parti
// yeniden denenmez ve KAYBOLUR — tuzağın göstermesi gereken şey tam olarak bu.
func TestCommitBeforeWriteTrapLosesFailedBatch(t *testing.T) {
	sink := &flakySink{failID: "e1", failTimes: 1, attempts: map[string]int{}, written: map[string]bool{}}
	kc := &fakeKafka{batches: [][]*kgo.Record{
		batchOf(t, 0, "e1", "e2", "e3"),
		batchOf(t, 3, "e4", "e5", "e6"),
	}, written: sink.has}
	c := newTestConsumer(ConsumerConfig{CommitBeforeWrite: true}, kc, sink, prometheus.NewRegistry())

	runConsumer(t, c, func() bool { return sink.has("e6") })

	if len(kc.unwritten) == 0 {
		t.Fatal("tuzakta commit yazmadan önce gelmeliydi")
	}
	if got := sink.attempts["e1"]; got != 1 {
		t.Fatalf("tuzakta başarısız parti yeniden denenmemeli (offset zaten commit edildi), %d deneme", got)
	}
	if sink.has("e1") {
		t.Fatal("tuzakta başarısız parti kaybolmalıydı")
	}
	if !sink.has("e6") {
		t.Fatal("sonraki parti yine de yazılmalıydı")
	}
}
