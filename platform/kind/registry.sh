#!/usr/bin/env bash
# kind local registry (resmi tarif): localhost:5001 host'tan, kind-registry:5000 node'lardan.
set -euo pipefail
REG_NAME=kind-registry; REG_PORT=5001
if [ "$(docker inspect -f '{{.State.Running}}' $REG_NAME 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge --name $REG_NAME registry:2 >/dev/null
  echo "registry başlatıldı: localhost:${REG_PORT}"
fi
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name ladder); do
  docker exec "$node" mkdir -p "$REGISTRY_DIR"
  cat <<TOML | docker exec -i "$node" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
TOML
done
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' $REG_NAME)" = 'null' ]; then
  docker network connect kind $REG_NAME
fi
kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
YAML
echo "registry node'lara bağlandı"
