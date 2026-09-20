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
