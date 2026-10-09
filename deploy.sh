#!/usr/bin/env bash
# Deploy de Dokploy Nettalco: actualiza codigo, construye y actualiza el servicio Swarm.
# Uso: ./deploy.sh          -> despliega origin/canary
#      ./deploy.sh rollback -> vuelve a la imagen anterior
set -euo pipefail

SERVICE=dokploy
IMAGE=dokploy-custom
# Imagen que publica el workflow nettalco-image.yml y que sigue el boton de la UI.
REGISTRY_IMAGE=${REGISTRY_IMAGE:-ghcr.io/nettalco/dokploy:canary}

if [ "${1:-}" = "rollback" ]; then
	docker service rollback "$SERVICE"
	exit 0
fi

git fetch origin canary
git reset --hard origin/canary

# Tag = version + commit corto, para que cada deploy sea identificable y reversible.
# ponytail: sed y no node — el host solo necesita git y docker, el build va dentro del contenedor.
VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' apps/dokploy/package.json | head -1)
[ -n "$VERSION" ] || { echo "No pude leer version de apps/dokploy/package.json" >&2; exit 1; }
TAG="${VERSION}-$(git rev-parse --short HEAD)"

echo ">> Construyendo ${IMAGE}:${TAG}"
docker build -t "${IMAGE}:${TAG}" -t "${IMAGE}:latest" .

echo ">> Actualizando servicio ${SERVICE}"
# DOKPLOY_CUSTOM_IMAGE redirige el chequeo de version y el boton de actualizar de la UI
# al registry propio. Sin esto, ese boton correria
# 'docker service update --image dokploy/dokploy:<v>' y reemplazaria esta imagen por la
# oficial, perdiendo el branding.
#
# El token (un PAT de solo lectura de paquetes) queda en el spec del servicio, visible
# con 'docker service inspect'. Es aceptable porque quien llega al socket de Docker ya
# es root en este host. Para sacarlo de ahi: crear un secreto de swarm y apuntar
# DOKPLOY_REGISTRY_TOKEN_FILE a /run/secrets/<nombre>, que el codigo ya soporta.
docker service update \
	--env-add "DOKPLOY_CUSTOM_IMAGE=${REGISTRY_IMAGE}" \
	--env-add "DOKPLOY_REGISTRY_USER=${GHCR_USER:-}" \
	--env-add "DOKPLOY_REGISTRY_TOKEN=${GHCR_TOKEN:-}" \
	--image "${IMAGE}:${TAG}" "$SERVICE"

# ponytail: solo capas huerfanas. NO usar 'prune -a' — borra la imagen anterior
# y te deja sin rollback. Para limpiar tags viejos a fondo, correr a mano.
docker container prune -f
docker image prune -f

echo ">> Desplegado ${IMAGE}:${TAG}"

# Reemplaza el aviso de version de la UI, que quedo desactivado arriba. Informativo:
# si falla la red o falta el remote, no debe tumbar un despliegue que ya salio bien.
if git remote get-url upstream >/dev/null 2>&1 || \
	git remote add upstream https://github.com/Dokploy/dokploy.git 2>/dev/null; then
	if git fetch upstream canary --quiet 2>/dev/null; then
		BEHIND=$(git rev-list --count HEAD..upstream/canary)
		[ "$BEHIND" -eq 0 ] &&
			echo ">> Al dia con upstream/canary" ||
			echo ">> Hay ${BEHIND} commits nuevos en upstream/canary"
	fi
fi
