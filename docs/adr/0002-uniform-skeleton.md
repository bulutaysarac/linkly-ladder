# ADR-0002 · Tekdüze iskelet: seviye Makefile'ı 3 satır, deploy aracı her yerde kustomize
**Durum:** kabul · **Tarih:** 2026-09-20
**Bağlam:** Kullanıcı isteği: 15 seviyenin hepsi aynı yapı, aynı komutlar, aynı Grafana; sadece sorunlar değişsin.
**Karar:** `ladder.mk` kökte tek kopya; seviye Makefile'ı sadece LEVEL/NAME + include. Dashboard, k6, chaos `platform/`'da
tek kopya, `$level` ile seçilir. Deploy her seviyede `kubectl apply -k deploy/`. Argo CD/Rollouts 12'de *konu*, `make up` değişmez.
**Reddedilen:** YAML → Kustomize → Helm araç merdiveni (tekdüzeliği bozar); seviye başına dashboard (kıyaslamayı zorlaştırır).
**Sonuç:** `tools/lint-skeleton.sh` sapmayı CI'da hata sayar.
