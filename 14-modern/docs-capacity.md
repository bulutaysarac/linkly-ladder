# Kapasite modeli — ölçülmüş sayılarla

> System Design Primer'ın zarf arkası hesabı, bu merdivende GERÇEKTEN ölçülmüş değerlerle.
> Buradaki her sayı bir `make repro` ya da `make load` çıktısından geliyor; tahmin yok.

## Ölçüm tabanı (bu laptop: 6 CPU / 10 GB Docker, kind 4 node)

| Ölçüm | Değer | Nereden |
|---|---|---|
| redirect p50 (L2 önbellek isabeti) | ~1–3 ms | P04-02 |
| redirect p50 (L1 isabeti) | < 0.5 ms | P14-01 |
| redirect p99 (DB'den, önbelleksiz) | ~97 ms | P02-01 |
| İstek başına DB sorgusu (02) | 2.0 | P02-01 |
| İstek başına DB sorgusu (04+) | ~0.05 (hit oranına bağlı) | P04-01 |
| Tek pod redirect kapasitesi | ~1700 rps (1 VU, önbellekli) | P00-04 ölçümü |
| Postgres bağlantı limiti | 100 (Pooler ile 500 uygulama bağlantısı) | P02-02, 09 |
| Redis tek çekirdek tavanı | hot-key'de belirgin | P04-03 |

## "1 milyon link/gün, 100 milyon redirect/gün" için ne gerekir?

```
100 M redirect/gün ÷ 86 400 s ≈ 1 160 rps ortalama
Tepe/ortalama oranı (ölçülen, P03-07/P04-04):   ~3×
→ tepe ≈ 3 500 rps

redirect-svc:
  1 700 rps/pod (önbellekli, tek çekirdek sınırında)
  → 3 500 / 1 700 ≈ 2 pod + yedeklilik + burst tamponu (P07-01: HPA geç kalır)
  → minReplicas 4, maxReplicas 12   ✓ mevcut ayar

Önbellek isabeti %95 varsayımıyla DB okuma:
  3 500 × 0.05 ≈ 175 okuma/s  → tek primary rahat taşır
  Ama SOĞUK anda (P03-02): 3 500 okuma/s → primary TAŞIYAMAZ
  → bu yüzden L2 kalıcı olmalı ve rollout'lar kademeli (12)

yazma yolu:
  1 M link/gün ÷ 86 400 ≈ 12 yazma/s ortalama, tepe ~40/s
  → api-svc 2 pod fazlasıyla yeter   ✓ mevcut ayar

tıklama olayları:
  3 500 olay/s → Redpanda tek broker bunu taşır (laptop'ta ~10k/s)
  consumer: parti 500, 1 sn flush → 7 parti/s → 1–3 replika   ✓ KEDA maxReplicas 3

Redis:
  3 500 GET/s + 7 000 limit kontrolü/s ≈ 10 500 komut/s
  Tek çekirdek ~80–100k komut/s taşır → RAHAT
  ANCAK hot-key (P04-03) tek anahtarda tavanı düşürür → L1 bu yüzden geri geldi (14)
```

## Darboğaz sıralaması (ölçülen, sırayla çarpılır)

1. **Redis hot key** (P04-03) → L1 ile aşıldı (14)
2. **DB bağlantıları** (P02-02) → Pooler ile aşıldı (09)
3. **DB okuma** (P02-01) → önbellek ile aşıldı (03/04)
4. **Tıklama yazma** (P02-08) → asenkron + toplama ile aşıldı (05/06)
5. **Tek broker / tek partition** (P06-03, P06-05) → kısmen (3 partition, hâlâ tek broker)
6. **Tek Postgres primary (yazma)** → aşılmadı: yatay yazma ölçeklemesi sharding ister

*Her darboğaz aşıldığında bir sonraki ortaya çıkar. "Ölçeklenebilir sistem" diye bir şey yoktur;
belirli bir yüke kadar ölçeklenen, sonraki darboğazı bilinen bir sistem vardır.*

## Bu modelin sınırları

- Tek laptop, tek bölge, tek cluster. Ağ gecikmesi gerçekçi değil (hepsi aynı makinede).
- Veri kümesi küçük: 1 M satırda index davranışı 100 M'de farklıdır.
- Trafik profili tekdüze; gerçek kısaltıcılarda dağılım **ağır kuyrukludur** (birkaç link tüm trafiği alır).
- Maliyet hesabı yok: bulutta 12 pod + 3 DB + Redis + Kafka'nın aylık faturası bu modelin parçası olmalı.
