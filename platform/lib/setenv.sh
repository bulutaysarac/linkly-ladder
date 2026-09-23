#!/usr/bin/env bash
# Seviyenin uygulama iş yüklerinde ortam değişkeni aç/kapat/göster — README §7'nin alıştırmaları için.
#
#   make set   E="TRAP_NO_SINGLEFLIGHT=true CACHE_TTL=1h"   [W=redirect]
#   make unset E="TRAP_NO_SINGLEFLIGHT CACHE_TTL"            [W=redirect]
#   make env                                                  (şu an ne ayarlı?)
#   make reset                                                (hepsini manifestteki hâline döndür)
#
# EN: The exercises said "set CACHE_CAPACITY=100" or "turn the flag off" and never said how.
#     `kubectl set env` is the obvious answer and it is wrong from level 12 on: redirect becomes an
#     Argo Rollout and `set env` fails on CRDs (it killed all 98 toggles in the ladder once). This
#     reuses the scripts' own `setenv`, which patches Rollouts too. Without W it targets EVERY
#     application workload (image from the ladder registry) — most flags are read by more than one
#     service, and setting one of them silently leaves half the system on the old value.
# TR: Alıştırmalar "CACHE_CAPACITY=100 yap" ya da "bayrağı kapat" diyor, nasıl yapılacağını
#     söylemiyordu. Akla gelen `kubectl set env` 12'den itibaren YANLIŞ: redirect bir Argo Rollout
#     olur ve `set env` CRD'lerde çalışmaz (bir kez merdivendeki 98 anahtarın hepsini öldürmüştü).
#     Bu, scriptlerin kendi `setenv`'ini kullanır; Rollout'u da yamalar. W verilmezse HER uygulama
#     iş yükünü hedefler (imajı merdiven registry'sinden gelen): bayrakların çoğunu birden fazla
#     servis okur ve yalnızca birini değiştirmek sistemin yarısını eski değerde bırakır.
# [Topic · Konu: Deney araçları]
source "$LADDER_ROOT/platform/lib/repro.sh"
mode=${1:?set|unset|env|reset}; shift || true

# İKİ TÜR AYRI SORULUR. `get deploy,rollout` Argo Rollouts CRD'si yokken (make minimal/standard,
# 00-11) TAMAMEN başarısız olur; hatayı yutan ilk hâl bunu "iş yükü yok" diye okudu ve `make reset`
# hiçbir şey yapmadan başarı döndü — tuzaklar açık kaldı. Rollout yalnızca CRD varsa aranır; gerçek
# bir kubectl hatası ise "yok" değil HATA olarak yükselir.
# EN: query the kinds separately; a missing Rollouts CRD must not read as "no workloads".
_app_names() { jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("/linkly-ladder/"))
  | "\(.kind | ascii_downcase | sub("deployment";"deploy"))/\(.metadata.name)"'; }
app_workloads() {
  local out
  out=$(kubectl -n "$NS" get deploy -o json) || { echo "✘ $NS iş yükleri okunamadı (kubectl hatası yukarıda)" >&2; return 1; }
  _app_names <<<"$out"
  if kubectl api-resources --api-group=argoproj.io -o name 2>/dev/null | grep -qx 'rollouts.argoproj.io'; then
    out=$(kubectl -n "$NS" get rollout -o json) || { echo "✘ $NS Rollout'ları okunamadı" >&2; return 1; }
    _app_names <<<"$out"
  fi
}
targets() {
  if [[ -n "${W:-}" ]]; then wl "$W"; else app_workloads; fi
}
# Hedef listesi: boşsa ya da okunamadıysa SÖYLE ve dur — sıfır tur dönen bir döngü "başardım" der.
need_targets() {
  local ws
  ws=$(targets) || { CLEANUP_WAIT=0; exit 1; }
  [[ -n "$ws" ]] || { echo "✘ $NS içinde uygulama iş yükü yok — önce: make up" >&2; CLEANUP_WAIT=0; exit 1; }
  printf '%s\n' "$ws"
}

case "$mode" in
  env)
    CLEANUP_WAIT=0
    ws=$(need_targets) || { CLEANUP_WAIT=0; exit 1; }
    for w in $ws; do
      echo "── $w"
      kubectl -n "$NS" get "$w" -o json | jq -r '.spec.template.spec.containers[0].env // [] | .[]
        | "  \(.name)=\(.value // (if .valueFrom then "<" + (.valueFrom | keys[0]) + ">" else "" end))"' | sort
    done ;;
  set|unset)
    [[ -n "${E:-}" ]] || { echo "E gerekli — örnek: make $mode E=\"$([[ $mode == set ]] && echo 'TRAP_X=true' || echo 'TRAP_X')\""; CLEANUP_WAIT=0; exit 2; }
    args=()
    for kv in $E; do
      if [[ $mode == set ]]; then
        [[ "$kv" == *=* ]] || { echo "✘ '$kv' KEY=değer biçiminde değil"; CLEANUP_WAIT=0; exit 2; }
        args+=("$kv")
      else
        args+=("${kv%%=*}-")
      fi
    done
    ws=$(need_targets) || { CLEANUP_WAIT=0; exit 1; }
    for w in $ws; do setenv "$w" "${args[@]}"; echo "✔ $w: ${args[*]}"; done
    echo "  pod'lar yeni değerle yeniden başlıyor; hazır olunca dönülecek..." ;;
  reset)
    # MANİFESTTEKİ HÂLE DÖN. `unset` bir değişkeni SİLER: manifest'te zaten tanımlı bir ayarı
    # (CACHE_CAPACITY=50000 gibi) değiştirip sonra unset etmek, onu manifest değerine değil KODUN
    # varsayılanına düşürür — "geri aldım" sanırsın, başka bir sistemle devam edersin. `make deploy`
    # da yetmez: kubectl apply, sonradan eklenen değişkenlere (TRAP_*) dokunmaz. Bu yüzden env
    # listesi, deploy/'un ürettiği listeyle BİREBİR değiştirilir.
    # EN: restore env to exactly what deploy/ renders — `unset` drops a manifest-defined value to the
    #     code default, and `kubectl apply` leaves variables added later (TRAP_*) in place.
    rendered=$(kubectl kustomize deploy/ 2>/dev/null | kubectl create --dry-run=client -o json -f - 2>/dev/null) \
      || { echo "✘ deploy/ render edilemedi (seviye klasöründe misin?)"; CLEANUP_WAIT=0; exit 1; }
    ws=$(need_targets) || { CLEANUP_WAIT=0; exit 1; }
    bad=0
    for w in $ws; do
      kind=${w%%/*}; name=${w#*/}
      # EŞLEŞME YOKSA DOKUNMA. `// []` ile boş listeye düşmek, iş yükünün TÜM ortamını (DATABASE_URL
      # dahil) silip "✔" basardı. Çıktı bir nesne akışı ya da tek bir List olabilir; ikisi de açılır.
      obj=$(jq -s -c --arg k "$kind" --arg n "$name" '[.[] | if .kind == "List" then .items[] else . end
            | select((.kind|ascii_downcase|sub("deployment";"deploy"))==$k and .metadata.name==$n)][0]' <<<"$rendered")
      if [[ -z "$obj" || "$obj" == null ]]; then
        echo "✘ $w deploy/'da bulunamadı — DOKUNULMADI (elle bak: make env W=$name)" >&2; bad=1; continue
      fi
      want=$(jq -c '.spec.template.spec.containers[0].env // []' <<<"$obj")
      kubectl -n "$NS" patch "$w" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$want}]" >/dev/null
      echo "✔ $w: ortam manifestteki hâline döndü"
    done
    (( bad == 0 )) || { CLEANUP_WAIT=0; exit 1; }
    echo "  pod'lar yeniden başlıyor; hazır olunca dönülecek..." ;;
  *) echo "kullanım: setenv.sh set|unset|env|reset"; CLEANUP_WAIT=0; exit 2 ;;
esac
