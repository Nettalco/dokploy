# Traer las novedades del Dokploy oficial

[← Volver al manual](README.md)

El Dokploy oficial (*upstream*) publica correcciones y funciones nuevas casi todas las
semanas. Para tenerlas hay que **rebasar** el fork: reaplicar los cambios de Nettalco
encima de la versión nueva.

Es el único procedimiento de este manual que **no es mecánico**. Suele haber
conflictos en los archivos de la marca, y resolverlos mal puede romper los colores sin
que ningún error lo delate. Hacerlo con tiempo, nunca apurado.

## Cuándo

Cuando aparece el *issue* **"Dokploy: N commits nuevos en upstream"** (llega los
lunes), o cuando `./deploy.sh` en desarrollo termina con
`Hay N commits nuevos en upstream/canary`.

No hace falta hacerlo cada semana. Sí conviene no dejar que se acumulen demasiados:
cuantos más commits juntos, más probables los conflictos.

### Por qué `canary` y no `main`

El oficial usa `canary` para desarrollo y publica las versiones desde `main`. Este
fork sigue `canary` a propósito:

- `main` va semanas por detrás y recibe las correcciones mucho después;
- las versiones publicadas **no son más estables**: el error que dejó a los miembros
  sin acceso a sus proyectos estaba en las versiones `v0.29.14` y `v0.30.0`.

La protección real no es la rama sino el recorrido desarrollo → promoción →
producción.

## Qué hace falta

Una máquina de desarrollo (no un servidor) con:

- `git` y `gh`, con la cuenta **`Nettalco`** activa;
- Node **24** y `pnpm`;
- el repositorio clonado, con el remoto `upstream` apuntando al oficial:

  ```bash
  git remote add upstream https://github.com/Dokploy/dokploy.git
  ```

## Procedimiento

### 1. Ver qué viene

```bash
git checkout canary && git pull
git fetch upstream canary main --tags

# Cuántos commits faltan
git rev-list --left-right --count upstream/canary...canary
#   primer número: lo que falta traer   segundo: los commits propios de Nettalco

# Qué traen
git log --oneline --no-merges canary..upstream/canary
```

### 2. Medir el riesgo

```bash
MB=$(git merge-base upstream/canary canary)

# Migraciones de base de datos nuevas
git diff --name-only $MB upstream/canary -- apps/dokploy/drizzle/ | grep '\.sql$'

# ¿Tocaron archivos que Nettalco modificó?
git diff --stat $MB upstream/canary -- $(git diff --name-only $MB canary)
```

- **Migraciones nuevas**: el despliegue va a modificar la base de datos al arrancar.
  Hacer respaldo de la base de cada servidor antes de desplegar en él.
- **Archivos propios tocados**: va a haber conflictos ahí. Ver
  [Conflictos conocidos](#conflictos-conocidos).

### 3. Respaldo

```bash
git branch -f backup-canary-pre-sync canary
git push origin backup-canary-pre-sync --force
```

Si algo sale mal en cualquier paso posterior, se vuelve a este punto con
`git reset --hard backup-canary-pre-sync`.

### 4. Rebasar

```bash
git rebase upstream/canary
```

Si se detiene por un conflicto: resolverlo (ver abajo), luego

```bash
git add <archivo>
git rebase --continue
```

y repetir hasta el final. Para abandonar todo y volver al estado anterior:
`git rebase --abort`.

### 5. Verificar

**Ningún paso se saltea.** El *typecheck* no revisa el CSS, y un color roto no da
ningún error: por eso se compila y se mira el resultado.

```bash
pnpm install --frozen-lockfile
pnpm --filter dokploy typecheck
pnpm --filter dokploy exec vitest run --config __test__/vitest.config.ts \
  __test__/settings/ __test__/permissions/

rm -rf apps/dokploy/.next
pnpm --filter dokploy build-next
```

Comprobar que los colores de marca llegaron al CSS compilado:

```bash
F=$(ls -S apps/dokploy/.next/static/css/*.css | head -1)
grep -o -- "--primary:[^;]*;" "$F"
grep -c 'hsl(hsl(' "$F"
```

Las **dos últimas** líneas de `--primary` tienen que ser `#072e55` (tema claro) y
`#3e92f9` (tema oscuro). El segundo comando tiene que dar **0**. Si no se cumple
cualquiera de las dos, los colores están rotos: ver
[La trampa de los colores](#la-trampa-de-los-colores).

Y que no queden marcas de conflicto olvidadas:

```bash
git grep -n '^<<<<<<<' -- . && echo "QUEDAN CONFLICTOS SIN RESOLVER"
```

### 6. Subir

El rebase reescribe la historia, así que hace falta forzar:

```bash
gh auth switch --hostname github.com --user Nettalco
gh auth setup-git --hostname github.com
git push origin canary --force-with-lease
```

`--force-with-lease` falla si alguien más subió algo mientras tanto, en vez de
pisarlo.

### 7. Desplegar

Esperar a que termine la construcción de la imagen (~11 minutos, en **Actions** →
**Nettalco Image**) y seguir el recorrido normal de [despliegue.md](despliegue.md):
desarrollo, probar, promover, producción.

## Conflictos conocidos

### La trampa de los colores

`apps/dokploy/styles/globals.css` es el archivo más peligroso del fork.

El oficial está migrando sus colores a un formato nuevo (oklch), y por eso el archivo
tiene **dos sistemas de color a la vez**:

- uno viejo, dentro de `@layer base`, con valores como `210 85% 18%`;
- uno nuevo, **fuera** de cualquier `@layer`, con valores como `oklch(0.205 0 0)`.

En CSS lo que está fuera de un `@layer` le gana a lo que está dentro, sin importar el
orden. **El que manda es el bloque nuevo**, y ahí tienen que estar los colores de
Nettalco.

Si al resolver un conflicto se acepta la versión del oficial sin más, la marca queda
definida pero **sin efecto**: la aplicación se ve gris y ningún error lo avisa. Solo
se nota mirando el CSS compilado, que es la verificación del paso 5.

Cómo resolverlo:

1. Aceptar la estructura del oficial.
2. En los bloques `:root { … }` y `.dark { … }` del sistema nuevo, reemplazar los
   valores por los de Nettalco, escritos como `hsl(210 85% 18%)` —con paréntesis, no
   la versión sin ellos—. El bloque `@theme inline` los pasa tal cual.
3. Repetir la verificación del paso 5.

Paleta de Nettalco:

| Uso | Tema claro | Tema oscuro |
|---|---|---|
| Primario | `hsl(210 85% 18%)` azul marino | `hsl(213 94% 61%)` celeste |
| Secundario | `hsl(213 94% 61%)` celeste | `hsl(210 60% 25%)` |
| Acento | `hsl(213 94% 61%)` celeste | `hsl(213 94% 61%)` celeste |
| Error | `hsl(0 73% 51%)` | `hsl(0 73% 51%)` |
| Fondo | `hsl(0 0% 100%)` | `hsl(210 85% 5%)` |
| Bordes | `hsl(215 20% 91%)` | `hsl(210 60% 20%)` |

> El comentario del archivo dice que el primario es `#082853`, pero el valor real
> compila a `#072e55`. La diferencia viene del branding original y no se corrigió.

**El error silencioso**: el sistema viejo envuelve los valores en `hsl(...)`. Si una
variable ya trae `hsl(...)` adentro, queda `hsl(hsl(...))`, que el navegador ignora
sin avisar. Es lo que detecta el `grep -c 'hsl(hsl('` del paso 5.

### El logo

`apps/dokploy/components/shared/logo.tsx`. El oficial agrega funciones de logo cada
tanto (por ejemplo, logos distintos para tema claro y oscuro). Resolver **quedándose
con la lógica nueva del oficial** y conservando al final la alternativa de Nettalco:

```tsx
  return (
    <img src="/logo.svg" alt="Nettalco" ... />
  );
```

### El título de la página

El oficial pasó el `<title>` de `apps/dokploy/pages/_app.tsx` a `_document.tsx`, que
lo genera en el servidor. Si aparece un conflicto en `_app.tsx` por un bloque
`<Head>`, aceptar la versión del oficial (sin ese bloque).

### El commit de formato

Hay un commit propio llamado *"style: apply biome formatting to Nettalco branding
files"* que suele chocar con lo ya resuelto en pasos anteriores del mismo rebase.
Casi siempre se resuelve tomando la versión que ya está (`HEAD`).

### Workflows nuevos del oficial

Un rebase puede traer workflows nuevos de GitHub Actions. Revisar con

```bash
gh workflow list --repo Nettalco/dokploy --all
```

Si alguno nuevo intenta publicar en el Docker Hub del oficial o depende de sus
secretos, va a fallar en cada cambio: desactivarlo con
`gh workflow disable "<nombre>" --repo Nettalco/dokploy`. Los que solo se ejecutan a
mano no molestan.

## Precauciones

**No ejecutar `pnpm format-and-lint:fix` en Windows.** Reescribe los finales de línea
de casi mil archivos y genera un cambio gigante que choca con todo. Para formatear,
hacerlo archivo por archivo:

```bash
npx biome check --write <archivo>
```

**El número de versión no avanza.** En `canary`, el `package.json` conserva la
versión anterior hasta que el oficial publica, porque el cambio de número solo se
hace en `main`. Que diga una versión vieja no significa que el código lo sea.

**Deshacer una sincronización ya subida:**

```bash
git reset --hard backup-canary-pre-sync
git push origin canary --force-with-lease
```

Y en los servidores donde ya se desplegó, `./deploy.sh rollback`.
