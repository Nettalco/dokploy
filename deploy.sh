#!/usr/bin/env bash
# Deploy de Dokploy Nettalco.
# Uso: ./deploy.sh          -> despliega la imagen que CI publico para el commit actual
#      ./deploy.sh local    -> construye en este servidor (respaldo si CI no esta)
#      ./deploy.sh rollback -> vuelve a la imagen anterior
set -euo pipefail

SERVICE=dokploy
REGISTRY=${REGISTRY:-ghcr.io/nettalco/dokploy}
# Tag movil que sigue el boton de la UI para detectar builds nuevas.
REGISTRY_IMAGE="${REGISTRY}:canary"
LOCAL_IMAGE=dokploy-custom

MODE=${1:-registry}

if [ "$MODE" = "rollback" ]; then
	docker service rollback "$SERVICE"
	exit 0
fi

# El reset reescribe este mismo archivo mientras bash lo esta leyendo, asi que la corrida
# que actualiza el script no puede ser la que lo ejecuta: se relanza una sola vez, ya con
# la version nueva. Sin esto, un cambio en el script recien surte efecto al segundo deploy.
if [ -z "${DEPLOY_REEXEC:-}" ]; then
	git fetch origin canary
	git reset --hard origin/canary
	DEPLOY_REEXEC=1 exec "$0" "$@"
fi

if [ "$MODE" = "local" ]; then
	# ponytail: sed y no node — el host solo necesita git y docker, el build va adentro.
	VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' apps/dokploy/package.json | head -1)
	[ -n "$VERSION" ] || { echo "No pude leer version de apps/dokploy/package.json" >&2; exit 1; }
	DEPLOY_IMAGE="${LOCAL_IMAGE}:${VERSION}-$(git rev-parse --short HEAD)"

	echo ">> Construyendo ${DEPLOY_IMAGE}"
	docker build -t "$DEPLOY_IMAGE" -t "${LOCAL_IMAGE}:latest" .
	echo ">> Ojo: una imagen construida aca no tiene digest, asi que el boton de"
	echo "   actualizar de la UI no va a ofrecer nada hasta volver al registry."
else
	# Se despliega por SHA y no por el tag movil: deja explicito que commit corre y falla
	# claro si CI todavia no publico este, en vez de desplegar en silencio uno anterior.
	DEPLOY_IMAGE="${REGISTRY}:$(git rev-parse HEAD)"

	echo ">> Buscando ${DEPLOY_IMAGE}"
	if ! docker manifest inspect "$DEPLOY_IMAGE" >/dev/null 2>&1; then
		cat >&2 <<-MSG
		No existe la imagen de este commit en el registry.

		Suele ser que CI sigue construyendo (tarda unos 11 minutos):
		  https://github.com/Nettalco/dokploy/actions/workflows/nettalco-image.yml

		Espera a que termine y repeti, o construi aca con:  ./deploy.sh local
		MSG
		exit 1
	fi
fi

echo ">> Actualizando servicio ${SERVICE}"
# DOKPLOY_CUSTOM_IMAGE redirige el chequeo de version y el boton de actualizar de la UI
# al registry propio. Sin esto, ese boton correria
# 'docker service update --image dokploy/dokploy:<v>' y reemplazaria esta imagen por la
# oficial, perdiendo el branding.
#
# El paquete en GHCR es publico (hereda la visibilidad del fork), asi que no hacen falta
# credenciales. GHCR_USER y GHCR_TOKEN solo se necesitan si se vuelve privado; el codigo
# tambien acepta DOKPLOY_REGISTRY_TOKEN_FILE para leerlo de un secreto de swarm.
#
# RELEASE_TAG solo se corrige para que la UI no siga mostrando el valor de la instalacion
# original; con DOKPLOY_CUSTOM_IMAGE definida ya no interviene en el chequeo.
docker service update \
	--env-add "DOKPLOY_CUSTOM_IMAGE=${REGISTRY_IMAGE}" \
	--env-add "DOKPLOY_REGISTRY_USER=${GHCR_USER:-}" \
	--env-add "DOKPLOY_REGISTRY_TOKEN=${GHCR_TOKEN:-}" \
	--env-add "RELEASE_TAG=canary" \
	--image "$DEPLOY_IMAGE" "$SERVICE"

# ponytail: solo capas huerfanas. NO usar 'prune -a' — borra la imagen anterior
# y te deja sin rollback. Para limpiar tags viejos a fondo, correr a mano.
docker container prune -f
docker image prune -f

echo ">> Desplegado ${DEPLOY_IMAGE}"

# Avisa de cambios en upstream, que es lo que el aviso de version de la UI ya no cubre.
# Informativo: si falla la red o falta el remote, no debe tumbar un deploy que salio bien.
if git remote get-url upstream >/dev/null 2>&1 ||
	git remote add upstream https://github.com/Dokploy/dokploy.git 2>/dev/null; then
	if git fetch upstream canary --quiet 2>/dev/null; then
		BEHIND=$(git rev-list --count HEAD..upstream/canary)
		[ "$BEHIND" -eq 0 ] &&
			echo ">> Al dia con upstream/canary" ||
			echo ">> Hay ${BEHIND} commits nuevos en upstream/canary"
	fi
fi
