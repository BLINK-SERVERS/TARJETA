# Rotación de claves y secretos

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-11 |
| Versión | 1.0.0 |
| Fecha | 2026-10-30 |
| Estado | Vigente |
| Normas | ISO/IEC 27001:2022 (A.5.16, A.5.17, A.8.24) |
| Disparador | Claves expuestas en chat y en el registro de una sesión de asistencia; secretos en archivos locales con formato roto |

## 1. Regla de decisión

Una clave que apareció en un chat, una captura, un issue o un archivo legible
por otros se considera **comprometida**. No se evalúa la probabilidad de abuso:
se rota y se revoca la anterior. La rotación se hace **crear → actualizar →
verificar → revocar**, nunca al revés, porque revocar primero deja el sistema
caído sin vuelta atrás.

## 2. Checklist

Marca cada casilla en orden. La columna «bloquea» indica qué deja de funcionar
si se hace fuera de orden.

### Fase 0 · Preparación (15 min)

- [ ] Abrir el gestor de secretos y crear la carpeta `BLINK / rotación 2026-10`.
- [ ] Generar las claves nuevas **en el gestor**, nunca en el chat ni en la consola
      (evita que queden en el historial).
- [ ] Anotar la versión desplegada de cada sitio antes de tocar nada
      (`gh run list --repo BLINK-SERVERS/TARJETA --limit 1`, idem BACKOFFICE).
- [ ] Confirmar ventana: las fases 1–4 no cortan servicio; la fase 3 (clave
      publicable) republica TARJETA y BACKOFFICE.

### Fase 1 · Contraseña de PostgreSQL

- [ ] Panel Supabase → proyecto `gakkfzqcrapxeierfdhk` → **Project Settings →
      Database → Database password → Reset password**. Generar 24+ caracteres.
- [ ] Guardar en el gestor como `BLINK supabase/postgres 2026-10-30`.
- [ ] Probar por el pooler (§5.1). No crear `~/.pgpass` permanente.
- [ ] Buscar consumidores de la clave vieja (§4.1) y actualizarlos.

**Bloquea:** migraciones, `pg_dump` y cualquier `psql`. Ninguna aplicación web.

### Fase 2 · Clave secreta de Supabase (`sb_secret_…`)

- [ ] Panel → **Project Settings → API Keys → Secret keys → Create new key**.
      Nombre: `blink-operacion-2026-10`.
- [ ] Copiarla una sola vez al gestor.
- [ ] Reemplazarla en `~/Escritorio/.env` (solo si algún script la usa; hoy no hay
      consumidor en los repositorios).
- [ ] Verificar con `GET /rest/v1/accounts` (§5.2).
- [ ] Revocar la clave anterior en el panel.

**Bloquea:** scripts de servicio y tareas de administración por REST. Nunca debe
llegar a una variable `VITE_*` ni al navegador.

### Fase 3 · Clave publicable (solo higiene)

Es pública por diseño; rotarla **no** protege datos, pero cierra el hallazgo.

- [ ] Panel → **API Keys → Publishable key → Rotate**.
- [ ] Actualizar la variable del repositorio en TARJETA y BACKOFFICE:

  ```bash
  gh variable set VITE_SUPABASE_ANON_KEY --repo BLINK-SERVERS/TARJETA --body "$NUEVA"
  gh variable set VITE_SUPABASE_ANON_KEY --repo BLINK-SERVERS/BACKOFFICE --body "$NUEVA"
  ```

  (El valor se pasa por variable de entorno del comando; nunca se escribe en el
  repositorio ni en el historial.)
- [ ] Relanzar ambos workflows (`gh workflow run pages.yml --repo …`) y esperar verde.
- [ ] Verificar acceso en TARJETA y BACKOFFICE (§5.5).

**Bloquea:** ambos portales hasta el redeploy. Hacer en horario de baja uso.

> Si lo que se filtró fue el **JWT secret heredado** (`anon`/`service_role`), la
> rotación invalida las dos claves a la vez y obliga a repetir esta fase; el
> procedimiento es el mismo, pero hay que actualizar también el POS si comparte
> proyecto (verificar `VITE_SUPABASE_URL` de cada `.env.local` antes de asumirlo).

### Fase 4 · PAT de GitHub (`ghp_…`)

- [ ] Buscar consumidores (§4.2).
- [ ] GitHub → **Settings → Developer settings → Personal access tokens** →
      revocar el token viejo.
- [ ] Crear uno *fine-grained*: acceso solo a `BLINK-SERVERS`, repositorios
      `TARJETA`, `BACKOFFICE`, `PASAJES`, `POS`; permisos **Contents: RW**,
      **Actions: RW** (relanzar workflows), **Pages: RW**, **Metadata: R**;
      caducidad 90 días.
- [ ] Copiarlo al gestor y a `~/Escritorio/.env`.
- [ ] Verificar con `GET /user` (§5.3).
- [ ] Si `gh` usaba ese mismo token, volver a autenticar: `gh auth login`.

**Bloquea:** scripts que usen el PAT y `gh` en las máquinas donde estuviera
exportado. Los despliegues por Actions no dependen de él.

### Fase 5 · Token de Cloudflare

- [ ] Verificar primero si sigue vivo (§5.4). Si ya responde `invalid`, solo hay
      que crear el nuevo.
- [ ] Cloudflare → **My Profile → API Tokens → Create Token**: permisos
      **Zone.DNS: Edit** y **Zone.Zone: Read**, recurso limitado a `blink.com.ve`.
      Caducidad 90 días.
- [ ] Actualizar `CLOUDFLARE_API_TOKEN` en `~/Escritorio/.env`.
- [ ] Verificar listando la zona (§5.4).
- [ ] Revocar el token anterior.

**Bloquea:** `npm run dominio` de PASAJES y cualquier cambio de DNS por API.
No afecta a GitHub Pages ni al sitio en sí.

### Fase 6 · Claves de LLM (Gemini / LLM_API_KEY)

- [ ] Google AI Studio → **API keys** → borrar la clave expuesta y crear otra.
- [ ] Actualizar `GEMINI_API_KEY`, `GEMINI_KEYS` y `LLM_API_KEY` en
      `~/Escritorio/.env`.
- [ ] Verificar con una llamada mínima al modelo.

**Bloquea:** solo pruebas locales; ningún producto publicado las usa.

### Fase 7 · Tokens de validador (si hubo pérdida de equipo)

No es rotación periódica: se rota por unidad, solo si el equipo o su token se
comprometió.

- [ ] Emitir token nuevo (se muestra una sola vez):

  ```sql
  select public.bt_validador_emitir_token('<MAC>');
  ```

- [ ] Enviarlo por la consola serie del ESP32: `TOKEN,<64 hex>`.
- [ ] Confirmar `SYNC,ok=1`.
- [ ] Si el equipo se perdió, revocar en lugar de emitir:

  ```sql
  select public.bt_validador_revocar_token('<MAC>');
  ```

### Fase 8 · Credenciales del operador (higiene, opcional)

- [ ] Cambiar el PIN de 6 dígitos desde el portal → **Perfil → Seguridad**.
- [ ] Reiniciar el secreto TOTP si el teléfono se perdió o el QR se compartió
      (procedimiento en BLINK-DOC-06 §5.5) y volver a inscribir el dispositivo.
- [ ] Nunca compartir el QR ni el secreto en grupo; el secreto se muestra una vez.

### Fase 9 · Cierre

- [ ] Actualizar BLINK-DOC-05 §5 (SEC-01 y SEC-02 → resueltos).
- [ ] Actualizar BLINK-DOC-09 §1 (R-01 y R-02 → mitigados/cerrados).
- [ ] Añadir la entrada en `CHANGELOG.md` bajo **Seguridad**.
- [ ] Borrar del gestor las claves anteriores (solo tras 7 días sin incidentes).
- [ ] Ejecutar la verificación completa de §5 y firmar el registro de §8.

## 3. Inventario

| Clave | Formato | Dónde vive | Consumidor | Si se filtra | Se rota en |
| --- | --- | --- | --- | --- | --- |
| Contraseña PostgreSQL | 24+ caracteres | Gestor de secretos | `psql`, `pg_dump`, migraciones | Acceso total a datos | Panel Supabase |
| Clave secreta | `sb_secret_…` | `~/Escritorio/.env` | Scripts de servicio | Omite RLS: lectura y escritura total | Panel → API Keys |
| Clave publicable | `sb_publishable_…` / JWT `anon` | Variables de repo, `.env` | Navegadores | Ninguno (RLS) | Panel → API Keys |
| PAT GitHub | `ghp_…` | `~/Escritorio/.env`, `gh` | Scripts, CLI | Escritura en repositorios | GitHub → Developer settings |
| Token Cloudflare | 40 caracteres | `~/Escritorio/.env` | `scripts/configurar-dominio.mjs` | Control del DNS de la zona | Cloudflare → API Tokens |
| Token de gestión Supabase | `sbp_…` | `BLINK_POS_Project/app/.env.local` | Management API | Administración de proyectos | Supabase → Account → Access Tokens |
| Claves LLM | `AIza…` / otras | `~/Escritorio/.env` | Pruebas locales | Cuota y coste | AI Studio |
| Token de validador | 64 hex | Hash en `vehicles.sync_token_hash` | ESP32 | Suplantar un validador | RPC (§2 fase 7) |
| PIN del operador | 6 dígitos | `accounts.pin_hash` (bcrypt) | Back-office | Acceso con TOTP | Portal → Perfil |
| Secreto TOTP | base32 | `accounts.totp_secret` | Autenticador | Segundo factor | Reinscribir |

## 4. Procedimientos

### 4.1 Buscar consumidores de la contraseña de la base

```bash
grep -rn --exclude-dir=node_modules --exclude-dir=.git \
  -e 'postgres.gakkfzqcrapxeierfdhk' -e 'PGPASSWORD' ~/BLINK_* ~/Descargas/*.md 2>/dev/null
```

Cualquier hallazgo en un archivo del repositorio es además una fuga: se elimina y
se revisa el historial. `alter role postgres with password …` **no** funciona por
el pooler («Only superusers can alter privileged roles»); la única vía es el panel.

### 4.2 Buscar consumidores del PAT

```bash
grep -rn --exclude-dir=node_modules --exclude-dir=.git \
  -e 'GITHUB_TOKEN' -e 'GH_TOKEN' -e 'ghp_' \
  ~/BLINK_Tarjeta ~/BLINK_Backoffice ~/BLINK_Pasajes_Project ~/BLINK_POS_Project 2>/dev/null
```

### 4.3 Crear claves sin dejarlas en el historial

```bash
read -rsp 'Clave nueva: ' NUEVA && export NUEVA
gh variable set VITE_SUPABASE_ANON_KEY --repo BLINK-SERVERS/TARJETA --body "$NUEVA"
unset NUEVA
```

Al escribir la clave se pega en el gestor y se pulsa Intro; no queda en
`~/.bash_history` ni en la salida del comando.

### 4.4 Conservar el servicio durante la rotación

| Situación | Qué hacer |
| --- | --- |
| Falla la verificación con la clave nueva | No revocar la anterior; corregir y repetir. |
| Se revocó por error | Crear otra al instante y repetir el despliegue; no hay recuperación del valor anterior. |
| El sitio muestra «Falta configurar el servidor» | La variable del repo no llegó al build: revisar `gh variable list` y relanzar. |
| `gh` deja de autenticar | `gh auth login` con el token nuevo. |

## 5. Verificación

Sustituir `$URL` por `https://gakkfzqcrapxeierfdhk.supabase.co` y las claves por
las nuevas, siempre por variable de entorno.

### 5.1 Base de datos

```bash
PGPASSWORD="$NUEVA" psql \
  "host=aws-0-us-east-2.pooler.supabase.com port=5432 \
   user=postgres.gakkfzqcrapxeierfdhk dbname=postgres sslmode=require" \
  -tAc "select 'ok', count(*) from public.accounts;"
```

### 5.2 Clave secreta

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "$URL/rest/v1/accounts?select=id&limit=1" \
  -H "apikey: $NUEVA_SECRET" -H "Authorization: Bearer $NUEVA_SECRET"
# Esperado: 200 (la clave de servicio omite RLS)
```

### 5.3 PAT de GitHub

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $NUEVO_PAT" https://api.github.com/user
# Esperado: 200
```

### 5.4 Cloudflare

```bash
curl -s -H "Authorization: Bearer $NUEVO_CF" \
  https://api.cloudflare.com/client/v4/user/tokens/verify
# Esperado: {"result":{"status":"active",...},"success":true}
```

### 5.5 Clave publicable y sitios

```bash
curl -s -X POST "$URL/rest/v1/rpc/bt_ajustes" \
  -H "apikey: $NUEVA_PUB" -H "Authorization: Bearer $NUEVA_PUB" \
  -H 'Content-Type: application/json' -d '{}' | head -c 200
# Esperado: JSON de configuración pública
```

| Sitio | Qué mirar |
| --- | --- |
| https://blink-servers.github.io/TARJETA/ | Carga en modo nube (sin aviso de demostración). |
| https://blink-servers.github.io/BACKOFFICE/ | Muestra el formulario de acceso, no «Falta configurar el servidor». |
| https://pasajes.blink.com.ve/ | Carga y certificado válido. |
| https://www.blink.com.ve/ | Carga; si usa otra clave, rotarla en su propio proyecto. |

## 6. Higiene de archivos locales

1. `~/Escritorio/.env` está **partido en líneas**: hay valores sueltos de 41 a 427
   caracteres, uno de ellos un fragmento de la clave publicable. Reescribirlo con
   una pareja `NOMBRE=valor` por línea y sin líneas huérfanas.
2. `~/BLINK_POS_Project/app/.env.local` tenía permisos `644` (legible por otros
   usuarios del equipo); el 2026-10-30 quedó en `600`. Verificar lo mismo en cada
   equipo donde se clone el proyecto: `chmod 600` a todos los `.env*`.
3. No usar el Escritorio como gestor de secretos: mover a `~/.config/blink/` con
   permisos `600` o dejarlos solo en el gestor.
4. `.env.example` **sí** se versiona, pero solo con marcadores. Revisión del
   2026-10-30: `BLINK_Tarjeta/.env.example` está limpio; en
   `BLINK_POS_Project/app/.env.example` la línea de `VITE_SUPABASE_PUBLISHABLE_KEY`
   tiene una clave real (pública, riesgo bajo) y debe sustituirse por un
   marcador en el próximo commit del POS.
5. Comprobar que ningún `.env` esté versionado:

   ```bash
   for r in ~/BLINK_Tarjeta ~/BLINK_Backoffice ~/BLINK_Pasajes_Project ~/BLINK_POS_Project; do
     git -C "$r" ls-files | grep -iE '(^|/)\.env' && echo "revisar: $r"
   done
   ```

6. Si un `.env` ya entró en un commit, rotar la clave **y** purgar el historial
   (`git filter-repo`) antes de volver a publicar el repositorio. Una clave
   publicable en un ejemplo solo exige sustituirla; una secreta exige purgar.

## 7. Rollback

| Clave | Marcha atrás |
| --- | --- |
| Contraseña de base | No hay: el valor anterior no se recupera. Mantener la sesión `psql` abierta durante la prueba. |
| Clave secreta / publicable | Solo si **no** se revocó la anterior; una vez revocada, crear otra. |
| PAT / Cloudflare | El token anterior se puede conservar activo hasta el cierre de la fase; revocarlo es el último paso. |
| Validador | Emitir otro token; el anterior deja de valer al emitir uno nuevo. |

Criterio de cierre: las cuatro verificaciones de §5 en verde y una sesión real en
cada sitio.

## 8. Registro de ejecución

| Fecha | Clave | Acción | Responsable | Verificación |
| --- | --- | --- | --- | --- |
| 2026-10-30 | — | Checklist emitido; rotación pendiente de ejecutar en el panel. | Equipo BLINK | — |
|  |  |  |  |  |

## 9. Referencias

- Gestión de secretos y respuesta a incidentes: BLINK-DOC-05 §6 y §7.
- Riesgos R-01 y R-02: BLINK-DOC-09 §1.
- Reinicio de TOTP: BLINK-DOC-06 §5.5.
- Contrato del panel y variables de despliegue: BLINK-DOC-04 §4, BLINK-DOC-06 §3.3.
