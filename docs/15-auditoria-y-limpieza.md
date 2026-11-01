# Auditoría de datos, limpieza y cierre del ciclo de recarga

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-15 |
| Versión | 1.0.0 |
| Fecha | 2026-10-31 |
| Estado | Vigente |
| Normas | ISO/IEC 27001:2022 A.8.10 · ISO/IEC/IEEE 12207 (mantenimiento) · ISO/IEC 25010 (fiabilidad, seguridad) |

## 1. Propósito

Este informe cierra dos trabajos sobre el backend de producción
(`gakkfzqcrapxeierfdhk`, PostgreSQL 17.11):

1. La **limpieza controlada** de datos de demostración, de prueba y caducados,
   sin tocar información real ni reiniciar contadores.
2. La **verificación del ciclo de recarga** de punta a punta, incluida la
   escritura física de la tarjeta maestra y el primer cobro real con el
   validador, con la evidencia en base de datos.

Las tablas genéricas que pedía el encargo inicial se traducen al esquema real
así: `profiles` → `accounts`, `wallets` → `cards.virtual_balance`,
`transactions` → `card_movements`, `logs` → `card_events` y `trips_telemetry`.
No existe una tabla `transactions` separada.

## 2. Método

1. Inventario de tablas, columnas, restricciones, índices, disparadores y
   funciones con consultas de solo lectura a `information_schema` y `pg_catalog`.
2. Búsqueda de cadenas de prueba (`test`, `foo`, `bar`, `dummy`, `placeholder`,
   `@test.*`, montos y referencias ficticias) en cuentas, tarjetas, vehículos,
   recargas y ajustes.
3. Revisión de orfandad por cada llave foránea y de políticas RLS.
4. El script de limpieza se ejecutó primero con `ROLLBACK` (simulación) y
   después se confirmó. Cada fila borrada queda archivada en
   `respaldo.purga_20261031`.
5. La prueba física se hizo contra producción con el validador `A12BC3D`
   (MAC `1C608BDF948C`) y la tarjeta maestra `A-00000-000-H`
   (UID `3981BF06`).

## 3. Inventario posterior a la limpieza

Conteo al 2026-10-31 20:48 (hora de Caracas). Los números de operación cambian
con el uso normal; durante la propia auditoría entraron dos recargas nuevas
desde el portal.

| Tabla | Filas | Función | RLS |
| --- | ---: | --- | --- |
| `accounts` | 1 | Cuenta administradora real. | Activa |
| `cards` | 1 | Maestra `A-00000-000-H`, saldo 4500 Bs. | Activa |
| `card_movements` | 4 | Recarga 5000 (aprobada), viaje −500 y dos recargas en revisión (5000 y 500). | Activa |
| `recharges` | 3 | Una aprobada y sincronizada; dos pendientes nuevas. | Activa |
| `trips_telemetry` | 1 | Primer viaje real, tarifa 500, saldo de chip 4500. | Activa |
| `card_events` | 4 | Historia de la maestra (MAESTRA → ALFA → ENROLADA). | Activa |
| `account_sessions` | 5 | Sesiones vigentes del panel; ninguna vencida. | Activa |
| `card_sessions` | 0 | Funciones heredadas, sin uso. | Activa |
| `vehicles` | 1 | Solo la unidad real `A12BC3D`. | Activa |
| `transit_routes` | 2 | Rutas de la línea. | Activa |
| `settlements` | 0 | Aún no se ha liquidado ningún período. | Activa |
| `card_batches` | 0 | Sin lotes; no quedan semillas de prueba. | Activa |
| `settings` | 1 | Configuración pública del portal. | Activa |

El esquema `respaldo` conserva copias de la migración `0006`
(`*_0006`) y ahora el archivo de esta purga. No son datos operativos y no deben
incluirse en reportes de negocio.

## 4. RLS, permisos y superficie expuesta

- Las **13 tablas** tienen `ROW LEVEL SECURITY` activo y **cero políticas**. Es
  el modo correcto aquí: el navegador no lee tablas, solo llama funciones RPC
  `SECURITY DEFINER`. Añadir políticas permisivas abriría la base sin necesidad.
  No se debe activar `FORCE ROW LEVEL SECURITY`: rompería las RPC, que corren
  como propietario.
- Hay 69 funciones `public.bt_*`; 26 son ejecutables por `anon`. Incluyen las
  del portal, las de sincronización del validador y las `bt_admin_*`, que exigen
  un token de sesión administrativa como parámetro.
- **No** son ejecutables por `anon`: `bt_aprobar_recarga`, `bt_rechazar_recarga`,
  `bt_acreditar_recarga`, `bt_recargas_pendientes`, `bt_liquidar`,
  `bt_validador_sincronizar` (la variante por MAC) ni las de generación de
  lotes. La acreditación y la aprobación solo se pueden invocar con la clave de
  servicio o desde SQL. Correcto.
- El chequeo de token del validador es por hash SHA-256 guardado en
  `vehicles.sync_token_hash` y exige `active = true`; el token en claro nunca se
  almacena.

## 5. Integridad referencial

| Relación | Acción al borrar | Criterio | Estado |
| --- | --- | --- | --- |
| `cards.account_id → accounts` | `SET NULL` | La tarjeta sobrevive a la cuenta. | Correcto |
| `cards.batch_id → card_batches` | `SET NULL` | El lote es trazabilidad, no dueño. | Correcto |
| `card_movements.card_id → cards` | `CASCADE` | El historial no existe sin tarjeta. | Correcto |
| `recharges.card_id → cards` | `CASCADE` | Igual que el historial. | Correcto |
| `recharges.movement_id → card_movements` | `SET NULL` | Permite corregir movimientos sin perder la recarga. | Correcto |
| `trips_telemetry.*` (tarjeta, movimiento) | `CASCADE` / `SET NULL` | Telemetría ligada a la tarjeta; referencias opcionales. | Correcto |
| `trips_telemetry.vehicle_id`, `route_id`, `settlement_id` | `SET NULL` | Conserva el viaje aunque cambie la flota. | Correcto |
| `settlements.vehicle_id → vehicles` | `RESTRICT` | No se borra una unidad con liquidaciones. | Correcto |
| `account_sessions`, `card_sessions` | `CASCADE` | Sesión efímera. | Correcto |
| `card_events.card_id → cards` | `CASCADE` | Bitácora de la tarjeta. | Correcto |

No se encontraron registros huérfanos en recargas, viajes, movimientos ni
tarjetas al momento de la auditoría.

## 6. Datos placeholder encontrados y tratamiento

| Hallazgo | Ubicación | Decisión | Resultado |
| --- | --- | --- | --- |
| Unidad demo `A99XY7Z`, MAC `001122334455`, sin token, con 0 viajes y 0 liquidaciones (semilla de `0002_demo.sql`). | `vehicles` | Borrada y archivada en `respaldo.purga_20261031`. | Eliminada |
| Pago Móvil público con datos de ejemplo: RIF `J-00000000-0`, teléfono `0414-0000000`, titular «BLINK PASAJES, C.A.». | `settings.publico` | **No se modifica**: es información bancaria real que debe cargar el dueño. | Pendiente del propietario |
| Sesiones caducadas | `account_sessions`, `card_sessions` | Borradas si `expira < now()`. | 0 filas |
| Cadenas `test`, `foo`, `bar`, `dummy`, `placeholder` o correos de ejemplo | `accounts`, `cards`, `vehicles`, `recharges` | Búsqueda sin coincidencias. | Nada que borrar |
| Lotes o tarjetas de prueba | `card_batches`, `cards` | Ya se habían retirado; solo queda la maestra real. | Nada que borrar |
| Copias de seguridad `*_0006` | esquema `respaldo` | Se conservan: son respaldo histórico, no datos vivos. | Conservadas |

El titular «BLINK PASAJES, C.A.» es coherente con la cuenta bancaria heredada,
pero conviene confirmarlo junto con el RIF y el teléfono antes de mostrar el
portal a un pasajero real.

## 7. Secuencias

La única secuencia del esquema es `card_events_id_seq` (inicio 1, incremento 1,
último valor 26, con 4 filas y IDs 11, 15, 19 y 25). Los huecos provienen de
inserciones revertidas durante las pruebas y **no se reinician**: hacerlo
reutilizaría identificadores y rompería la trazabilidad de una bitácora.
La numeración de tarjetas no usa secuencias: `bt_generar_lote` asigna
`batch_number` y `serial_number` con control de cupo en `card_batches`.

## 8. Ciclo de vida de la recarga

### 8.1 Correspondencia de estados

| Etapa genérica | Estado real en BLINK | Efecto en base |
| --- | --- | --- |
| `PENDING` | `recharges.status = 'pendiente'` y `card_movements.estado = 'pendiente'` | Se registra el intento con `id` UUID, banco, referencia, teléfono y fecha. El saldo no se toca. |
| `VERIFYING` / `PROCESSING` | `status = 'aprobado'` y `synced_to_chip = false` | El administrador aprobó y el saldo virtual ya se acreditó; falta que el chip lo reciba. |
| `COMPLETED` | `status = 'aprobado'` y `synced_to_chip = true` | El validador aplicó la recarga, confirmó el saldo del chip y se actualizó la telemetría. |
| `FAILED` / `CANCELLED` | `status = 'rechazado'` | El movimiento queda `rechazado`, el saldo no cambia y el motivo se guarda en el detalle. Cancelar es rechazar con motivo. |

No hay un estado `procesando` separado: la operación es atómica dentro de la
RPC y el único estado intermedio verdadero es «aprobado y aún no en el chip»,
que es justo lo que representa `synced_to_chip`.

### 8.2 Recorrido

1. **Reporte.** `bt_recargar` valida monto entero, tope, teléfono, banco y
   referencia; aplica un límite de 6 reportes cada 10 minutos por tarjeta;
   rechaza referencias ya vigentes; inserta el movimiento pendiente y la recarga
   pendiente en la misma transacción.
2. **Aprobación.** `bt_aprobar_recarga` bloquea la fila (`FOR UPDATE`), exige
   estado `pendiente`, suma el monto a `cards.virtual_balance`, marca el
   movimiento como aprobado con el saldo resultante y sella `resolved_at`,
   `resolved_by`.
3. **Rechazo.** `bt_rechazar_recarga` hace lo mismo pero deja el saldo intacto y
   pasa el movimiento a rechazado con el motivo.
4. **Entrega al chip.** En el siguiente `SYNC`, el validador recibe las recargas
   aprobadas sin sincronizar. En el toque aplica primero la recarga en el chip,
   descuenta el pasaje y reporta el saldo final.
5. **Confirmación.** `bt_validador_sincronizar` inserta `trips_telemetry` y el
   movimiento del viaje, actualiza `virtual_balance` y `last_chip_balance`, y
   marca `synced_to_chip = true` con `synced_at`.

### 8.3 Controles de idempotencia y doble ejecución

| Control | Dónde | Protege de |
| --- | --- | --- |
| Índice único parcial `recharges_unica_idx (card_id, bank, bank_reference) WHERE status <> 'rechazado'` | `recharges` | Reportar dos veces la misma referencia; permite reintentar tras un rechazo. |
| `SELECT … FOR UPDATE` + verificación de estado | `bt_aprobar_recarga`, `bt_rechazar_recarga` | Aprobar o rechazar dos veces la misma recarga. |
| `offline_id` único | `trips_telemetry` | Reenviar el mismo toque desde el validador. |
| `synced_to_chip` con filtro `NOT synced_to_chip` | `bt_validador_sincronizar` | Confirmar dos veces la misma entrega. |
| Token por hash y validador activo | `bt_validador_sincronizar_token` | Suplantar un equipo. |

### 8.4 Evidencia de la prueba real (2026-10-31)

| Paso | Resultado |
| --- | --- |
| Grabado del chip | `ENROLADA,serial=A-00000-000-H,uid=3981BF06`, saldo inicial 0, tarifa 0 (maestra). |
| Recarga aprobada | `7aa8b2ca-4bc9-4c57-98ce-548e45087e0e`, 5000 Bs, `aprobado`, `resolved_by` Diego Beleño. |
| Toque | Tarifa 500, `chip_balance_after = 4500`, `offline_id = 3981BF06-1-2-D41B70`, MAC `1C608BDF948C`. |
| Sincronización | `synced_to_chip = true` a las 20:40; `trips_telemetry` 1 fila; `recaudado = 500`. |
| Saldos | `virtual_balance = last_chip_balance = 4500`; movimientos +5000 y −500. |
| Resumen operativo | 1 pasaje, 500 recaudados, 500 por liquidar, 1 tarjeta activa, 4500 Bs en circulación. |

Al cierre de este informe quedaron **dos recargas pendientes nuevas**
(referencias `6466` por 5000 Bs y `4346` por 500 Bs), reportadas desde el portal
durante la auditoría. Son datos reales: esperan la revisión y aprobación del
administrador y no se tocaron.

## 9. Revisión de funciones y disparadores

Los únicos disparadores del esquema son `bt_tocar_actualizada` en `cards`,
`accounts` y `vehicles`; solo actualizan `updated_at`. **Ningún disparador mueve
saldos**: todos los cambios de saldo ocurren en RPC explícitas y auditables.
Esto es correcto y no conviene sustituirlo por disparadores implícitos.

Hallazgos de la revisión, con la mejora propuesta. Ninguno se aplicó en
producción durante esta auditoría; se dejan como migración futura.

| ID | Hallazgo | Riesgo | Propuesta |
| --- | --- | --- | --- |
| F-01 | `bt_aprobar_recarga` no comprueba que `movement_id` exista ni cuántas filas actualizó. Si una recarga quedara sin movimiento, se acreditaría el saldo sin registro en el historial. | M | Antes de acreditar, exigir `movement_id IS NOT NULL`; después, verificar `GET DIAGNOSTICS` y abortar si no se actualizó una fila. |
| F-02 | La sincronización comprueba `offline_id` con `EXISTS` y luego inserta; dos sincronizaciones simultáneas podrían chocar con el índice único y abortar el lote. | B | Insertar con `ON CONFLICT (offline_id) DO NOTHING` y continuar si no se insertó. |
| F-03 | La confirmación de recarga (`synced_to_chip`) acepta cualquier UUID aprobado, sin atarlo a la tarjeta ni al UID del validador que reporta. | B | Limitar la actualización a recargas de la tarjeta cuyo `chip_uid` coincide con el toque reportado. |
| F-04 | No hay caducidad de recargas pendientes ni trabajo programado (`pg_cron` no está instalado). Una recarga sin revisar queda pendiente para siempre. | M | Política operativa: rechazar con motivo «expirada» después de 7 días. Si se automatiza, instalar `pg_cron` y ejecutar una función `bt_expirar_recargas(interval)` diaria. |
| F-05 | Un toque puede sobrescribir `virtual_balance` con el saldo del chip cuando existe una recarga aprobada que ese equipo aún no descargó, dejando el crédito temporalmente fuera de la vista. | B | Al aplicar toques, no bajar `virtual_balance` por debajo de `last_chip + recargas aprobadas sin sincronizar`; o garantizar la descarga de pendientes antes de cobrar (el firmware ya aplica la pendiente al toque cuando la tiene). |
| F-06 | `bt_acreditar_recarga` acredita de inmediato sin pasar por la bandeja de pendientes (conciliación manual). | B | Mantenerla fuera de `anon` (hoy lo está) y usarla solo desde SQL o servicio; registrar el uso en la bitácora. |

Prioridad sugerida: F-01 y F-02 como parche corto; F-04 como política operativa
inmediata; F-03 y F-05 en la siguiente iteración del sincronizador.

## 10. Script de limpieza

Ruta: [`tarjeta/supabase/limpieza/2026-10-31_auditoria_y_purga.sql`](../supabase/limpieza/2026-10-31_auditoria_y_purga.sql).

- Se ejecuta en una sola transacción con `lock_timeout` y
  `statement_timeout`.
- Archiva cada vehículo borrado en `respaldo.purga_20261031` (id, tabla, fila
  JSONB y fecha), lo que permite reconstruirlo.
- Aborta si la unidad demo tuviera viajes o liquidaciones.
- Borra solo sesiones vencidas.
- Verifica al final que no quede el vehículo demo ni recargas huérfanas.
- **No** reinicia secuencias, **no** toca cuentas, tarjetas, recargas,
  movimientos, telemetría ni `settings`.

Resultado de la ejecución: 1 fila archivada y 1 vehículo borrado; 0 sesiones
vencidas; comprobaciones de cierre superadas.

## 11. Estado del cierre

| Etapa | Estado | Evidencia |
| --- | --- | --- |
| Datos de prueba purgados | Cerrado | `vehicles` solo tiene `A12BC3D`; archivo en `respaldo`. |
| RLS y permisos revisados | Cerrado | 13/13 tablas con RLS; 0 políticas; RPC acotadas por token. |
| Llaves foráneas revisadas | Cerrado | Matriz de §5; sin huérfanos. |
| Ciclo de recarga completo | Cerrado | Recarga 5000 aprobada, aplicada al chip y confirmada; viaje real de 500. |
| Chip de la maestra grabado | Cerrado | `ENROLADA,uid=3981BF06`, saldo 4500 tras el viaje. |
| Ajustes de Pago Móvil reales | Abierto | Depende del propietario. |
| Mejoras F-01 a F-06 | Abierto | Propuestas en §9. |
| Rotación de secretos y MFA | Abierto | BLINK-DOC-09 / BLINK-DOC-11. |

## 12. Control de cambios

| Versión | Fecha | Cambio |
| --- | --- | --- |
| 1.0.0 | 2026-10-31 | Creación: auditoría, purga del vehículo demo, revisión de RLS, integridad y ciclo de recarga, y evidencia de la prueba física de punta a punta. |
