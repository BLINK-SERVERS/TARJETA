# Seguridad de la información

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-05 |
| Versión | 1.3.0 |
| Fecha | 2026-10-29 |
| Estado | Vigente |
| Norma | ISO/IEC 27001:2022 (A.5, A.8) · OWASP ASVS L1 |

## 1. Activos

| Activo | Clasificación | Dónde vive |
| --- | --- | --- |
| Datos de pasajeros (cédula, teléfono, correo) | Confidencial | `accounts` (Supabase) |
| PIN (hash bcrypt) | Confidencial | `accounts.pin_hash` |
| Secreto TOTP del operador | Secreto | `accounts.totp_secret` (solo lectura por `security definer`) |
| Saldo y movimientos | Interno | `cards`, `card_movements` |
| Datos de Pago Móvil | Interno | `accounts.pago_*` |
| Token de validador | Secreto | `vehicles.sync_token_hash` (hash) |
| Clave publishable | Público | GitHub Actions vars / `.env.local` |
| Contraseña de PostgreSQL | Secreto crítico | Gestor de secretos del equipo |
| Tokens de GitHub / Cloudflare / Supabase | Secreto crítico | Gestores personales |

## 2. Roles y permisos

| Rol | Puede |
| --- | --- |
| `anon` (clave pública) | Ejecutar **solo** los RPC del portal listados en BLINK-DOC-04 §2. |
| `authenticated` | Igual que `anon` en el esquema `bt_*`; en POS, sus propias filas por RLS. |
| `service_role` | RPC de operación y acceso total. **Nunca** se usa en el navegador. |
| Administrador de línea | Ejecuta RPC de servicio desde entorno confiable (script o consola). |
| Rol `ADMIN` / `TAQUILLA` | Columna `accounts.rol`; el back-office exige ese rol en cada RPC, no solo en el inicio de sesión. |
| Validador | Token propio (`Authorization: Bearer`), puede sincronizar solo sus taps. |

Controles implementados:

- RLS activo en las 13 tablas; `revoke all` para `anon`/`authenticated` en todas.
- `security definer` con `search_path` fijo para evitar *search path injection*.
- Las funciones internas (`bt_*_json`, `bt_sesion_cuenta`, `bt_admin_sesion`,
  `bt_totp_*`, etc.) están revocadas.
- `anon` ejecuta el contrato del portal **y** trece RPC de back-office que
  autentican por token de sesión con rol administrativo y segundo factor.
- **El precio de la recarga es autoritativo del servidor.** `bt_recargar_pasajes`
  no acepta montos: recotiza con `cards.tarifa` y `bt_cotizar_recarga`, y
  `bt_tarifario`/`bt_cotizar_recarga` están revocadas para clientes. Un cliente
  que altere la vista previa no cambia lo que se guarda.
- El tope de recarga y los parámetros tarifarios viven en `settings.publico`;
  el cliente solo los lee para previsualizar (`bt_ajustes`).
- El PIN nunca viaja al cliente después del registro y nunca se devuelve.
- La respuesta de `bt_entrar` no distingue entre cédula inexistente y PIN erróneo
  (mensaje genérico `credenciales`), salvo el bloqueo temporal.

## 3. Autenticación y sesiones

| Aspecto | Implementación |
| --- | --- |
| PIN | 6 dígitos, sin repeticiones ni secuencias; bcrypt costo 10 (`gen_salt('bf',10)`). |
| Intentos | 5 fallos → bloqueo 5 minutos (persistido en `accounts`). |
| Sesión de cuenta | UUID v4 en `account_sessions`, 12 h, purga de vencidas. |
| Sesión de tarjeta (legada) | `card_sessions`, 12 h; se elimina junto con la de cuenta en `bt_salir`. |
| Cuenta administradora | Se crea en `0006` con el PIN recibido por `set_config('blink.admin_pin', …)` en la sesión del operador; el valor no se versiona. |
| Derivación de PIN | bcrypt costo 10 vía `extensions.crypt`. Argon2id no está disponible en el `pgcrypto` de Supabase; bcrypt cumple el requisito mientras el PIN siga siendo de 6 dígitos y el intento esté limitado. |
| POS | Supabase Auth (correo + contraseña + verificación por código). |
| Validador | Token aleatorio, almacenado como hash en `vehicles.sync_token_hash`. |

El token se guarda en el navegador (almacenamiento local del portal). No se usa
`localStorage` para datos sensibles más allá del token y del estado de la billetera.

### 3.1 Back-office: RBAC y verificación en dos pasos

La operación administrativa se separó del portal del pasajero en un repositorio y
una publicación distintos, pero sobre la **misma** base cifrada. El control tiene
tres capas:

| Capa | Control |
| --- | --- |
| Sesión | Token en `account_sessions` validado por `bt_admin_sesion` en cada RPC. |
| Rol | `rol in ('ADMIN','TAQUILLA')`; un pasajero recibe `bt:permiso` aunque tenga token válido. |
| Segundo factor | TOTP RFC 6238 verificado con `pgcrypto` (`extensions.hmac(...,'sha1')`), 30 s, 6 dígitos, ventana ±1 paso. |

Diseño:

- **El secreto TOTP no toca el navegador más de una vez.** `bt_admin_mfa_inscribir`
  lo entrega para inscribir el dispositivo (QR `otpauth://`); ni el inicio de
  sesión ni la consulta de estado lo devuelven. Reiniciar la inscripción invalida
  el anterior.
- **Activar exige un código real.** `bt_admin_mfa_activar` valida con
  `bt_totp_valido` antes de marcar `totp_activo`; un código equivocado no activa.
- **Las RPC de inventario exigen MFA.** `bt_admin_sesion_mfa` bloquea con
  `bt:mfa` mientras el operador no tenga el segundo factor activo. Las consultas
  de lectura (estado, inscripción, catálogo) permiten terminar la inscripción.
- **El navegador nunca lleva `service_role`.** Las funciones primitivas
  (`bt_generar_lote`, `bt_estacion_*`, `bt_resumen_operativo`) siguen revocadas
  para `anon`; el panel pasa por envoltorios con token.
- **Token de sesión en `sessionStorage`** (clave `blink.backoffice.sesion`), no en
  `localStorage`: al cerrar la pestaña, el operador vuelve a autenticarse.
- **El segundo factor es por cuenta, no por dispositivo.** Tras una pérdida del
  teléfono, un administrador debe reiniciar la inscripción desde la consola SQL
  (`totp_secret = null, totp_activo = false`).

## 4. Protección de datos en tránsito y en reposo

- HTTPS obligatorio en las tres publicaciones (Pages y Cloudflare).
- Supabase cifra en reposo (gestión del proveedor).
- Las copias lógicas (`pg_dump`) deben cifrarse antes de salir del equipo.
- No se registran cédulas, teléfonos ni PIN en consola ni en analítica.
- TLS 1.3 con *forward secrecy* es el mínimo exigible al proveedor; el navegador
  habla `https://` y PostgREST rechaza conexiones sin TLS. La verificación de la
  versión negociada debe hacerse en la revisión trimestral (no es configurable
  desde el plan actual).
- Firmas HMAC de peticiones (HMAC-SHA256) **no** se implementan en el portal: la
  clave pública viajaría al navegador y el HMAC dejaría de aportar seguridad. Se
  reservan para integraciones servidor-a-servidor (webhook bancario).

## 5. Riesgos de exposición conocidos

| ID | Hallazgo | Impacto | Acción |
| --- | --- | --- | --- |
| SEC-01 | La contraseña de PostgreSQL se compartió en un canal de chat y se reutilizó para operar la base. | Alto: acceso total a datos. | **Rotar en el panel de Supabase** y actualizar el gestor de secretos (pendiente, BLINK-DOC-09 R-01). |
| SEC-02 | Tokens de GitHub/Cloudflare/Supabase pegados en chat. | Alto. | Rotar cada token y revocar los anteriores. |
| SEC-03 | El repositorio es público. | Bajo: solo contiene claves publishable. | Verificar en cada PR que no entre `.env`, dumps ni tokens. |
| SEC-04 | No hay 2FA obligatorio en las cuentas de la organización. | Medio. | Activar 2FA en GitHub y Cloudflare. |
| SEC-05 | El back-office no tiene MFA propio; el rol `ADMIN` solo vive en la base. | Medio. | **Resuelto en 0007:** TOTP obligatorio en las RPC de inventario. Queda operativo cuando la cuenta administradora inscriba su dispositivo. |
| SEC-06 | El reclamo se valida solo por serial impreso: quien conozca un serial libre puede reclamarlo. | Medio. | Añadir código de activación por tarjeta o doble confirmación en taquilla para lotes grandes. |

> Regla operativa: **ningún secreto se escribe en archivos del repositorio, en
> commits, en issues ni en la documentación.** Si un secreto se pega en un chat,
> se considera expuesto y se rota.

## 6. Gestión de secretos

| Secreto | Ubicación actual | Responsable de rotación |
| --- | --- | --- |
| Contraseña de PostgreSQL | Gestor de secretos del equipo | Administrador de la base |
| `SUPABASE_ACCESS_TOKEN` | Gestor de secretos del equipo | Administrador de Supabase |
| `CLOUDFLARE_API_TOKEN` | Gestor de secretos del equipo | Administrador de DNS |
| Credenciales de GitHub | Sesión del navegador / `gh auth` | Cada desarrollador |
| Publicación (publishable key) | Variable de repositorio (pública) | No requiere rotación periódica |

El procedimiento paso a paso —inventario, orden, verificación y rollback— está en
**BLINK-DOC-11** (rotación de claves y secretos).

Buenas prácticas:

1. Usar `.env.local` (ignorado por git) para desarrollo.
2. Pasar secretos por variable de entorno en el comando, nunca en el historial.
3. Revisar `git status` y `git diff` antes de cada commit.
4. Si se filtra una clave publishable, no compromete datos (RLS), pero se rota por
   higiene.

## 7. Respuesta a incidentes

1. **Contener:** revocar el token o rotar la contraseña afectada en el panel
   correspondiente (Supabase, Cloudflare, GitHub).
2. **Evaluar:** revisar `pg_stat_activity`, logs de PostgREST y accesos recientes.
3. **Erradicar:** corregir la causa (permiso, función o configuración).
4. **Recuperar:** restaurar desde copia si hubo alteración de datos; verificar
   saldos contra `card_movements`.
5. **Documentar:** añadir el incidente a BLINK-DOC-09 y una entrada en el CHANGELOG
   si el cambio es visible.
6. **Comunicar:** informar a la línea si hubo exposición de datos de pasajeros.

## 8. Revisión

La revisión de accesos y secretos se realiza en cada hito y como mínimo una vez por
trimestre. El resultado se registra en BLINK-DOC-09 (§2, riesgos).
