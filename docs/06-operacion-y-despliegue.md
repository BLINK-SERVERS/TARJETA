# Operación y despliegue

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-06 |
| Versión | 1.1.0 |
| Fecha | 2026-10-29 |
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

# BLINK POS
cd BLINK_POS_Project/app
npm ci && npm run dev
```

Para que TARJETA use la nube en local, crear `.env.local` (nunca se commitea):

```dotenv
VITE_SUPABASE_URL=https://<ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<clave publishable>
```

Sin ese archivo la app arranca en **modo demostración** (datos locales).

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

### 3.3 BLINK POS (manual)

```bash
cd BLINK_POS_Project/app
npm run deploy         # build:pages + gh-pages -d dist -t
```

Publica en la rama `gh-pages`; Cloudflare sirve `www.blink.com.ve`. El script
`postbuild-pages.mjs` genera `404.html` y `.nojekyll` para rutas profundas.

### 3.4 Rollback de una publicación

| Producto | Procedimiento |
| --- | --- |
| TARJETA / PASAJES | Revertir el commit conflictivo (`git revert`) y empujar; el workflow republica. Alternativa: `gh run rerun <id>` del último run bueno (no cambia el código). |
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
   # … 0002, 0003, 0004, 0005
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

Comprobaciones:

```sql
select status, count(*) from public.cards group by status order by status;
select evento, canal, count(*) from public.card_events group by 1, 2 order by 1;
select clave, ejecutado, detalle from respaldo.bitacora;
```

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
