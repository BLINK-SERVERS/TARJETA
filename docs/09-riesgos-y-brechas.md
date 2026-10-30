# Registro de riesgos, brechas y deuda técnica

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-09 |
| Versión | 1.1.0 |
| Fecha | 2026-10-29 |
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
| R-07 | PIN de 6 dígitos de baja entropía protege la cuenta `ADMIN`. | M | A | Cambiar el PIN de arranque, no reutilizarlo en otros sistemas y exigir MFA en el back-office. | **Abierto** |

## 2. Brechas funcionales frente al diseño técnico

La fuente de verdad es `Documentación Técnica del Ecosistema Blink Pasajes`
(2026-10-29). Estado de implementación:

| ID | Brecha | Impacto | Notas |
| --- | --- | --- | --- |
| B-01 | Mapa de memoria MIFARE por sectores y claves diversificadas `HMAC_SHA256(master, UID)` no implementado en la nube. | M | El firmware y el esquema actual usan UID + saldo virtual; falta la escritura segura del plástico. |
| B-02 | Lista negra offline en el validador: descarga implementada, prueba física pendiente. | M | Depende de la tarea #28. |
| B-03 | BLINK PASAJES opera en local, sin RPC `bt_*`. | A | Migración planificada; hoy el admin usa datos del navegador. |
| B-04 | Aprobación de recargas sin interfaz: solo RPC de servicio. | M | El admin de PASAJES debería consumir `bt_recargas_pendientes`/`bt_aprobar_recarga`. |
| B-05 | Recuperación de PIN inexistente en el portal. | M | Requiere flujo de atención o verificación por correo. |
| B-06 | Telemetría fiscal sin exportación oficial (GTFS/CSV). | B | El módulo Fiscal muestra totales, no descarga. |
| B-07 | Estación de enrolado: la carga masiva UID↔serial existe en `0006`, falta el circuito físico completo con la placa. | M | `bt_estacion_enrolar` + `bt_estacion_catalogo` cubren el alta; la prueba con lector depende de la tarea #28. |
| B-08 | Sin notificaciones al pasajero (correo/SMS) al aprobar recargas. | B | El correo se captura pero no se usa. |
| B-09 | Firmas HMAC de peticiones no aplicadas en el portal. | B | Se reservan para servidor-a-servidor: la clave pública vive en el navegador (ver BLINK-DOC-05 §4). |
| B-10 | Sin verificación automatizada de TLS 1.3 en las publicaciones. | M | GitHub Pages no permite fijar la versión; revisar trimestralmente con `openssl s_client`. |
| B-11 | Argon2id no disponible en el `pgcrypto` de Supabase. | B | Se usa bcrypt costo 10 con bloqueo por intentos; revisar si el proveedor habilita Argon2. |
| B-12 | Reclamo solo por serial: sin código de activación por tarjeta. | M | Añadir un segundo factor impreso o activación asistida en taquilla para lotes grandes (SEC-06). |

## 3. Deuda técnica

| ID | Deuda | Consecuencia | Prioridad |
| --- | --- | --- | --- |
| D-01 | Dos implementaciones del mismo contrato (`local.ts` y `nube.ts`). | Un cambio debe replicarse en ambas. | Alta |
| D-02 | Funciones legadas (`bt_activar`, `bt_tarjeta`, `card_sessions`). | Superficie de ataque y confusión. | Media |
| D-03 | Firmware fuera de git (`~/Arduino`). | Se pierde si falla el equipo. | Alta |
| D-04 | Sin E2E en CI. | Regresiones detectadas tarde. | Media |
| D-05 | Sin alertas de recargas pendientes ni validadores caídos. | Operación a ciegas. | Media |
| D-06 | Pruebas de integración se hacen contra producción con rollback. | Riesgo de dejar datos si falla a mitad. | Media |
| D-07 | Prettier no corre en CI (el CSS actual no está formateado). | Ruido en diffs. | Baja |
| D-08 | `VITE_SUPABASE_ANON_KEY` guarda una clave publishable (nombre heredado). | Confusión al rotar. | Baja |

## 4. Limitaciones conocidas de la plataforma

| ID | Limitación | Efecto |
| --- | --- | --- |
| L-01 | Web Serial solo existe en Chromium de escritorio. | El lector no funciona en móvil ni en Safari/Firefox. |
| L-02 | El host directo de Supabase es IPv6. | Hay que usar el pooler desde redes IPv4. |
| L-03 | GitHub Pages no permite cabeceras personalizadas. | No se pueden añadir CSP/HSTS propios en TARJETA/PASAJES. |
| L-04 | Pages sirve con base `/TARJETA/`; mover a subdominio exige compilar en la raíz. | Cambio de `base` y de `vite.config.ts` si se decide `tarjeta.blink.com.ve`. |

## 5. Plan de mitigación inmediato

| # | Acción | Responsable | Plazo |
| --- | --- | --- | --- |
| 1 | Aplicar `0006` en producción (purga archivada + cuenta administradora). | Administrador | Inmediato |
| 2 | Rotar contraseña de PostgreSQL y tokens expuestos. | Administrador | Inmediato |
| 3 | Mover firmware a un repositorio con `firmware/`. | Desarrollo | Corto |
| 4 | Migrar BLINK PASAJES al esquema `bt_*`. | Desarrollo | Medio |
| 5 | Añadir E2E de registro/recarga en CI. | Desarrollo | Medio |
| 6 | Implementar recuperación de PIN. | Producto | Medio |
| 7 | Añadir alertas de pendientes y validadores. | Operación | Medio |

## 6. Revisión

Este registro se actualiza al cerrar cada hito. La última revisión corresponde al
2026-10-29, tras escribir y probar la migración 0006 de aprovisionamiento en lote.
