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

app_workloads() {
  kubectl -n "$NS" get deploy,rollout -o json 2>/dev/null | jq -r '
    .items[] | select(.spec.template.spec.containers[0].image | test("/linkly-ladder/"))
    | "\(.kind | ascii_downcase | sub("deployment";"deploy"))/\(.metadata.name)"'
}
targets() {
  if [[ -n "${W:-}" ]]; then wl "$W"; else app_workloads; fi
}

case "$mode" in
  env)
    CLEANUP_WAIT=0
    for w in $(targets); do
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
    ws=$(targets)
    [[ -n "$ws" ]] || { echo "✘ $NS içinde uygulama iş yükü yok — önce: make up"; CLEANUP_WAIT=0; exit 1; }
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
    for w in $(targets); do
      kind=${w%%/*}; name=${w#*/}
      want=$(jq -s -c --arg k "$kind" --arg n "$name" '[.[] | select((.kind|ascii_downcase|sub("deployment";"deploy"))==$k and .metadata.name==$n)][0].spec.template.spec.containers[0].env // []' <<<"$rendered")
      kubectl -n "$NS" patch "$w" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$want}]" >/dev/null
      echo "✔ $w: ortam manifestteki hâline döndü"
    done
    echo "  pod'lar yeniden başlıyor; hazır olunca dönülecek..." ;;
  *) echo "kullanım: setenv.sh set|unset|env|reset"; CLEANUP_WAIT=0; exit 2 ;;
esac
