# Pruebas y calidad

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-07 |
| Versión | 1.1.0 |
| Fecha | 2026-10-29 |
| Estado | Vigente |
| Normas | ISO/IEC/IEEE 26513 · ISO/IEC 25010 |

## 1. Estrategia

| Nivel | Herramienta | Alcance |
| --- | --- | --- |
| Unidad | Vitest | Reglas de dominio, formato, PIN, carga del lote, repositorio local. |
| Integración de datos | PostgreSQL 16 en contenedor + `psql` | Migraciones y RPC de punta a punta con `SET LOCAL ROLE anon`. |
| Integración real | Supabase de producción dentro de una transacción con `ROLLBACK` | Contrato RPC real, permisos y RLS. |
| Sistema (UI) | Navegador Chromium contra el sitio publicado | Registro, vínculo, recarga, perfil. |
| Regresión visual | Medición de `aspect-ratio` y radio en 371/320/280 px | Tarjeta virtual ID-1. |

No hay todavía pruebas E2E automatizadas en CI (Playwright existe solo en POS);
es una brecha declarada (BLINK-DOC-09 R-05).

## 2. Suites automatizadas

| Repo | Comando | Resultado 2026-10-29 |
| --- | --- | --- |
| TARJETA | `npm test` | **60 pruebas, 4 archivos, todas en verde** |
| TARJETA | `npm run typecheck` | Sin errores |
| PASAJES | `npm test` | **56 pruebas, 4 archivos, todas en verde** |
| POS | `npm test` / `npm run qa` | Suite propia; requiere Chromium instalado |

Cobertura funcional de TARJETA por archivo:

| Archivo | Qué prueba |
| --- | --- |
| `src/lib/dominio.test.ts` | Cédulas, teléfonos, correos, montos, seriales. |
| `src/lib/formato.test.ts` | Máscaras de cédula/teléfono, moneda, fechas. |
| `src/lib/local.test.ts` | Registro, entrada, vínculo, recarga y extracto en modo local. |
| `src/lib/lote.test.ts` | Generación de lotes con Luhn y Code 128. |

## 3. Pruebas de base de datos (2026-10-29)

Ejecutadas contra PostgreSQL 16 local y repetidas contra producción con
`SET LOCAL ROLE anon` y `ROLLBACK` final (sin dejar datos):

| # | Caso | Resultado |
| --- | --- | --- |
| 1 | Registro con pago propio devuelve token | OK |
| 2 | Billetera recién creada sin tarjetas | OK (0) |
| 3 | Vincular tarjeta activa y sin dueño | OK (1 tarjeta, titular = cuenta) |
| 4 | Extracto de la tarjeta vinculada | OK |
| 5 | Reportar recarga válida | OK (`pendiente`) |
| 6 | Cambiar PIN con el actual correcto | OK |
| 7 | Entrar con el PIN nuevo | OK |
| 8 | Actualizar fuente de pago (familiar) | OK (`Mercantil`) |
| 9 | Vincular la misma tarjeta otra vez | `bt:duplicada` |
| 10 | PIN incorrecto | `{error:"credenciales"}` |
| 11 | Movimientos de una tarjeta ajena | `bt:sin-tarjeta` |
| 12 | Vincular tarjeta bloqueada | `bt:bloqueada` |
| 13 | Cerrar sesión | OK |
| 14 | Usar el token cerrado | `bt:sesion` |

Además se probó en local: PIN triviales rechazados, cédula y correo duplicados,
bloqueo a los 5 fallos, tarjeta vencida, serial con Luhn inválido, tope de recarga,
referencia duplicada y ráfaga de reportes.

### 3.1 Migración 0006 (aprovisionamiento en lote)

Ejecutada sobre una base nueva (`prueba6`, PostgreSQL 16) con `0001`→`0005` y
`0006`, dos veces seguidas para comprobar idempotencia:

| # | Caso | Resultado |
| --- | --- | --- |
| 1 | Purga con archivo previo en `respaldo` | OK (3 tarjetas, 2 recargas) |
| 2 | Segunda ejecución no vuelve a purgar | OK (`bitacora`) |
| 3 | Lote de arranque de 20 tarjetas en `FABRICADA` | OK |
| 4 | Login administrador (cédula + PIN) y billetera vacía | OK, `rol = ADMIN` |
| 5 | Reclamo de `23-1-000001-9` | OK: `ACTIVE`, `asignada_por = portal` |
| 6 | Reclamo repetido | `bt:duplicada` |
| 7 | Enrolar 2 pares con un UID inválido | 1 enrolada, 1 rechazada |
| 8 | UID repetido en otra tarjeta | rechazado |
| 9 | Catálogo del lote | 20 tarjetas |
| 10 | Asignación en taquilla a otra cuenta | OK |
| 11 | Reclamo de tarjeta ajena | `bt:ya-activada` |
| 12 | Resumen operativo | `fabricadas=18`, `asignadas=2` |
| 13 | Pérdida de tarjeta sin dueño | rechazada |
| 14 | Bitácora `card_events` | 3 eventos (asignación portal, enrolamiento, taquilla) |

Permisos verificados con `has_function_privilege`: `anon` solo ejecuta
`bt_entrar`/`bt_vincular`; las funciones de estación, lote y resumen quedan
únicamente en `service_role`.

El caso queda reproducible en `supabase/pruebas/0006_lotes.sql`:

```bash
psql "$CADENA" -v ON_ERROR_STOP=1 -f supabase/pruebas/0006_lotes.sql
```

La prueba corre en una transacción que termina en `ROLLBACK`; el PIN se toma de
`blink.admin_pin` en la sesión.

La aplicación en producción queda pendiente porque la sesión del panel de
Supabase expiró y la contraseña de PostgreSQL no está en el repositorio ni en el
gestor local.

## 4. Prueba de sistema en producción (2026-10-29)

Entorno: `https://blink-servers.github.io/TARJETA/`, Chromium, datos reales de
Supabase. Cuenta de prueba creada y eliminada al terminar; datos restaurados.

| Paso | Resultado |
| --- | --- |
| Carga del portal en modo nube (sin aviso de demostración) | OK |
| Registro en dos pasos con Pago Móvil propio | OK |
| Billetera vacía con llamado a vincular | OK |
| Vínculo de `23-1-000002-7` | OK; titular mostrado = cuenta |
| Tarjeta virtual con saldo, tarifa, serial y Code 128 | OK |
| Recarga de Bs 100 con banco y referencia | OK; comprobante en revisión |
| Movimiento visible en el inicio | OK |
| Perfil: datos, fuente de pago, tarjeta, apariencia, seguridad | OK |
| Enlaces a PASAJES y blink.com.ve | OK (PASAJES apunta a `pasajes.blink.com.ve`) |
| Limpieza de datos de prueba | OK; `accounts` volvió a 0 y la tarjeta a `account_id = null` |

## 5. Prueba de la tarjeta virtual (ID-1 / CR80)

| Viewport | Ancho de tarjeta | Alto | Relación medida | Radio |
| --- | --- | --- | --- | --- |
| 371 px | 341 px | 215 px | 1,586 | 12,6 px |
| 320 px | 290 px | 183 px | 1,585 | 12 px (mínimo) |
| 280 px | 250 px | 158 px | 1,582 | 12 px (mínimo) |

Criterio: proporción 1,586:1 ±1 %, radio `clamp(12px, 3.7cqw, 16px)`, sin
solapamiento de contenido. **Cumplido** tras sustituir `min-height` por
`aspect-ratio` y escalar el interior con unidades `cqw`.

## 6. Criterios de aceptación del hito

| Criterio | Estado |
| --- | --- |
| Registro, vínculo y recarga contra la base real | Cumplido |
| Migración 0005 aplicada sin errores | Cumplido |
| Despliegue automático en verde | Cumplido |
| Proporción y radio de la tarjeta | Cumplido |
| Pruebas unitarias en verde | Cumplido |
| Enrolado y cobro con tarjeta física | **Pendiente** (requiere lector y plástico) |

## 7. Calidad según ISO/IEC 25010

| Característica | Cómo se atiende |
| --- | --- |
| Adecuación funcional | RPC con reglas de negocio en la base; 14 casos verificados. |
| Eficiencia | Índices por cédula, correo, tarjeta, sesión y pendientes; consultas limitadas. |
| Compatibilidad | Chromium/Edge/Firefox modernos; Web Serial solo Chromium escritorio. |
| Usabilidad | Flujo guiado por pasos, mensajes en español, modo claro/oscuro, tarjeta legible. |
| Fiabilidad | Transacciones, `on delete` explícito, bloqueo por intentos, modo local de respaldo. |
| Seguridad | Ver BLINK-DOC-05. |
| Mantenibilidad | TypeScript estricto, capas separadas, migraciones versionadas, esta suite. |
| Portabilidad | Build estático en GitHub Pages; sin dependencia de servidor propio. |

## 8. Deuda de pruebas

1. Automatizar el flujo de §4 con Playwright contra un proyecto de pruebas.
2. Añadir pruebas de RPC al CI con una base efímera (Docker + PostgreSQL 16).
3. Probar el validador con tarjeta física y modo offline (tarea #28).
4. Añadir prueba de regresión visual de la tarjeta en varios viewports.
