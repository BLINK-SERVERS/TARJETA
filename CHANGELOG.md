# Changelog — BLINK TARJETA

Todos los cambios relevantes de este producto se documentan aquí.

Formato basado en [Keep a Changelog 1.1.0](https://keepachangelog.com/es-ES/1.1.0/)
y versionado [SemVer 2.0.0](https://semver.org/lang/es/). Las fechas usan ISO 8601.

## [No publicado]

### Pendiente

- Recuperación de PIN en el portal.
- Interfaz de aprobación de recargas para el administrador.
- Notificaciones por correo al acreditar una recarga.
- Gestión de operadores y reinicio de TOTP desde la interfaz del back-office.
- Prueba física de enrolado y cobro con el lector (tarea #28).

## [1.2.0] — 2026-10-29

Back-office separado del portal, con control de acceso por rol y verificación en
dos pasos; el panel opera con token de sesión, nunca con la clave de servicio.

### Añadido

- **Migración `0007_backoffice_mfa.sql`**: columnas `totp_secret`, `totp_activo`
  y `totp_confirmado_at` en `accounts`, y verificación TOTP RFC 6238 (HMAC-SHA1,
  30 s, 6 dígitos, ventana ±1) implementada en PL/pgSQL sobre `pgcrypto`.
- **Sesiones de back-office**: `bt_admin_sesion` valida token vigente y rol
  `ADMIN`/`TAQUILLA`; `bt_admin_sesion_mfa` exige además el segundo factor.
- **Acceso del operador**: `bt_admin_entrar`, `bt_admin_estado`,
  `bt_admin_mfa_inscribir` y `bt_admin_mfa_activar`. El secreto TOTP solo sale al
  inscribir el dispositivo.
- **RPC administrativas con token**: `bt_admin_resumen`, `bt_admin_lote`,
  `bt_admin_catalogo`, `bt_admin_enrolar` y `bt_admin_asignar`. Concedidas a
  `anon`; las funciones primitivas de operación siguen cerradas.
- **Migración `0008_backoffice_lectura.sql`**: consultas de solo lectura
  `bt_admin_lotes` y `bt_admin_tarjetas` para lotes e inventario.
- **Aplicación BLINK BACK-OFFICE** (`BLINK-SERVERS/BACKOFFICE`), publicada en
  https://blink-servers.github.io/BACKOFFICE/: acceso, inscripción TOTP, resumen,
  lotes, inventario, estación con lector Web Serial y taquilla; exportación CSV.
- **Documentación**: BLINK-DOC-02/03/04/05/06/07/08/09/10 y el índice pasan a
  1.2.0 con las migraciones, el contrato del panel y las pruebas de aceptación.

### Cambiado

- El rol de la cuenta se verifica en **cada** RPC del panel, no solo al entrar;
  retirar el rol invalida la sesión administrativa sin tocar el token.
- El panel guarda el token en `sessionStorage` (se pierde al cerrar la pestaña).
- `bt_admin_tarjetas` devuelve `titular` y `cedula` en `null` para tarjetas sin
  dueño, en lugar del nombre por defecto del plástico.

### Seguridad

- El navegador del operador ya no necesita `service_role`: todas las operaciones
  pasan por RPC que autentican el token en el servidor.
- El código TOTP se verifica en la base; el secreto nunca vuelve en el inicio de
  sesión ni en la consulta de estado.
- Reiniciar la inscripción invalida el secreto anterior; un secreto mostrado en
  una captura o chat se considera expuesto.
- Cinco intentos fallidos siguen bloqueando la cuenta 5 minutos, también en el
  back-office.

### Base de datos

- `0007` y `0008` aplicadas en producción el 2026-10-29, con prueba de aceptación
  (`PRUEBAS_0007_OK`) y `ROLLBACK`. Estado posterior: 20 tarjetas `FABRICADA`,
  1 lote, 1 cuenta administradora con segundo factor pendiente y 0 eventos.

## [1.1.0] — 2026-10-29

Aprovisionamiento en lote y activación por reclamo, con base inicial controlada.

### Añadido

- **Estado `FABRICADA`**: los lotes se pre-generan sin dueño, sin saldo y sin
  acceso al portal (Fase 1 del modelo corporativo).
- **Activación por reclamo**: `bt_vincular` convierte una tarjeta `FABRICADA` en
  `ACTIVE`, sella `asignada_at`/`asignada_por` y escribe la bitácora.
- **Estación de asignación**: `bt_estacion_enrolar` carga pares UID↔serial en
  bloque (hasta 5.000 por tanda) con reporte de rechazos; `bt_estacion_catalogo`
  devuelve la hoja del lote y `bt_estacion_asignar` vincula en taquilla a una
  cuenta existente.
- **Bitácora `card_events`** (`ENROLADA`, `ASIGNADA`, `PERDIDA`) con canal y
  operador.
- **Rol de cuenta** (`PASAJERO`/`TAQUILLA`/`ADMIN`) como base del RBAC del
  back-office.
- **Metadatos de lote**: `origen` (`FABRICANTE`/`ESTACION`), `creado_por` y
  `cerrado_at`; `bt_generar_lote` acepta `p_origen` y devuelve el estado.
- **Purga archivada**: las tablas de demostración se copian a `respaldo.*_0006`
  y la bitácora `respaldo.bitacora` impide repetirla.
- **Cuenta administradora única**: se crea con el PIN recibido por
  `set_config('blink.admin_pin', …)`; el valor no se versiona.
- **Lote de arranque** de 20 tarjetas cuando la base queda vacía.

### Cambiado

- `bt_reportar_perdida` rechaza tarjetas `FABRICADA` (aún sin dueño).
- `bt_resumen_operativo` informa `fabricadas` y `asignadas`.
- `bt_cuenta_json` incluye `rol`.
- La migración 0006 sustituye `bt_generar_lote(int,text,int,int)` por la firma de
  cinco parámetros (compatible: el quinto tiene valor por defecto).

### Seguridad

- `card_events` con RLS y sin permisos para `anon`/`authenticated`.
- Las funciones de estación, lote y resumen quedan solo en `service_role`;
  `anon` conserva únicamente el contrato del portal.
- La purga es reversible desde el esquema `respaldo` (sin RPC, solo consola SQL).

## [1.0.0] — 2026-10-29

Primera versión publicada con cuenta de pasajero y billetera multi-tarjeta.

### Añadido

- **Cuenta del pasajero** (`accounts`): nombres, apellidos, cédula `V/E`,
  teléfono, correo, PIN de 6 dígitos y fuente de Pago Móvil.
- **Billetera multi-tarjeta**: una cuenta puede vincular varias tarjetas por
  serial (`cards.account_id`); carrusel con varias tarjetas en la interfaz.
- **Sesión de cuenta** (`account_sessions`) con token UUID de 12 horas.
- **Registro en dos pasos**: datos personales y luego pregunta de Pago Móvil
  (propia o de un familiar).
- **RPC nuevas**: `bt_registrar`, `bt_sesion`, `bt_vincular`, `bt_actualizar_pago`
  y las nuevas firmas de `bt_entrar`, `bt_movimientos`, `bt_recargar` y `bt_salir`.
- **Tarjeta virtual ID-1/CR80**: proporción 1,586:1 bloqueada, radio
  `clamp(12px, 3.7cqw, 16px)`, bisel interior y sombra difusa; interior escalado
  con container queries.
- **Perfil**: datos de la cuenta, fuente de pago editable, tarjeta seleccionada,
  apariencia y seguridad.
- **Documentación ISO**: suite `docs/` (BLINK-DOC-00 a 10) y este CHANGELOG.

### Cambiado

- El PIN dejó de vivir en el plástico y pasó a la cuenta (6 dígitos, sin
  repeticiones ni secuencias).
- `bt_movimientos` y `bt_recargar` ahora reciben el serial de la tarjeta.
- El enlace a BLINK PASAJES apunta a `https://pasajes.blink.com.ve/`.
- La tarjeta virtual usa `aspect-ratio` en lugar de `min-height`, y todas las
  medidas interiores se expresan en `cqw`.

### Corregido

- La tarjeta se deformaba en pantallas de 280–360 px: se eliminó `min-height` y se
  escaló el contenido con unidades de contenedor.
- El titular mostrado en la billetera es siempre el de la cuenta (no el grabado
  en la tarjeta).

### Seguridad

- `accounts` y `account_sessions` con RLS y sin permisos para `anon`/`authenticated`;
  acceso solo mediante RPC `security definer`.
- PIN almacenado con bcrypt (`extensions.crypt`, costo 10).
- Bloqueo de 5 minutos tras 5 intentos fallidos.
- Validación de tarjeta bloqueada, vencida, duplicada o de otra cuenta antes de
  vincular.
- Límite de 6 reportes de recarga por tarjeta cada 10 minutos y rechazo de
  referencias repetidas.

### Eliminado

- Firmas anteriores `bt_movimientos(text,int)` y
  `bt_recargar(text,numeric,text,text,text)` (reemplazadas por versiones con serial).

### Base de datos

- Migración `0005_cuentas.sql` aplicada en producción el 2026-10-29 (PostgreSQL
  17.11). Verificada con 14 casos RPC como rol `anon` y `ROLLBACK`.

## Historial anterior a 1.0.0

Commits que construyeron el producto (rama `main`):

| Fecha | Commit | Cambio |
| --- | --- | --- |
| 2026-10-28 | `486dd48` | Portal del pasajero con tarjeta recargable. |
| 2026-10-28 | `eb76d72` | Claves de Supabase desde variables del repositorio. |
| 2026-10-29 | `23b1af3` | ID BLINK de 10 dígitos con Luhn. |
| 2026-10-29 | `5dd8354` | Alineación con el esquema del manual técnico del ecosistema. |
| 2026-10-29 | `e88ddb9` | Generador de lotes con serial Luhn y hoja de impresión. |
| 2026-10-29 | `20ac8e3` | Cierre de las funciones de operación a `anon`. |
| 2026-10-29 | `58e1e5a` | Cuenta de pasajero con billetera multi-tarjeta. |
| 2026-10-29 | `69cb2d3` | Tarjeta virtual con proporción ID-1/CR80 bloqueada. |

## Cómo mantener este archivo

- Añade entradas bajo `[No publicado]` mientras desarrollas.
- Al publicar, renombra a `[x.y.z] — AAAA-MM-DD` y crea un nuevo `[No publicado]`.
- Usa las categorías: Añadido, Cambiado, Obsoleto, Eliminado, Corregido, Seguridad.
- Un cambio incompatible de RPC o esquema obliga a subir la versión mayor.
