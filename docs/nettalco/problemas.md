# Solución de problemas

[← Volver al manual](README.md)

Cada caso de esta página pasó de verdad. Están ordenados por cuándo aparecen.

## Primero: ver el estado

En el servidor, estos tres comandos explican casi cualquier situación:

```bash
# ¿Está corriendo? ¿Con qué imagen? ¿Algún error?
docker service ps dokploy --no-trunc | head -5

# ¿Qué imagen tiene configurada?
docker service inspect dokploy --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'

# ¿Qué canal sigue el botón de actualizar?
docker service inspect dokploy \
  --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' | tr ',' '\n' | grep DOKPLOY_CUSTOM
```

> ⚠️ Nunca pegar en un chat o ticket la salida **completa** de
> `docker service inspect`: incluye la contraseña de la base de datos de Dokploy.
> Filtrar siempre con `grep`, como arriba.

Los registros del panel, filtrando lo que importa (sin filtro escupen consultas SQL
enteras imposibles de leer):

```bash
docker service logs dokploy --tail 200 2>&1 | grep -A5 "Error\|Failed query"
```

## Al desplegar

### No existe la imagen de este commit

```text
No existe la imagen de este commit en el registry.
```

La imagen se construye en GitHub Actions después de cada cambio y tarda unos 11
minutos. Revisar **Actions** → **Nettalco Image**: si está en curso, esperar y
repetir `./deploy.sh`.

Si la construcción **falló**, abrir esa ejecución y leer el error. Mientras se
resuelve, se puede construir en el propio servidor con `./deploy.sh local` (ver
[despliegue.md](despliegue.md#construir-en-el-propio-servidor)).

Si la construcción quedó **cancelada**: es normal cuando se suben varios cambios
seguidos, solo se construye el último. Hacer `./deploy.sh` de nuevo: baja el código
más reciente, cuya imagen sí se construyó.

### Todavía no hay ninguna imagen promovida

```text
Todavia no hay ninguna imagen promovida a :stable.
```

Se ejecutó `./deploy.sh stable` sin haber promovido nunca. Promover primero (ver
[despliegue.md](despliegue.md#1-promover)).

### El despliegue se queda en no suitable node

```text
1/1: no suitable node (host-mode port already in use on 1 node)
```

Ya no debería pasar: `deploy.sh` lo evita bajando el servicio a cero antes de cambiar
la imagen. Si aparece es porque se usó un comando a mano o una versión vieja del
script.

**Causa**: el instalador de Dokploy publica el puerto 3000 en *modo host*. Con una
sola réplica, Docker intenta levantar el contenedor nuevo antes de que el viejo libere
el puerto, y la actualización espera para siempre.

**Salida**: cortar con Ctrl+C y aplicar la imagen con el servicio en cero (ver
[Desplegar una imagen concreta a mano](#desplegar-una-imagen-concreta-a-mano)).

### Se queda quieto después de "Levantando 1 replica(s)"

Con el script actual no pasa: la limpieza final tiene un tope de un minuto. Con
versiones anteriores, el `docker image prune` podía quedarse esperando.

A esa altura **el despliegue ya terminó**: solo faltaba limpiar. Es seguro cortar con
Ctrl+C. Verificar con `docker service ps dokploy` que esté `Running`.

### `git push` responde 403

```text
remote: Permission to Nettalco/dokploy.git denied to <otra-cuenta>.
```

Está activa una cuenta de GitHub sin permiso de escritura:

```bash
gh auth switch --hostname github.com --user Nettalco
gh auth setup-git --hostname github.com
```

### El panel quedó caído

Si el servicio quedó con cero réplicas (por ejemplo, tras cortar un comando a mano a
la mitad):

```bash
docker service scale --detach dokploy=1
```

Esperar unos segundos y verificar con `docker service ps dokploy`.

## Al deshacer

### No hay imagen anterior registrada

```text
No hay imagen anterior registrada: este servidor todavia no tuvo un deploy
con la version actual del script, asi que no hay a donde volver.
```

El *rollback* vuelve a la imagen que anota cada despliegue. Si el servidor todavía no
tuvo ninguno con la versión actual de `deploy.sh`, no hay nada anotado. Desplegar a
mano la imagen deseada, como se explica a continuación.

### Desplegar una imagen concreta a mano

Para volver a una versión puntual, o cuando el script no sirve.

1. Elegir la imagen. Cada construcción queda guardada con el commit como nombre:
   `ghcr.io/nettalco/dokploy:<commit completo>`. Los commits se ven con
   `git log --oneline` o en GitHub.

2. Aplicarla **con el servicio en cero**, porque si no se cuelga por el puerto:

   ```bash
   docker service scale --detach dokploy=0
   # esperar a que no quede nada corriendo:
   docker service ps dokploy --filter desired-state=running --quiet
   # (cuando ese comando no muestre nada:)
   docker service update --detach --image ghcr.io/nettalco/dokploy:<commit> dokploy
   docker service scale --detach dokploy=1
   ```

3. Verificar con `docker service ps dokploy`.

Si es un servidor de producción, después volver a dejarlo en su canal con
`./deploy.sh stable`.

## En el panel

### El botón de actualizar no ofrece nada

Es lo esperado si el servidor ya corre la última imagen de su canal. Además, en
producción solo ofrece algo **después de promover**.

Si se sabe que hay algo nuevo y aun así no aparece:

- Comprobar el canal con el tercer comando de [Primero: ver el estado](#primero-ver-el-estado).
- Si la imagen que corre es `dokploy-custom:...`, se construyó en el servidor con
  `./deploy.sh local`: no tiene con qué comparar. Volver al registro con
  `./deploy.sh` o `./deploy.sh stable`.

### Dice que hay una versión nueva y no es así

El número de versión que muestra el panel sale del código, y en `canary` no avanza
hasta que el Dokploy oficial publica (el cambio de número solo lo hacen en `main`).
Puede mostrar una versión anterior a la publicada aunque el código sea **más nuevo**.

Si además el botón ofrece instalar la imagen **oficial** de Dokploy, al servicio le
falta `DOKPLOY_CUSTOM_IMAGE`. **No instalar**: reemplazaría la imagen de Nettalco por
la oficial y se perdería la marca. Corregir con `./deploy.sh` o `./deploy.sh stable`,
que la configura.

### Los colores de la marca no aparecen

Si después de traer novedades del oficial el panel se ve gris, con los colores por
defecto, casi seguro es la trampa de los colores: ver
[actualizar-upstream.md](actualizar-upstream.md#la-trampa-de-los-colores).

### Un miembro no ve los servicios de un proyecto

Pasó en las versiones `v0.29.14` y `v0.30.0`: los usuarios con rol *member* veían la
tarjeta del proyecto pero, al entrar, los sacaba sin explicación. El oficial lo
corrigió en `v0.30.1`.

Sirve de ejemplo de cómo diagnosticar un error que parece de permisos:

1. Revisar que el miembro tenga marcados el **proyecto**, el **entorno** y cada
   **servicio**, en **Settings** → **Users** → permisos. Marcar el proyecto no marca
   sus entornos solo.
2. Si está todo bien marcado, mirar los registros mientras el miembro reproduce el
   problema. En aquel caso aparecía `Failed query`: era una consulta rota, no un
   permiso.

## Con los avisos

### No llegan los avisos de novedades

El aviso es un *issue* en GitHub; el correo lo manda GitHub a quien **siga** el
repositorio. Comprobar:

1. Que los *issues* estén activos: **Settings** del repositorio → **General** →
   sección **Features** → **Issues**. GitHub los desactiva por defecto en los forks.
2. Que la persona siga el repositorio: botón **Watch** → **Custom** → **Issues**.
3. Que el workflow corra: **Actions** → **Nettalco Upstream Check**. Se puede lanzar a
   mano con **Run workflow**.

Si el workflow corre bien y dice *"Al dia, nada que avisar"*, simplemente no hay
novedades.
