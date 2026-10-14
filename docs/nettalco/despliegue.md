# Despliegue

[← Volver al manual](README.md)

Todo se hace con `deploy.sh`, conectado por SSH al servidor y como `root` (o con
`sudo -i`). Los accesos están en el inventario interno.

## Desplegar en desarrollo

Para probar el último cambio subido a `canary`:

```bash
cd ~/dokploy && ./deploy.sh
```

El script baja el código más reciente y despliega la imagen construida para **ese
commit exacto**. Si responde que la imagen no existe, la construcción todavía no
terminó (tarda unos 11 minutos): esperar y repetir.

Salida esperada:

```text
>> Buscando ghcr.io/nettalco/dokploy:<commit>
>> Actualizando servicio dokploy
>> Bajando a cero para liberar el puerto
>> Levantando 1 replica(s)
>> Desplegado ghcr.io/nettalco/dokploy:<commit>
>> Al dia con upstream/canary
```

La última línea avisa si el Dokploy oficial tiene novedades por traer. Solo aparece
en desarrollo.

Después, entrar al panel y comprobar que funciona: que se vea la marca de Nettalco,
que aparezcan los proyectos y que se pueda abrir alguno.

## Pasar a producción

Un cambio llega a producción en dos pasos: **promoverlo** y **desplegarlo**.

### 1. Promover

Promover es marcar como `stable` una imagen que ya se probó en desarrollo.

1. Averiguar el commit que corre en desarrollo. En ese servidor:

   ```bash
   cd ~/dokploy && git rev-parse HEAD
   ```

2. En GitHub: **Actions** → **Nettalco Promote** → **Run workflow**.
3. Pegar el commit completo (40 caracteres) en el campo **sha** y ejecutar.

Tarda menos de un minuto. El resumen de la ejecución muestra el commit y la huella
(*digest*) de la imagen promovida.

> Promover no despliega nada: solo cambia a qué imagen apunta `stable`. Producción
> sigue igual hasta el paso siguiente.

Con la línea de comandos de GitHub también se puede:

```bash
gh workflow run "Nettalco Promote" --repo Nettalco/dokploy \
  -f sha=<commit completo> -f channel=stable
```

### 2. Desplegar

En **cada** servidor de producción, de a uno:

```bash
cd ~/dokploy && ./deploy.sh stable
```

Conviene empezar por el que menos duela si algo falla, verificar, y recién después
seguir con el otro.

### Verificar

```bash
docker service ps dokploy --no-trunc | head -3
```

Tiene que figurar `Running` y una imagen `ghcr.io/nettalco/dokploy:stable`.

Para confirmar que el botón de actualizar quedó mirando el canal correcto:

```bash
docker service inspect dokploy \
  --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' | tr ',' '\n' | grep DOKPLOY_CUSTOM
```

En producción tiene que terminar en `:stable`. Si dice `:canary`, alguien desplegó
sin `stable`: corregirlo con `./deploy.sh stable`.

> No pegar la salida completa de ese `inspect` en chats ni tickets: incluye la
> contraseña de la base de datos de Dokploy. El `grep` de arriba la deja afuera.

## Deshacer un despliegue

```bash
cd ~/dokploy && ./deploy.sh rollback
```

Vuelve a la imagen que corría **antes del último despliegue**, con el mismo
procedimiento seguro, sin tocar el código ni el canal del servidor. Ejecutarlo dos
veces seguidas vuelve a la versión nueva: alterna entre las dos últimas.

Si responde *"No hay imagen anterior registrada"*, ese servidor todavía no tuvo un
despliegue con la versión actual del script, que es la que registra a dónde volver.
En ese caso, desplegar a mano la imagen deseada (ver
[problemas.md](problemas.md#desplegar-una-imagen-concreta-a-mano)).

## El botón de actualizar del panel

Está abajo en la barra lateral, y también en **Settings** → **Server**. Ambos abren
el diálogo **Web Server Update**: pulsar **Check for updates** y, si hay una imagen
nueva en su canal, ofrece instalarla. Solo lo ven los usuarios con permiso para
administrar la organización.

| | Desarrollo | Producción |
|---|---|---|
| Qué ofrece | Cualquier build nueva de `canary` | Solo lo promovido a `stable` |
| Cuándo aparece | Al rato de cada cambio subido | Solo después de promover |

Hace lo mismo que `deploy.sh`, así que da igual usar uno u otro.

Dos casos en que **no ofrece nada aunque haya novedades**, a propósito:

- si el servidor corre una imagen construida localmente con `./deploy.sh local`: no
  tiene huella con qué comparar, y antes que arriesgar un reemplazo se abstiene;
- si no puede consultar el registro de imágenes.

## Construir en el propio servidor

Solo como respaldo, si GitHub Actions no está disponible:

```bash
cd ~/dokploy && ./deploy.sh local
```

Construye la imagen en el servidor (varios minutos, consume CPU y disco). Mientras
corra una imagen así, el botón de actualizar no ofrece nada. Para volver a la
normalidad, el siguiente despliegue tiene que ser `./deploy.sh` o
`./deploy.sh stable`.

## Qué hace `deploy.sh` por dentro

Útil para entender un error:

1. **Se actualiza a sí mismo**: baja el código de `canary` y se vuelve a ejecutar
   con la versión nueva. Así un arreglo en el script rige desde la misma corrida.
2. **Elige la imagen**: la del commit (desarrollo), `stable` (producción), la anterior
   (*rollback*) o una construida ahí (`local`).
3. **Comprueba que exista** en el registro antes de tocar nada.
4. **Baja el servicio a cero**, espera a que termine, cambia la imagen y lo vuelve a
   levantar. Es la única forma confiable de liberar el puerto: ver
   [problemas.md](problemas.md#el-despliegue-se-queda-en-no-suitable-node).
5. Si algo falla con el servicio en cero, **lo vuelve a levantar** con la imagen
   anterior. Nunca deja el panel caído.
6. **Limpia** imágenes viejas, con un tope de tiempo.
7. En desarrollo, **avisa** si el Dokploy oficial tiene novedades.

Variables que el script deja configuradas en el servicio:

| Variable | Para qué |
|---|---|
| `DOKPLOY_CUSTOM_IMAGE` | Qué imagen y canal sigue el botón de actualizar |
| `RELEASE_TAG` | El canal, para mostrarlo en el panel |
| `DOKPLOY_REGISTRY_USER` / `DOKPLOY_REGISTRY_TOKEN` | Vacías. Solo hacen falta si el paquete de imágenes se vuelve privado |

Y una etiqueta, `nettalco.previous-image`, con la imagen anterior, que usa el
*rollback*.
