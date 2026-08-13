#!/usr/bin/env bash
# Deploy de Dokploy Nettalco: actualiza codigo, construye y actualiza el servicio Swarm.
# Uso: ./deploy.sh          -> despliega origin/canary
#      ./deploy.sh rollback -> vuelve a la imagen anterior
set -euo pipefail

SERVICE=dokploy
IMAGE=dokploy-custom

if [ "${1:-}" = "rollback" ]; then
	docker service rollback "$SERVICE"
	exit 0
fi

git fetch origin canary
git reset --hard origin/canary

# Tag = version + commit corto, para que cada deploy sea identificable y reversible.
VERSION=$(node -p "require('./apps/dokploy/package.json').version")
TAG="${VERSION}-$(git rev-parse --short HEAD)"

echo ">> Construyendo ${IMAGE}:${TAG}"
docker build -t "${IMAGE}:${TAG}" -t "${IMAGE}:latest" .

echo ">> Actualizando servicio ${SERVICE}"
docker service update --image "${IMAGE}:${TAG}" "$SERVICE"

# ponytail: solo capas huerfanas. NO usar 'prune -a' — borra la imagen anterior
# y te deja sin rollback. Para limpiar tags viejos a fondo, correr a mano.
docker container prune -f
docker image prune -f

echo ">> Desplegado ${IMAGE}:${TAG}"
