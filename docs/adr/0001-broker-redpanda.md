# ADR-0001 · Broker: Redpanda (Kafka API)
**Durum:** kabul · **Tarih:** 2026-09-20
**Bağlam:** 06'da click olayları için broker gerekiyor; 16 GB Mac'te kind içinde koşar.
**Karar:** Redpanda (tek binary, Kafka API uyumlu, `rpk`, public metrics). Go istemcisi franz-go.
**Alternatifler:** Strimzi Kafka (gerçek dünyaya en yakın, ağır), NATS JetStream (daha hafif, Kafka semantiği değil).
**Sonuç:** Kafka API öğrenilir; Strimzi'ye geçiş sadece deploy/ değişikliği.
