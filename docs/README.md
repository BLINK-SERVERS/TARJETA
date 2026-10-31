# Documentación del ecosistema BLINK — índice y control documental

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-00 |
| Versión | 1.5.0 |
| Fecha | 2026-10-30 |
| Estado | Vigente |
| Autor | Equipo BLINK (desarrollo asistido) |
| Revisión | 3 |
| Normas de referencia | ISO 9001:2015 §7.5 · ISO/IEC/IEEE 12207:2017 · ISO/IEC/IEEE 26511/26512/26513/26514/26515 · ISO/IEC 25010 · ISO/IEC 27001:2022 |

## 1. Propósito

Esta carpeta reúne la documentación técnica y operativa del ecosistema **BLINK**,
formado por tres aplicaciones web y un backend compartido. Su objetivo es que
cualquier persona pueda **retomar el desarrollo, operar el sistema y auditar sus
decisiones** sin depender del contexto de quien lo construyó.

La suite sigue, en lo aplicable a un proyecto pequeño, las prácticas de control
documental de ISO 9001 (§7.5), el ciclo de vida de ISO/IEC/IEEE 12207 y las
normas de documentación de software ISO/IEC/IEEE 26511 a 26515.

## 2. Alcance

| Producto | Repositorio | URL pública | Versión |
| --- | --- | --- | --- |
| BLINK POS (sitio de la línea y punto de venta) | `BLINK-SERVERS/POS` | https://www.blink.com.ve | 1.19.0 |
| BLINK PASAJES (lector, fiscal, admin) | `BLINK-SERVERS/PASAJES` | https://pasajes.blink.com.ve | 0.1.0 |
| BLINK TARJETA (portal del pasajero) | `BLINK-SERVERS/TARJETA` | https://blink-servers.github.io/TARJETA/ | 1.4.0 |
| BLINK BACK-OFFICE (consola administrativa) | `BLINK-SERVERS/BACKOFFICE` | https://blink-servers.github.io/BACKOFFICE/ | 1.0.0 |
| Backend (Supabase) | proyecto `gakkfzqcrapxeierfdhk` | — | PostgreSQL 17.11 |

> **Base de datos compartida.** Las cuatro aplicaciones apuntan al **mismo proyecto
> de Supabase** (TARJETA y BACKOFFICE usan además el mismo esquema `bt_*`).
> BLINK POS usa Supabase Auth y las tablas `businesses` y `catalogo_global`;
> BLINK PASAJES opera hoy en modo local con Web Serial y es la siguiente en migrar
> al esquema `bt_*`. Cualquier cambio de esquema debe evaluarse contra todas.

## 3. Documentos

| Código | Documento | Norma principal |
| --- | --- | --- |
| BLINK-DOC-01 | [Alcance y partes interesadas](01-alcance-y-partes-interesadas.md) | 12207 |
| BLINK-DOC-02 | [Arquitectura del ecosistema](02-arquitectura.md) | 26514 |
| BLINK-DOC-03 | [Modelo de datos](03-modelo-de-datos.md) | 26514 |
| BLINK-DOC-04 | [API de funciones RPC](04-api-rpc.md) | 26514 |
| BLINK-DOC-05 | [Seguridad de la información](05-seguridad.md) | 27001 |
| BLINK-DOC-06 | [Operación y despliegue](06-operacion-y-despliegue.md) | 12207 |
| BLINK-DOC-07 | [Pruebas y calidad](07-pruebas-y-calidad.md) | 26513 · 25010 |
| BLINK-DOC-08 | [Manual de usuario](08-manual-de-usuario.md) | 26511 · 26512 |
| BLINK-DOC-09 | [Riesgos, brechas y deuda técnica](09-riesgos-y-brechas.md) | 12207 · 27001 |
| BLINK-DOC-10 | [Guía para retomar el desarrollo](10-guia-de-retoma.md) | 26515 |
| BLINK-DOC-11 | [Rotación de claves y secretos](11-rotacion-de-claves.md) | 27001 |
| BLINK-DOC-12 | [Enrolado y producción de lotes de tarjetas](12-enrolado-de-lotes.md) | 7810 · 7812-1 · 15417 · PDF/VT |
| BLINK-DOC-13 | [Seguridad bancaria y operación offline](13-seguridad-bancaria-offline.md) | 7812-1 · 7064 · 14443 · GlobalPlatform |
| BLINK-DOC-14 | [Estándares industriales y control de calidad](14-estandares-industriales.md) | 14443 · 7810 · 10373 |
| — | [CHANGELOG](../CHANGELOG.md) | Keep a Changelog 1.1.0 + SemVer |

## 4. Convenciones de esta suite

- **Idioma:** español (es-VE), con identificadores de código en inglés cuando ya
  existen en la base (`cards`, `accounts`) y en español cuando son nuevos.
- **Fechas:** ISO 8601 (`AAAA-MM-DD`) en documentos y `AAAA-MM-DD HH:MM` en logs.
- **Versiones:** SemVer 2.0.0. Un cambio incompatible en RPC o esquema obliga a
  subir la versión mayor del producto afectado y a registrar la migración.
- **Referencias cruzadas:** rutas relativas dentro de esta carpeta; enlaces
  absolutos solo a recursos externos estables.
- **Secretos:** ningún documento contiene claves, tokens ni contraseñas. Se indica
  **dónde** vive cada secreto y **quién** debe rotarlo (ver BLINK-DOC-05).

## 5. Control de cambios documental

| Versión | Fecha | Cambio | Autor |
| --- | --- | --- | --- |
| 1.0.0 | 2026-10-29 | Creación de la suite completa tras el despliegue de la cuenta multi-tarjeta. | Equipo BLINK |
| 1.1.0 | 2026-10-29 | Aprovisionamiento en lote (FABRICADA), estación de asignación, bitácora y purga archivada. | Equipo BLINK |
| 1.1.1 | 2026-10-29 | 0006 aplicada en producción; DOC-03/06/07/09 pasan a 1.1.1 con el estado verificado. | Equipo BLINK |
| 1.2.0 | 2026-10-29 | Back-office separado (repo `BACKOFFICE`) con RBAC y TOTP; migraciones 0007 y 0008 aplicadas; suite pasa a 1.2.0. | Equipo BLINK |
| 1.3.0 | 2026-10-30 | Nuevo BLINK-DOC-11: checklist de rotación de claves, inventario de secretos y verificación. | Equipo BLINK |
| 1.4.0 | 2026-10-30 | Nuevo BLINK-DOC-12: enrolado de lotes y tarjeta maestra; serie de 7 dígitos (`23-1-0000001-9`) con migración 0009. | Equipo BLINK |
| 1.5.0 | 2026-10-30 | BLINK-DOC-12 pasa a 2.0.0 con el estándar de producción del propietario; migración 0010 y serial maestro `00-0-0000000-0`. | Equipo BLINK |

Reglas de mantenimiento:

1. Todo cambio de esquema o de contrato RPC actualiza BLINK-DOC-03 y BLINK-DOC-04
   **en el mismo commit** que la migración.
2. Todo cambio visible para el usuario añade una entrada en `CHANGELOG.md`.
3. La revisión completa de la suite se hace al cerrar cada hito y, como mínimo,
   una vez por trimestre.

## 6. Glosario

| Término | Definición |
| --- | --- |
| **ID BLINK** | Serial visible con dígito verificador Luhn: 10 dígitos (`23-1-000001-9`) o 11 en la serie nueva (`23-1-0000001-9`). |
| **Cuenta** | Identidad del pasajero (cédula, PIN, Pago Móvil) que puede tener N tarjetas. |
| **Billetera** | Conjunto de tarjetas activas de una cuenta. |
| **Validador** | Dispositivo ESP32 + RC522 que cobra el pasaje y sincroniza con la nube. |
| **Lector** | Modo de BLINK PASAJES que lee el UID del chip por Web Serial. |
| **RPC** | Función PostgreSQL expuesta por PostgREST (`POST /rest/v1/rpc/<nombre>`). |
| **RLS** | Row Level Security: política de filas de PostgreSQL. |
| **Pago Móvil** | Transferencia bancaria venezolana que el pasajero reporta y un admin aprueba. |
| **Back-office** | Consola administrativa separada del portal; exige rol `ADMIN`/`TAQUILLA` y TOTP. |
| **TOTP** | Código de 6 dígitos cada 30 s (RFC 6238); BLINK lo verifica en la base, no en el navegador. |
