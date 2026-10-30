# Seguridad de la información

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-05 |
| Versión | 1.0.0 |
| Fecha | 2026-10-29 |
| Estado | Vigente |
| Norma | ISO/IEC 27001:2022 (A.5, A.8) · OWASP ASVS L1 |

## 1. Activos

| Activo | Clasificación | Dónde vive |
| --- | --- | --- |
| Datos de pasajeros (cédula, teléfono, correo) | Confidencial | `accounts` (Supabase) |
| PIN (hash bcrypt) | Confidencial | `accounts.pin_hash` |
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
| Validador | Token propio (`Authorization: Bearer`), puede sincronizar solo sus taps. |

Controles implementados:

- RLS activo en las 12 tablas; `revoke all` para `anon`/`authenticated` en todas.
- `security definer` con `search_path` fijo para evitar *search path injection*.
- Las funciones internas (`bt_*_json`, `bt_sesion_cuenta`, etc.) están revocadas.
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
| POS | Supabase Auth (correo + contraseña + verificación por código). |
| Validador | Token aleatorio, almacenado como hash en `vehicles.sync_token_hash`. |

El token se guarda en el navegador (almacenamiento local del portal). No se usa
`localStorage` para datos sensibles más allá del token y del estado de la billetera.

## 4. Protección de datos en tránsito y en reposo

- HTTPS obligatorio en las tres publicaciones (Pages y Cloudflare).
- Supabase cifra en reposo (gestión del proveedor).
- Las copias lógicas (`pg_dump`) deben cifrarse antes de salir del equipo.
- No se registran cédulas, teléfonos ni PIN en consola ni en analítica.

## 5. Riesgos de exposición conocidos

| ID | Hallazgo | Impacto | Acción |
| --- | --- | --- | --- |
| SEC-01 | La contraseña de PostgreSQL se compartió en un canal de chat y se reutilizó para operar la base. | Alto: acceso total a datos. | **Rotar en el panel de Supabase** y actualizar el gestor de secretos (pendiente, BLINK-DOC-09 R-01). |
| SEC-02 | Tokens de GitHub/Cloudflare/Supabase pegados en chat. | Alto. | Rotar cada token y revocar los anteriores. |
| SEC-03 | El repositorio es público. | Bajo: solo contiene claves publishable. | Verificar en cada PR que no entre `.env`, dumps ni tokens. |
| SEC-04 | No hay 2FA obligatorio en las cuentas de la organización. | Medio. | Activar 2FA en GitHub y Cloudflare. |

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
