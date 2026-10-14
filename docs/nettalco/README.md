# Dokploy Nettalco — Manual de operación

Dokploy es la plataforma desde la que se despliegan las aplicaciones de Nettalco.
Este repositorio es un **fork** del Dokploy oficial con la marca de Nettalco y con
herramientas propias para desplegarlo y mantenerlo al día.

> **Este manual es público**, igual que el repositorio. No contiene IPs, usuarios
> ni contraseñas. Los nombres de los servidores, sus accesos y quién tiene permisos
> están en el **inventario interno** de Confluence.

## Por dónde empezar

| Necesito… | Leer |
|---|---|
| Desplegar, pasar algo a producción o deshacer un cambio | [despliegue.md](despliegue.md) |
| Traer las novedades del Dokploy oficial | [actualizar-upstream.md](actualizar-upstream.md) |
| Algo falló | [problemas.md](problemas.md) |

## Comandos de todos los días

Siempre desde la carpeta del repo en el servidor (`~/dokploy`):

| Servidor | Para desplegar | Para deshacer |
|---|---|---|
| Desarrollo | `./deploy.sh` | `./deploy.sh rollback` |
| Producción — front | `./deploy.sh stable` | `./deploy.sh rollback` |
| Producción — back | `./deploy.sh stable` | `./deploy.sh rollback` |

> ⚠️ En producción **siempre** `./deploy.sh stable`. Sin `stable`, el servidor pasa
> a correr versiones sin probar y su botón de actualizar empieza a ofrecer cualquier
> build nueva.

## Cómo está armado

### Tres instancias independientes

Hay **tres** Dokploy, cada uno con su propio panel y su propia base de datos. No se
gestionan entre sí: cada uno se actualiza por separado.

| Instancia | Uso | Canal que sigue |
|---|---|---|
| Desarrollo | Probar antes que nadie | `canary` — la última versión construida |
| Producción — front | Aplicaciones de front | `stable` — solo lo promovido |
| Producción — back | Aplicaciones de back | `stable` — solo lo promovido |

Actualizar el panel de Dokploy **no detiene las aplicaciones** que gestiona: son
servicios aparte. Durante unos segundos no se puede entrar al panel, nada más.

### El recorrido de un cambio

```text
 cambio en el repo (rama canary)
            │
            ▼
 GitHub Actions construye la imagen ──► ghcr.io/nettalco/dokploy:<commit>
            │                          ghcr.io/nettalco/dokploy:canary
            ▼
 desarrollo:  ./deploy.sh   ◄── se prueba acá
            │
            │  ¿anduvo bien?
            ▼
 se promueve (a mano) ───────────────► ghcr.io/nettalco/dokploy:stable
            │
            ▼
 producción:  ./deploy.sh stable
```

La promoción **no reconstruye nada**: le pone la etiqueta `stable` a la misma imagen
que ya se probó. Producción corre exactamente el mismo binario que desarrollo.

### Las piezas

| Pieza | Qué es |
|---|---|
| `Nettalco/dokploy`, rama `canary` | El código. Fork de `Dokploy/dokploy` |
| `ghcr.io/nettalco/dokploy` | Las imágenes. Paquete **público**, no hace falta login para descargarlo |
| `deploy.sh` | Script que despliega en cada servidor |
| Workflow **Nettalco Image** | Construye la imagen en cada cambio de `canary` (~11 min) |
| Workflow **Nettalco Promote** | Mueve `stable` a una imagen ya probada. Se ejecuta a mano |
| Workflow **Nettalco Upstream Check** | Avisa cuando el Dokploy oficial tiene novedades |

### El botón de actualizar del panel

Dokploy trae un botón para actualizarse solo. En el original descarga la imagen
oficial, que **reemplazaría la de Nettalco y borraría la marca**. En este fork está
modificado para que cada servidor mire **su propio canal**:

- en desarrollo ofrece cualquier build nueva de `canary`;
- en producción solo ofrece lo que se haya promovido a `stable`.

Es equivalente a correr `deploy.sh`, así que se puede usar cualquiera de los dos.

### Avisos de novedades

El workflow **Nettalco Upstream Check** corre los **lunes a las 9:00** (hora de Lima).
Si el Dokploy oficial tiene cambios que el fork no tiene, abre un *issue* en el
repositorio con la lista; si ya hay uno abierto, lo actualiza en vez de duplicarlo.
Cuando el fork vuelve a estar al día, lo cierra solo.

El aviso llega por correo a quien **siga el repositorio** en GitHub. Para recibirlo:
en el repositorio, botón **Watch** → **Custom** → marcar **Issues**.

> Si quien recibe los avisos deja el equipo, otra persona tiene que activarlo con su
> propia cuenta, o los avisos se acumulan sin que nadie los vea.

También se puede ejecutar a mano: **Actions** → **Nettalco Upstream Check** →
**Run workflow**.

## Cuentas de GitHub

| Cuenta | Para qué |
|---|---|
| `Nettalco` | Dueña del repositorio y del paquete de imágenes. **Con esta se sube código** |
| Personal de quien opere | Solo para recibir los avisos. Sin permiso de escritura en el repo |

Con `gh` (la línea de comandos de GitHub) se pueden tener varias cuentas a la vez.
Si un `git push` responde **403**, casi seguro está activa la cuenta equivocada:

```bash
gh auth switch --hostname github.com --user Nettalco
gh auth setup-git --hostname github.com
```

## Qué tiene este fork que el oficial no

Conviene saberlo antes de traer novedades, porque es donde aparecen los conflictos.

**La marca de Nettalco**

| Archivo | Qué cambia |
|---|---|
| `apps/dokploy/public/logo.svg` | El logo |
| `apps/dokploy/components/shared/logo.tsx` | Usa el logo propio si no hay otro configurado |
| `apps/dokploy/components/layouts/onboarding-layout.tsx` | Nombre y descripción en la pantalla de ingreso |
| `apps/dokploy/styles/globals.css` | Los colores de marca. **El más delicado**: ver [actualizar-upstream.md](actualizar-upstream.md#la-trampa-de-los-colores) |
| `apps/dokploy/.env.production.example` | `NEXT_PUBLIC_APP_NAME` y `NEXT_PUBLIC_APP_DESCRIPTION`, que se hornean en la imagen |
| `apps/dokploy/pages/index.tsx` | Quita el ingreso con GitHub y Google, que es solo de la versión en la nube |

**El botón de actualizar apuntando al registro propio**

| Archivo | Qué cambia |
|---|---|
| `packages/server/src/services/custom-image.ts` | Toda la lógica. Archivo propio: nunca da conflicto |
| `packages/server/src/services/settings.ts` | Un enganche de cuatro líneas |
| `apps/dokploy/server/api/routers/settings.ts` | Un enganche de cuatro líneas |
| `packages/server/src/index.ts` | Una línea que exporta lo anterior |

**Herramientas de despliegue**: `deploy.sh` y los tres workflows `nettalco-*.yml`.

Los workflows del Dokploy oficial que publican en su Docker Hub están
**desactivados**: fallarían por falta de credenciales. Algunos otros siguen activos
porque solo se ejecutan a mano o con *pull requests* y no molestan.
