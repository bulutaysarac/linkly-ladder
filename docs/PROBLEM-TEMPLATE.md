### PNN-XX · <başlık>
**Belirti:** Kullanıcının/operatörün gördüğü şey. Bir cümle.
**Neden:** Kök neden. Sistem tasarımı konusuyla bağla: [Topic · Konu: …]
**Reproduce (adım adım):**
  1. `make up` (başlangıç durumu)
  2. İkinci terminalde: `make load S=…`
  3. Tetikleyici: `kubectl …` / `make chaos C=…` / `TRAP_… =1`
  4. Gözlem: ne göreceksin, kaç saniye içinde
  5. `make repro P=PNN-XX` aynı adımları otomatik koşar; son satır REPRODUCED / NOT-REPRODUCED
**Grafana:** `<dashboard>` → "<panel>" (level=lvlNN); PromQL: `…`
**Nerede çözülüyor:** Seviye NN+k (ne ile). Geçici çare varsa ve neden yetmediği.

---

## Script kontratı (`problems/PNN-XX.sh`)

İlk satırlar sabittir; gerisi ölçümdür. Son satır **REPRODUCED (exit 0)** ya da
**NOT-REPRODUCED (exit 1)** basmak zorunda — `verify-prev` kararını çıkış koduna değil bu
**işarete** bakarak verir (script çökerse ERROR görünür, yanlışlıkla yeşil yanmaz).

```bash
#!/usr/bin/env bash
source "${LADDER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/platform/lib/repro.sh"
```

### `platform/lib/repro.sh` — sık kullanılanlar

| Yardımcı | Ne yapar / neden var |
|---|---|
| `ensure_healthy` | Ölçümün temiz başlangıç noktası: taban replika, gerçekten HTTP veren pod'lar |
| `on_cleanup "<komut>"` | Deney sonrası geri alma (ters sırada çalışır). **Her yıkıcı adımın karşılığı olmalı** |
| `need_confirm "<ne>"` | Yıkıcı adım: `CONFIRM=1` yoksa exit 2 (SKIPPED) |
| `dep_pod <selector>` | Bağımlı bileşenin HAZIR pod'u; gelene kadar bekler. Önceki deney onu öldürmüş olabilir |
| `chaos_apply <şablon>` | Chaos uygula + temizliğini kaydet. **Enjekte edilemezse exit 2** — sessizce arızasız ölçme |
| `clicks <code> <N> [par]` | Paralel tıklama üreteci (sıralı curl döngüsü birikim üretmeye yetmez) |
| `k6run <senaryo> …` | k6 + Prometheus remote-write; özet `$K6_SUMMARY` |
| `sample_series <port> <sn> <dosya> <desen> [atla]` | Pod'un `/metrics` ucunu **saniyede bir** örnekle → saniyelik fark dizisi |
| `peak_avg <dosya>` | `tepe ortalama oran` üçlüsü |
| `promq '<PromQL>'` | Anlık sorgu, ilk değer (yoksa `0`) · `prom_absent` metrik hiç yok mu? |
| `port_forward <pod> <port>` / `port_forward_stop` | Ingress'i atla: "korumayı kim veriyor?" sorusu için |
| `wait_endpoints <n>` · `scale <n>` · `replicas_of` | Ölçek değişimi; endpoint listesi rollout'tan geriden gelir |

### Ölçüm kuralları (kök README'deki tabloyla aynı, script yazarken tekrar oku)

1. **Pencere**, ölçtüğün olaydan kısa olmasın; **çözünürlük** olaydan ince olsun.
2. İki fazı **ayrı** ölç: `increase(...[3m])` bir önceki fazı da toplar. Faz başı/sonu sayaç farkı
   ya da faz süresine eşit pencere kullan.
3. **Komşu olayı sustur:** aynı grafiği besleyen ikinci bir mekanizma varsa (TTL churn gibi),
   deney süresince onu kapat — yoksa hangisini ölçtüğünü bilemezsin.
4. Deneyin **hazırlığı** da enjekte ettiğin arızaya tabidir (k6 `setup()` dahil).
5. Ölçüyü iddiaya göre seç: "her pod kendi önbelleğini ısıtıyor" iddiasının ölçüsü **ıska sayısı**dır,
   hit oranı değil (payı ve paydası birlikte oynar).
6. Ölçemediğin bir sınırı, **sınırın kendisini** ölçerek göster (`redis-benchmark` ile tavan gibi).
7. Deneyi **ölçeğe uydur**: ya veriyi büyüt ya sınırı küçült — ve neyi değiştirdiğini yaz.
8. Metrik adının var olduğunu **varsayma**: yoksa `promq` sessizce `0` döner ve script "sorun yok" der.
