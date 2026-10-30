# Operación y despliegue

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-06 |
| Versión | 1.3.0 |
| Fecha | 2026-10-30 |
| Estado | Vigente |
| Norma | ISO/IEC/IEEE 12207 (operación y mantenimiento) |

## 1. Prerrequisitos

| Herramienta | Versión usada | Notas |
| --- | --- | --- |
| Node.js | 22 en CI (24 en el equipo de desarrollo) | `npm ci` para instalaciones reproducibles. |
| npm | 10+ | — |
| GitHub CLI | 2.x | `gh auth login` con acceso a `BLINK-SERVERS`. |
| psql | 16+ | Cliente para migraciones y consultas. |
| arduino-cli | 1.x | Flasheo de firmware ESP32. |
| Docker | opcional | PostgreSQL 16 local para probar migraciones. |

## 2. Desarrollo local

```bash
# BLINK TARJETA
cd BLINK_Tarjeta
npm ci
npm run dev            # http://localhost:5173
npm run typecheck
npm test
npm run build          # dist/

# BLINK PASAJES
cd BLINK_Pasajes_Project/app
npm ci && npm run dev

# BLINK BACK-OFFICE
cd BLINK_Backoffice
npm ci && npm run dev   # http://localhost:5176

# BLINK POS
cd BLINK_POS_Project/app
npm ci && npm run dev
```

Para que TARJETA use la nube en local, crear `.env.local` (nunca se commitea):

```dotenv
VITE_SUPABASE_URL=https://<ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<clave publishable>
```

Sin ese archivo la app arranca en **modo demostración** (datos locales). El
back-office no tiene modo local: sin esas dos variables muestra el aviso
«Falta configurar el servidor» y no deja entrar.

## 3. Despliegue de las aplicaciones

### 3.1 BLINK TARJETA (automático)

```bash
git push origin main
```

El workflow `.github/workflows/pages.yml` ejecuta `npm ci`, `typecheck`, `test` y
`build --base=/TARJETA/`, y publica con `deploy-pages`. Si falla cualquier paso,
no se publica nada.

- Verificación: `gh run list --repo BLINK-SERVERS/TARJETA --limit 3`
- URL: https://blink-servers.github.io/TARJETA/

### 3.2 BLINK PASAJES (automático)

Igual que TARJETA, pero compila en la raíz (`npm run build`) porque sirve el
dominio completo `pasajes.blink.com.ve`.

- Verificación: `gh run list --repo BLINK-SERVERS/PASAJES --limit 3`
- El script `npm run dominio` fija el dominio y fuerza HTTPS vía API de GitHub
  (requiere `CLOUDFLARE_API_TOKEN` con acceso a la zona).

### 3.3 BLINK BACK-OFFICE (automático)

Repositorio propio (`BLINK-Servers/BACKOFFICE`), mismo código de base y mismo
proyecto Supabase. Compila con la base `/BACKOFFICE/` porque no tiene dominio
propio todavía.

```bash
git push origin main
```

- Workflow `.github/workflows/pages.yml`: `npm ci`, `typecheck`,
  `build --base=/BACKOFFICE/` con las variables `VITE_SUPABASE_URL` y
  `VITE_SUPABASE_ANON_KEY` del repositorio, y `deploy-pages`.
- Verificación: `gh run list --repo BLINK-SERVERS/BACKOFFICE --limit 3`
- URL: https://blink-servers.github.io/BACKOFFICE/
- La primera publicación requiere habilitar Pages:
  `gh api -X POST repos/BLINK-SERVERS/BACKOFFICE/pages -f build_type=workflow`.

### 3.4 BLINK POS (manual)

```bash
cd BLINK_POS_Project/app
npm run deploy         # build:pages + gh-pages -d dist -t
```

Publica en la rama `gh-pages`; Cloudflare sirve `www.blink.com.ve`. El script
`postbuild-pages.mjs` genera `404.html` y `.nojekyll` para rutas profundas.

### 3.5 Rollback de una publicación

| Producto | Procedimiento |
| --- | --- |
| TARJETA / PASAJES / BACKOFFICE | Revertir el commit conflictivo (`git revert`) y empujar; el workflow republica. Alternativa: `gh run rerun <id>` del último run bueno (no cambia el código). |
| POS | `npm run deploy` desde un checkout del commit anterior, o `git revert` + nuevo deploy. |

## 4. Dominios y DNS (Cloudflare)

| Registro | Destino | Proxy |
| --- | --- | --- |
| `www` | `blink-servers.github.io` (CNAME) | Proxied (Cloudflare) |
| `pasajes` | `blink-servers.github.io` (CNAME) | **DNS only** |
| Registros MX/TXT | Proveedor de correo | DNS only |

> Los CNAME de GitHub Pages **deben ser DNS-only**. Con proxy activo, GitHub no
> puede emitir el certificado y el dominio queda en error. POS es la excepción
> histórica: Pages no tiene HTTPS forzado y Cloudflare termina TLS.

## 5. Trabajo con la base de datos

### 5.1 Conexión

El host directo `db.<ref>.supabase.co` es **IPv6**; desde redes IPv4 usar el pooler:

```bash
psql "host=aws-0-us-east-2.pooler.supabase.com port=5432 \
      user=postgres.<ref> dbname=postgres sslmode=require" \
     -c "select version();"
```

La contraseña se toma del gestor de secretos y se pasa por `PGPASSWORD` en el
entorno del comando. **No se escribe en archivos ni en el historial.** Si la sesión
del panel de Supabase expiró, hay que volver a entrar (GitHub o correo) antes de
aplicar migraciones: el editor SQL es la vía alternativa al pooler.

### 5.2 Aplicar una migración (procedimiento obligatorio)

1. Probar en PostgreSQL local:

   ```bash
   docker run --rm -d --name blink-eco -p 55433:5432 -e POSTGRES_PASSWORD=local postgres:16-alpine
   psql "postgresql://postgres:local@127.0.0.1:55433/postgres" -f supabase/migrations/0001_tarjeta.sql
   # … 0002, 0003, 0004, 0005, 0006, 0007, 0008, 0009, 0010
   ```

2. Ejecutar la migración nueva dentro de una transacción con
   `--single-transaction -v ON_ERROR_STOP=1`.
3. Verificar con el flujo RPC completo usando `SET LOCAL ROLE anon` y terminar en
   `ROLLBACK` para no dejar datos de prueba.
4. Aplicar en producción (siempre en transacción):

   ```bash
   psql "$CADENA" -v ON_ERROR_STOP=1 --single-transaction -f supabase/migrations/000N_x.sql
   ```

   `0006` además archiva y purga los datos de demostración y crea la cuenta
   administradora. El PIN se pasa en la misma sesión, nunca en el archivo:

   ```bash
   PGOPTIONS="-c blink.admin_pin=<PIN>" psql "$CADENA" -v ON_ERROR_STOP=1 \
     --single-transaction -f supabase/migrations/0006_lotes_corporativos.sql
   ```

   Sin `blink.admin_pin` la migración no crea la cuenta y avisa por `NOTICE`.

   Si no hay `psql` (p. ej. el panel de Supabase), se pega el archivo en el
   editor SQL con `select set_config('blink.admin_pin', '<PIN>', false);`
   antepuesto y se elige **Run and enable RLS** cuando el editor advierta de
   operaciones destructivas o de tablas sin RLS. El PIN no se guarda.

5. Confirmar: `select proname from pg_proc where proname like 'bt_%' order by 1;`
   y `select count(*) from public.accounts;` (debe ser coherente).
6. Registrar la migración en BLINK-DOC-03 §2 y en el CHANGELOG.

### 5.3 Consultas de salud

```sql
-- Integridad de la billetera
select count(*) filter (where account_id is not null) as vinculadas,
       count(*) filter (where status = 'ACTIVE')       as activas
  from public.cards;

-- Recargas pendientes de revisión
select count(*) from public.recharges where status = 'pendiente';

-- Sesiones vigentes
select count(*) from public.account_sessions where expira > now();
```

### 5.4 Provisión de lotes y estación de asignación

**Vía preferida: el back-office.** Abrir
https://blink-servers.github.io/BACKOFFICE/ e iniciar sesión con cédula y PIN de
una cuenta `ADMIN`/`TAQUILLA`. La primera vez el panel pide inscribir el segundo
factor: escanear el QR con Google Authenticator, Authy o 1Password y escribir el
código de 6 dígitos. Sin ese paso el panel no deja crear lotes ni asignar.

| Pantalla | Uso |
| --- | --- |
| Resumen | Totales de inventario y operación. |
| Lotes | Crear un lote `FABRICANTE`/`ESTACION` y exportar su hoja en CSV. |
| Inventario | Filtrar por lote, serial o estado; exportar. |
| Estación | Conectar el lector (Web Serial), capturar UID y cargar pares en bloque. |
| Taquilla | Asignar un serial a una cédula ya registrada. |

**Vía SQL (consola o `service_role`), para automatizaciones:**

```sql
-- Fase 1 · pre-generación (todas quedan en FABRICADA)
select public.bt_generar_lote(1000, 'Patrocinante', 23, 1, 'FABRICANTE');

-- Hoja de trabajo de la estación (serial, UID y estado)
select public.bt_estacion_catalogo('<uuid-del-lote>');

-- Carga de pares capturados con el lector USB/ESP32
select public.bt_estacion_enrolar(
  '<uuid-del-lote>',
  '[{"serial":"23-1-000001-9","uid":"0484CC62"},
    {"serial":"23-1-000002-7","uid":"04A1B2C3"}]',
  'operador-01'
);

-- Fase 2 alternativa · asignación en taquilla a una cuenta existente
select public.bt_estacion_asignar('23-1-000001-9', 'V-34201580', 'taquilla-01');
```

```sql
-- Comprobaciones
select status, count(*) from public.cards group by status order by status;
select evento, canal, count(*) from public.card_events group by 1, 2 order by 1;
select clave, ejecutado, detalle from respaldo.bitacora;
```

### 5.5 Reiniciar el segundo factor de un operador

Si el operador pierde el teléfono o el reloj del dispositivo se desfasa más de un
paso, se reinicia la inscripción (la cuenta vuelve a «MFA pendiente» y el panel
pide inscribir de nuevo):

```sql
update public.accounts
   set totp_secret = null, totp_activo = false, totp_confirmado_at = null
 where cedula_digitos = '<digitos>';
delete from public.account_sessions
 where account_id = (select id from public.accounts where cedula_digitos = '<digitos>');
```

Nunca se documenta ni se comparte un secreto TOTP: si aparece en un chat o en una
captura, se reinicia la inscripción.

La purga de `0006` es reversible: las filas originales quedan en
`respaldo.*_0006`. Para restaurar una tabla concreta, copiarla de vuelta con la
consola SQL (no hay RPC para eso, por diseño).

## 6. Firmware

| Sketch | Ruta | Función |
| --- | --- | --- |
| `BLINK_Lector` | `~/Arduino/BLINK_Lector/BLINK_Lector.ino` | Puente serie: `READY,BLINK,1`, `CARD,<UID>`, `PONG` a 115200 baudios. |
| `BLINK_Validador` | `~/Arduino/BLINK_Validador/BLINK_Validador.ino` | Cobro offline, Wi-Fi, NTP, sincronización HTTPS con token. |

Compilar y flashear:

```bash
arduino-cli compile --fqbn esp32:esp32:esp32 ~/Arduino/BLINK_Lector
arduino-cli upload  --fqbn esp32:esp32:esp32 -p /dev/ttyUSB0 ~/Arduino/BLINK_Lector
```

Enrolado manual (consola serie del validador):

```text
ENROLAR,23-1-000001-9,50000,1,3981BF06
```

`serial, saldo inicial, fare_type, UID`. El UID debe coincidir con
`cards.chip_uid` (se registra con `bt_enrolar_tarjeta`).

Los sketches **no están en los repositorios**; viven solo en el equipo de
desarrollo. Trasladarlos a un repositorio (o a `firmware/`) es una brecha abierta
(BLINK-DOC-09 R-04).

## 7. Monitoreo y alertas

| Señal | Dónde |
| --- | --- |
| Estado de despliegues | `gh run list` / pestaña Actions |
| Errores de RPC | logs de PostgREST en el panel de Supabase |
| Recargas pendientes | consulta SQL de §5.3 |
| Validadores sin sincronizar | `trips_telemetry.synced_at` nulo o antiguo |

No hay alertas automáticas configuradas; es una mejora pendiente (BLINK-DOC-09 R-06).

## 8. Copias de seguridad

1. Copia automática diaria del proveedor.
2. Copia lógica semanal:

   ```bash
   pg_dump "$CADENA" --no-owner --format=custom -f blink-$(date +%F).dump
   ```

3. Guardar el dump cifrado en el gestor de respaldos del equipo.
4. Probar una restauración al menos una vez por trimestre en una base nueva.

## 9. Lista de verificación de una publicación

- [ ] `npm run typecheck` y `npm test` en verde.
- [ ] Migraciones aplicadas y verificadas (si las hay).
- [ ] CHANGELOG actualizado.
- [ ] Documentos afectados actualizados (BLINK-DOC-03/04/05).
- [ ] Sin secretos en `git diff`.
- [ ] Workflow de Pages en verde y sitio cargando.
- [ ] Flujo crítico probado en producción (registro, vínculo, recarga).
- [ ] Si el cambio toca el panel: login con rol administrativo y segundo factor
      verificado en https://blink-servers.github.io/BACKOFFICE/.
