#!/usr/bin/env bash
# Deploy de Dokploy Nettalco. Manual completo en docs/nettalco/.
# Uso: ./deploy.sh          -> desarrollo: la imagen del commit actual
#      ./deploy.sh stable   -> produccion: la ultima imagen promovida
#      ./deploy.sh local    -> construye en este servidor (respaldo si CI no esta)
#      ./deploy.sh rollback -> vuelve a la imagen que corria antes del ultimo deploy
#
# Produccion sigue :stable y no :canary, para que solo corra lo que ya se probo en
# desarrollo. La etiqueta la mueve el workflow nettalco-promote.yml, a mano.
set -euo pipefail

# Ruta absoluta antes de movernos: el relanzamiento de mas abajo vuelve a invocar este
# archivo, y con una ruta relativa dejaria de resolver una vez cambiado el directorio.
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# Todo lo que sigue (git, package.json, el contexto del build) es relativo al repo, asi
# que el script se ubica solo y funciona desde cualquier directorio.
cd "$(dirname "$SCRIPT")"

SERVICE=dokploy
REGISTRY=${REGISTRY:-ghcr.io/nettalco/dokploy}
LOCAL_IMAGE=dokploy-custom
# Imagen que reemplazo el ultimo deploy. Es lo que usa el rollback: 'docker service
# rollback' no sirve aca porque el deploy cambia el spec en varios pasos y el "spec
# anterior" seria el intermedio con cero replicas.
PREVIOUS_LABEL=nettalco.previous-image

MODE=${1:-registry}

# El boton de la UI sigue el mismo canal que este servidor: en produccion solo ofrece
# imagenes promovidas, en desarrollo cualquier build nueva de canary.
if [ "$MODE" = "stable" ]; then
	CHANNEL=stable
else
	CHANNEL=canary
fi
REGISTRY_IMAGE="${REGISTRY}:${CHANNEL}"

# El reset reescribe este mismo archivo mientras bash lo esta leyendo, asi que la corrida
# que actualiza el script no puede ser la que lo ejecuta: se relanza una sola vez, ya con
# la version nueva. Sin esto, un cambio en el script recien surte efecto al segundo deploy.
# El rollback no toca el codigo: vuelve a una imagen, no a un commit.
if [ "$MODE" != "rollback" ] && [ -z "${DEPLOY_REEXEC:-}" ]; then
	git fetch origin canary
	git reset --hard origin/canary
	DEPLOY_REEXEC=1 exec "$SCRIPT" "$@"
fi

if [ "$MODE" = "rollback" ]; then
	DEPLOY_IMAGE=$(docker service inspect "$SERVICE" \
		--format "{{index .Spec.Labels \"${PREVIOUS_LABEL}\"}}")
	if [ -z "$DEPLOY_IMAGE" ] || [ "$DEPLOY_IMAGE" = "<no value>" ]; then
		echo "No hay imagen anterior registrada: este servidor todavia no tuvo un deploy" >&2
		echo "con la version actual del script, asi que no hay a donde volver." >&2
		exit 1
	fi
	echo ">> Volviendo a ${DEPLOY_IMAGE}"
elif [ "$MODE" = "local" ]; then
	# ponytail: sed y no node — el host solo necesita git y docker, el build va adentro.
	VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' apps/dokploy/package.json | head -1)
	[ -n "$VERSION" ] || { echo "No pude leer version de apps/dokploy/package.json" >&2; exit 1; }
	DEPLOY_IMAGE="${LOCAL_IMAGE}:${VERSION}-$(git rev-parse --short HEAD)"

	echo ">> Construyendo ${DEPLOY_IMAGE}"
	docker build -t "$DEPLOY_IMAGE" -t "${LOCAL_IMAGE}:latest" .
	echo ">> Ojo: una imagen construida aca no tiene digest, asi que el boton de"
	echo "   actualizar de la UI no va a ofrecer nada hasta volver al registry."
elif [ "$MODE" = "stable" ]; then
	# Produccion no mira el git local: corre lo que se promovio, sea cual sea el commit
	# que tenga este clon (aca el repo solo aporta este script).
	DEPLOY_IMAGE="${REGISTRY}:stable"

	echo ">> Buscando ${DEPLOY_IMAGE}"
	if ! docker manifest inspect "$DEPLOY_IMAGE" >/dev/null 2>&1; then
		cat >&2 <<-MSG
		Todavia no hay ninguna imagen promovida a :stable.

		Promove una desde Actions > Nettalco Promote, indicando el SHA que ya
		probaste en desarrollo:
		  https://github.com/Nettalco/dokploy/actions/workflows/nettalco-promote.yml
		MSG
		exit 1
	fi
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
#
# El rollback deja el entorno como esta: si recalculara el canal, un servidor de
# produccion volveria pasado a canary.
ENV_ARGS=()
if [ "$MODE" != "rollback" ]; then
	ENV_ARGS=(
		--env-add "DOKPLOY_CUSTOM_IMAGE=${REGISTRY_IMAGE}"
		--env-add "DOKPLOY_REGISTRY_USER=${GHCR_USER:-}"
		--env-add "DOKPLOY_REGISTRY_TOKEN=${GHCR_TOKEN:-}"
		--env-add "RELEASE_TAG=${CHANNEL}"
	)
fi

CURRENT_IMAGE=$(docker service inspect "$SERVICE" \
	--format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')

# El instalador publica el puerto en modo host. Con una sola replica, swarm no alcanza a
# liberar ese puerto antes de planificar la tarea nueva, ni siquiera con stop-first, y la
# actualizacion se cuelga en "no suitable node (host-mode port already in use)". Bajar a
# cero primero es lo unico que lo garantiza. Implica unos segundos sin panel; con un
# unico puerto en modo host no hay forma de evitarlo.
REPLICAS=$(docker service inspect "$SERVICE" --format '{{.Spec.Mode.Replicated.Replicas}}')
: "${REPLICAS:=1}"

# Todo con --detach y espera propia: sin eso, 'docker service scale' bloquea en su
# verificacion de convergencia y se queda colgado indefinidamente contra este servicio.
# Falla si docker no responde, en vez de informar cero: un error aqui no puede
# confundirse con "ya no queda ninguna tarea", o seguiriamos adelante con el puerto
# todavia ocupado.
tareas_corriendo() {
	local ids
	ids=$(docker service ps "$SERVICE" --filter desired-state=running --quiet) || return 1
	# grep -c devuelve 1 con entrada vacia, que aqui es un conteo valido de cero.
	printf '%s\n' "$ids" | grep -c '.' || true
}

esperar() { # esperar <cantidad esperada> <segundos>
	local n
	for _ in $(seq 1 "$2"); do
		if n=$(tareas_corriendo) && [ "$n" -eq "$1" ]; then
			return 0
		fi
		sleep 1
	done
	return 1
}

echo ">> Bajando a cero para liberar el puerto"
docker service scale --detach "${SERVICE}=0"
# Si algo falla de aca en mas, el panel tiene que volver igual, aunque sea con la imagen
# vieja: nunca dejar el servicio en cero.
trap 'docker service scale --detach "${SERVICE}=${REPLICAS}" >/dev/null 2>&1 || true' EXIT
esperar 0 60 || { echo "La tarea vieja no termino de bajar." >&2; exit 1; }

# ${ENV_ARGS[@]+...} y no "${ENV_ARGS[@]}": con set -u, un arreglo vacio da error en bash
# anteriores a 4.4, y en el rollback queda vacio a proposito.
docker service update --detach \
	--update-order stop-first \
	--label-add "${PREVIOUS_LABEL}=${CURRENT_IMAGE}" \
	${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
	--image "$DEPLOY_IMAGE" "$SERVICE"

echo ">> Levantando ${REPLICAS} replica(s)"
docker service scale --detach "${SERVICE}=${REPLICAS}"
trap - EXIT
esperar "$REPLICAS" 120 ||
	echo ">> Ojo: todavia no levanto. Revisa con: docker service ps ${SERVICE}" >&2

# ponytail: solo capas huerfanas. NO usar 'prune -a' — borra la imagen anterior
# y te deja sin rollback. Para limpiar tags viejos a fondo, correr a mano.
#
# Acotado en tiempo y sin cortar el script: el prune compite por el bloqueo del almacen
# de imagenes mientras arranca el contenedor nuevo y puede quedarse esperando. Un
# despliegue ya exitoso no puede quedar colgado por una limpieza.
limpiar() { # limpiar <contenedores|imagenes> <subcomando>
	timeout 60 docker "$2" prune -f >/dev/null 2>&1 ||
		echo ">> Limpieza de ${1} omitida (se hara en el proximo deploy)" >&2
}
limpiar contenedores container
limpiar imagenes image

echo ">> Desplegado ${DEPLOY_IMAGE}"

# Avisa de cambios en upstream, que es lo que el aviso de version de la UI ya no cubre.
# Solo en desarrollo: en produccion importa lo promovido, no lo que haya en upstream.
# Informativo: si falla la red o falta el remote, no debe tumbar un deploy que salio bien.
if [ "$MODE" != "rollback" ] && [ "$CHANNEL" = "canary" ] &&
	{ git remote get-url upstream >/dev/null 2>&1 ||
		git remote add upstream https://github.com/Dokploy/dokploy.git 2>/dev/null; }; then
	if git fetch upstream canary --quiet 2>/dev/null; then
		BEHIND=$(git rev-list --count HEAD..upstream/canary)
		[ "$BEHIND" -eq 0 ] &&
			echo ">> Al dia con upstream/canary" ||
			echo ">> Hay ${BEHIND} commits nuevos en upstream/canary"
	fi
fi
