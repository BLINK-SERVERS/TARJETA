# Registro de riesgos, brechas y deuda técnica

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-09 |
| Versión | 1.7.0 |
| Fecha | 2026-10-31 |
| Estado | Vigente |
| Normas | ISO/IEC/IEEE 12207 (riesgos) · ISO/IEC 27001 (A.5.7) |

Escalas: probabilidad e impacto **A**lta / **M**edia / **B**aja. Estado:
**Abierto**, **Mitigado**, **Aceptado**.

## 1. Riesgos de seguridad

| ID | Riesgo | Prob. | Impacto | Mitigación | Estado |
| --- | --- | --- | --- | --- | --- |
| R-01 | Contraseña de PostgreSQL compartida en chat y reutilizada. | A | A | Rotar en el panel de Supabase; guardar solo en el gestor de secretos; actualizar los scripts de operación. | **Abierto** (tarea #29) |
| R-02 | Tokens de GitHub, Cloudflare y Supabase pegados en conversaciones. | A | A | Rotar y revocar los anteriores; activar 2FA. | **Abierto** |
| R-03 | Sin 2FA obligatorio en la organización. | M | A | Exigir 2FA a todos los miembros. | **Abierto** |
| R-04 | Repositorios públicos con historial de configuración. | B | M | Revisar que solo haya claves publishable; nunca commitear `.env`. | **Mitigado** |
| R-05 | Un mismo proyecto Supabase aloja comercio y transporte. | M | A | RLS estricto y dominios sin FK cruzadas; evaluar proyecto separado si crece. | **Aceptado** |
| R-06 | `bt_registrar` no tiene límite por IP (solo unicidad). | M | M | Añadir rate limiting en PostgREST/Cloudflare o captcha. | **Abierto** |
| R-07 | PIN de 6 dígitos de baja entropía protege la cuenta `ADMIN`. | M | A | Segunda capa implementada: TOTP RFC 6238 obligatorio en las RPC de inventario (0007). Falta que el operador inscriba su dispositivo. No reutilizar el PIN de arranque. | **Mitigado** (inscripción pendiente) |
| R-08 | Pérdida del teléfono del operador: el segundo factor solo se reinicia desde SQL. | B | M | Procedimiento documentado (BLINK-DOC-06 §5.5); añadir una RPC de reinicio asistido con doble aprobación. | **Aceptado** |
| R-09 | Si un secreto TOTP se muestra en una captura o chat, el factor queda expuesto. | B | M | Se reinicia la inscripción (invalida el secreto) y se considera expuesto. | **Mitigado** |
| R-10 | El modo sin conexión guarda en el teléfono datos personales (nombre, cédula, teléfono, correo, datos de pago) y el token de sesión en `localStorage`; un XSS o un equipo desbloqueado los expone. | M | A | Copia de solo lectura, sin capacidad de escritura ni claves de servicio; caduca a las 12 h de la última sincronización, rechaza fechas futuras y se borra al salir, al expirar la sesión o si el servidor la rechaza. Falta cifrado con WebCrypto atado al PIN y CSP (L-03). | **Mitigado** (residual aceptado) |
| R-11 | El service worker comparte origen con las demás publicaciones de GitHub Pages; una limpieza o un ámbito amplios podrían tocar o leer cachés ajenas. | B | M | Borra solo cachés con prefijo `blink-tarjeta-`, valida origen y ámbito de los mensajes, solo cachea recursos estáticos dentro de `/TARJETA/` y las respuestas de API quedan fuera. | **Mitigado** |

## 2. Brechas funcionales frente al diseño técnico

La fuente de verdad es `Documentación Técnica del Ecosistema Blink Pasajes`
(2026-10-29), conservada en `~/BLINK/documentacion/fuentes/`. Estado de
implementación:

| ID | Brecha | Impacto | Notas |
| --- | --- | --- | --- |
| B-01 | Mapa de memoria MIFARE por sectores y claves diversificadas `HMAC_SHA256(master, UID)` no implementado en la nube. | M | El firmware y el esquema actual usan UID + saldo virtual; falta la escritura segura del plástico. |
| B-02 | Lista negra offline en el validador: descarga implementada, prueba física pendiente. | M | El 2026-10-31 se probaron físicamente el enrolado y el cobro; falta bloquear una tarjeta y confirmar que el validador la rechaza sin red (BLINK-DOC-15 §8.4). |
| B-03 | ~~BLINK PASAJES opera en local, sin RPC `bt_*`.~~ | — | **Cerrada** el 2026-10-31: el panel se retiró; el flujo pasó al portal y al back-office. |
| B-04 | Aprobación de recargas sin bandeja en el back-office: se resuelve con RPC de servicio (`bt_recargas_pendientes`/`bt_aprobar_recarga`). | M | Añadir la pantalla de recargas pendientes al panel. |
| B-05 | Recuperación de PIN inexistente en el portal. | M | Requiere flujo de atención o verificación por correo. |
| B-06 | Telemetría fiscal sin exportación oficial (GTFS/CSV). | B | El módulo Fiscal muestra totales, no descarga. |
| B-07 | Estación de enrolado: la carga masiva UID↔serial existe en `0006` y su interfaz en el back-office (`BACKOFFICE`), falta el circuito físico completo con la placa. | M | El grabado del chip funciona por la consola serie (prueba real del 2026-10-31); falta conectarlo a la interfaz web. |
| B-08 | Sin notificaciones al pasajero (correo/SMS) al aprobar recargas. | B | El correo se captura pero no se usa. |
| B-09 | Firmas HMAC de peticiones no aplicadas en el portal. | B | Se reservan para servidor-a-servidor: la clave pública vive en el navegador (ver BLINK-DOC-05 §4). |
| B-10 | Sin verificación automatizada de TLS 1.3 en las publicaciones. | M | GitHub Pages no permite fijar la versión; revisar trimestralmente con `openssl s_client`. |
| B-11 | Argon2id no disponible en el `pgcrypto` de Supabase. | B | Se usa bcrypt costo 10 con bloqueo por intentos; revisar si el proveedor habilita Argon2. |
| B-12 | Reclamo solo por serial: sin código de activación por tarjeta. | M | Añadir un segundo factor impreso o activación asistida en taquilla para lotes grandes (SEC-06). |
| B-13 | El back-office no tiene recuperación de TOTP ni gestión de operadores en la interfaz. | B | Alta y reinicio de operadores por SQL; evaluar pantalla de cuentas para rol `ADMIN`. |
| B-14 | La estación web no graba el chip: solo registra UID↔serial; la escritura del bloque de identidad y de las llaves se hace por la consola serie (`ENROLAR`). | A | Impide operar la distribución pre-enrolada solo con el back-office (BLINK-DOC-12 §10). |
| B-15 | Sin cola secuencial, *tap & next* ni punto de control anti-desfase en la estación. | M | El enrolado de 1000 tarjetas obliga a tipear o escanear cada serial; riesgo de desfase de pila. |
| B-16 | Sin carga de artes ni paquete de producción (ZIP VDP y PDF/VT): hoy el generador entrega CSV y hoja A4. | M | La imprenta recibe el material por fuera del sistema y el CSV no trae `orden_impresion`, `lote_id` ni `patrocinante`. |
| B-17 | La estación no está reservada al propietario: `bt_admin_sesion_mfa` admite ADMIN y TAQUILLA. | M | Contradice la exclusividad de la estación que exige BLINK-DOC-12 §1. |
| B-18 | Panel de fiscales inexistente: la telemetría y la liquidación solo se consultan por SQL. | M | Próximo hito; aún sin repositorio. |
| B-19 | La simulación no corre en CI: se ejecuta a mano en el equipo de desarrollo. | M | Ver D-10; bloquea detectar regresiones del contrato en cada push. |
| B-20 | `settings.publico` conserva el Pago Móvil de ejemplo (RIF `J-00000000-0`, teléfono `0414-0000000`, titular «BLINK PASAJES, C.A.»). | A | Un pasajero real vería datos bancarios falsos. El dueño debe cargar el RIF, teléfono y titular definitivos (BLINK-DOC-15 §6). |
| B-21 | No hay caducidad de recargas pendientes ni trabajo programado; `pg_cron` no está instalado. | M | Una recarga sin revisar queda pendiente indefinidamente. Aplicar la política de rechazo por antigüedad (BLINK-DOC-15 §9, F-04). |

## 3. Deuda técnica

| ID | Deuda | Consecuencia | Prioridad |
| --- | --- | --- | --- |
| D-01 | Dos implementaciones del mismo contrato (`local.ts` y `nube.ts`). | Un cambio debe replicarse en ambas. | Alta |
| D-02 | Funciones legadas (`bt_activar`, `bt_tarjeta`, `card_sessions`). | Superficie de ataque y confusión. | Media |
| D-03 | Firmware del **lector** fuera de git (`~/Arduino`). El validador ya tiene repositorio propio en `~/BLINK/firmware/validador`. | Se pierde el lector si falla el equipo. | Alta |
| D-04 | Sin E2E en CI. | Regresiones detectadas tarde. | Media |
| D-05 | Sin alertas de recargas pendientes ni validadores caídos. | Operación a ciegas. | Media |
| D-06 | Pruebas de integración se hacen contra producción con rollback. | Riesgo de dejar datos si falla a mitad. | Media |
| D-07 | Prettier no corre en CI (el CSS actual no está formateado). | Ruido en diffs. | Baja |
| D-08 | `VITE_SUPABASE_ANON_KEY` guarda una clave publishable (nombre heredado). | Confusión al rotar. | Baja |
| D-09 | La copia sin conexión no se cifra con WebCrypto ni se ata al PIN. | Un XSS o un teléfono desbloqueado puede leer los datos mientras la copia viva (12 h). | Media |
| D-10 | La simulación local no está integrada al CI y depende de `docker-compose` v1. | El contrato RPC se prueba a mano; un cambio puede llegar a `main` sin pasar por el flujo completo. | Media |
| D-11 | La aprobación de recargas no verifica que exista su movimiento y la sincronización de toques no usa `ON CONFLICT`. | Una recarga podría acreditarse sin historial y dos sincronizaciones simultáneas podrían abortar el lote (BLINK-DOC-15 §9, F-01/F-02). | Media |

## 4. Limitaciones conocidas de la plataforma

| ID | Limitación | Efecto |
| --- | --- | --- |
| L-01 | Web Serial solo existe en Chromium de escritorio. | El lector no funciona en móvil ni en Safari/Firefox. |
| L-02 | El host directo de Supabase es IPv6. | Hay que usar el pooler desde redes IPv4. |
| L-03 | GitHub Pages no permite cabeceras personalizadas. | No se pueden añadir CSP/HSTS propios en TARJETA/BACKOFFICE ni en la redirección. |
| L-04 | Pages sirve con base `/TARJETA/`; mover a subdominio exige compilar en la raíz. | Cambio de `base` y de `vite.config.ts` si se decide `tarjeta.blink.com.ve`. |
| L-05 | La tarjeta maestra se crea por consola (`bt_crear_tarjeta_maestra`), no desde el back-office. | Crear el plástico del propietario exige acceso a SQL. |
| L-06 | La redirección de `pasajes.blink.com.ve` es HTML (`meta refresh` + JS), no un 301 del servidor. | GitHub Pages no permite reglas de servidor; sin JS igual redirige por el `meta`, pero no hay control de cabeceras ni de caché. |

## 5. Plan de mitigación inmediato

| # | Acción | Responsable | Plazo |
| --- | --- | --- | --- |
| 1 | ~~Aplicar `0006` en producción~~ (hecho el 2026-10-29; ver BLINK-DOC-07 §3.2). | Administrador | Cerrado |
| 1b | ~~Aplicar `0007` y `0008`; publicar el back-office~~ (hecho el 2026-10-29; ver BLINK-DOC-07 §3.3, §3.4 y §4.2). | Administrador | Cerrado |
| 1c | Inscribir el segundo factor de la cuenta administradora desde el teléfono del operador. | Operador | Inmediato |
| 1d | ~~Aplicar `0009` y crear la tarjeta maestra~~ (hecho el 2026-10-30; ver BLINK-DOC-07 §3.5 y BLINK-DOC-12). | Administrador | Cerrado |
| 1e | ~~Aplicar `0010` y renumerar la maestra a `00-0-0000000-0`~~ (hecho el 2026-10-30; ver BLINK-DOC-07 §3.6). | Administrador | Cerrado |
| 2 | Rotar contraseña de PostgreSQL y tokens expuestos (checklist en BLINK-DOC-11). | Administrador | Inmediato |
| 3 | Mover el firmware del **lector** a un repositorio con `firmware/` (el validador ya está en git). | Desarrollo | Corto |
| 4 | ~~Migrar BLINK PASAJES al esquema `bt_*`~~ (cerrado el 2026-10-31: panel retirado y dominio redirigido a TARJETA). | Desarrollo | Cerrado |
| 4b | Construir el panel de fiscales sobre `trips_telemetry` y `bt_liquidar`. | Producto | Próximo hito |
| 5 | Añadir E2E de registro/recarga en CI. | Desarrollo | Medio |
| 6 | Implementar recuperación de PIN. | Producto | Medio |
| 7 | Añadir alertas de pendientes y validadores. | Operación | Medio |
| 8 | Grabar el chip desde la estación web (B-14) y añadir cola secuencial con *tap & next* (B-15). | Desarrollo | Corto |
| 9 | Generar el paquete de producción ZIP VDP / PDF-VT y permitir la carga de artes (B-16). | Desarrollo | Medio |
| 10 | Restringir la estación al rol del propietario (B-17). | Desarrollo | Corto |
| 11 | Cifrar la copia sin conexión con WebCrypto y el PIN del pasajero (R-10, D-09). | Desarrollo | Medio |
| 12 | Llevar `simulacion/flujo.sh` al CI (B-19, D-10). | Desarrollo | Corto |
| 13 | Aplicar las guardas F-01 y F-02 del ciclo de recarga (D-11) y definir la caducidad de pendientes (B-21). | Desarrollo | Corto |
| 14 | Cargar el Pago Móvil real en `settings.publico` (B-20). | Propietario | Inmediato |

## 6. Revisión

Este registro se actualiza al cerrar cada hito. La última revisión corresponde al
2026-10-31, con la auditoría de datos y el cierre del ciclo de recarga
(BLINK-DOC-15): se cerró la prueba física de enrolado y cobro, se purgó la
unidad demo, se añadieron B-20 (Pago Móvil de ejemplo), B-21 (pendientes sin
caducidad) y D-11 (guardas del ciclo), y se acotó D-03 al firmware del lector.
La revisión anterior, del 2026-10-31, acompañó el retiro de BLINK PASAJES (B-03
cerrada, L-03 acotada a TARJETA/BACKOFFICE), la redirección del dominio (L-06)
y la simulación local del flujo completo (B-19, D-10). La revisión del
2026-10-31 anterior acompañó la seguridad del portal sin conexión: se añadieron
R-10, R-11 y D-09, y se endurecieron la caducidad de la copia local y el alcance
del service worker. La revisión del 2026-10-30 acompañó las migraciones `0009`
(serie de 7 dígitos) y `0010` (maestra `00-0-0000000-0`) y la alineación de
BLINK-DOC-12 con el estándar de producción del propietario (impresión ID-1,
paquete VDP y enrolado secuencial).
