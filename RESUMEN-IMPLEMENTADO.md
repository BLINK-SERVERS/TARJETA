# BLINK — Resumen de lo implementado

| Campo | Valor |
| --- | --- |
| Fecha | 2026-10-31 |
| Alcance | Portal del pasajero, back-office, base Supabase, firmware del validador, generador de lotes y documentación |
| Último commit del portal | `203754f` (endurecimiento de la capa sin conexión) |
| Estado | Operativo en producción; quedan pendientes físicos y de rotación de claves (ver §10) |

Este documento resume **qué existe hoy** en el ecosistema BLINK, con el detalle
técnico necesario para retomarlo. No sustituye a la suite ISO de `docs/`
(BLINK-DOC-00 a 14), que sigue siendo la fuente formal; sirve como vista única
de conjunto.

---

## 1. Visión general

BLINK es un sistema de transporte con tarjeta sin contacto, compuesto por tres
aplicaciones web, un backend gestionado y un validador embebido:

| Pieza | Repositorio / ubicación | Publicación | Versión |
| --- | --- | --- | --- |
| Portal del pasajero (BLINK TARJETA) | `BLINK-SERVERS/TARJETA` · `~/BLINK_Tarjeta` | <https://blink-servers.github.io/TARJETA/> | 1.4.0 |
| Back-office corporativo | `BLINK-SERVERS/BACKOFFICE` · `~/BLINK_Backoffice` | <https://blink-servers.github.io/BACKOFFICE/> | 1.1.0 |
| Punto de venta y sitio de la línea | `BLINK-SERVERS/POS` | <https://www.blink.com.ve> | 1.19.0 |
| PASAJES (lector, fiscal, admin) | `BLINK-SERVERS/PASAJES` | <https://pasajes.blink.com.ve> | 0.1.0 |
| Backend | Supabase, proyecto `gakkfzqcrapxeierfdhk` | REST/RPC por TLS | PostgreSQL 17 |
| Validador | `~/Arduino/BLINK_Validador` (ESP32 + MFRC522 + ST7789) | Físico, en banco de pruebas | firmware v6 |
| Documentación | `~/BLINK_Tarjeta/docs/` | — | suite 1.5.1 |

Regla transversal: **los navegadores nunca reciben la clave `service_role`**.
Las operaciones sensibles viven en funciones `security definer` de Postgres y se
invocan por RPC con la llave publishable.

---

## 2. Portal del pasajero (BLINK TARJETA)

Aplicación React 19 + TypeScript + Vite, con estética BLINK y dos backends tras
`src/lib/repo.ts`.

### 2.1 Funcionalidad

- **Acceso** por cédula (V/E) y PIN de 6 dígitos; registro en dos etapas con
  datos de Pago Móvil propios o de un familiar.
- **Billetera multi-tarjeta**: una cuenta con N plásticos vinculados por serial.
- **Tarjeta virtual 3D** con cuatro zonas, giro y reverso; muestra saldo, tipo,
  estado, vencimiento y el serial formateado.
- **Recarga por Pago Móvil** en tres pasos (monto → datos de la fuente de pago →
  reporte con referencia y comprobante), con validación de campos y duplicados.
- **Movimientos** por tarjeta, del más nuevo al más viejo.
- **Perfil**: datos de la cuenta, cambio de PIN, fuente de pago, tema claro/oscuro
  y enlaces a PASAJES y al sitio.
- **Vínculo de tarjeta** por serial tras el reclamo; exige que el chip esté
  enrolado (`0013`) para no activar plásticos ilegibles.
- **Modo demostración**: sin variables de Supabase la app arranca en local con
  tarjetas demo (PIN `194628`), útil para revisar la interfaz sin backend.
- **Montos enteros en bolívares**, sin céntimos, en portal, back-office y
  firmware.

### 2.2 Uso en el celular y sin conexión (PWA)

- `public/sw.js` precarga el armazón (HTML, manifest, iconos) y, en la primera
  visita, los recursos con hash (`main.tsx` le manda las URLs ya cargadas).
- Navegación *red primero* con respaldo en caché; estáticos *caché primero*.
- Instalable: Android/Chrome «Instalar aplicación», iOS/Safari «Añadir a
  pantalla de inicio».
- Sin red se abre la tarjeta con el **último saldo sincronizado** y la leyenda
  «Saldo guardado en este teléfono · sin conexión».
- Recargar, vincular, cambiar PIN o datos de pago siguen exigiendo internet.
- La copia local (`blink.tarjeta.offline.v1`) **caduca a las 12 h** de la última
  sincronización y se borra al salir, al expirar la sesión o si el servidor la
  rechaza.

### 2.3 Endurecimiento de seguridad (2026-10-31)

Aplicado en el commit `203754f`, tras revisar la superficie de la capa offline:

| Antes | Ahora |
| --- | --- |
| Copia local con datos personales y token sin caducidad | `src/lib/offline.ts`: TTL de 12 h, rechazo de fechas futuras (>5 min), descarte de formato viejo y borrado en salida/expiración |
| El service worker borraba **todas** las cachés del origen al actualizarse | Solo borra claves con prefijo `blink-tarjeta-` (el origen de Pages es compartido) |
| Aceptaba cualquier URL del mismo origen en `postMessage` | Valida `evento.origin`, el ámbito `/TARJETA/` y que sea un recurso estático |
| Cacheaba cualquier GET del mismo origen, incluidas API | Solo cachea estáticos del armazón; las respuestas de API nunca se guardan |
| La copia sobrevivía a la sesión local vencida | `App.tsx` la elimina cuando no hay sesión válida |

Verificado en Chromium headless contra el sitio publicado: respaldo con Supabase
bloqueado, modo avión, copia vencida descartada y una actualización del worker
que conserva cachés ajenas (`otra-app-v1`) y borra las propias antiguas.

---

## 3. Back-office (BLINK BACKOFFICE)

Consola corporativa separada del portal y del POS, sobre la misma base.

| Módulo | Función |
| --- | --- |
| **Acceso** | Cuenta con rol `ADMIN`/`TAQUILLA` y segundo factor TOTP (RFC 6238) |
| **MFA** | Inscripción del teléfono con `otpauth://` y QR generado en el navegador |
| **Resumen** | Inventario, recargas pendientes, recaudación del día y flota |
| **Lotes** | Genera N tarjetas `FABRICADA` con serial Luhn (1–999 por lote) |
| **Inventario** | Búsqueda por serial, UID, nombre o cédula; exporta CSV; registra mermas (`SCRAP`) |
| **Estación** | Web Serial + ESP32: **enrolado secuencial** («tap & next») sin teclear serial ni UID |

### 3.1 Modelo de seguridad

- La sesión del operador se valida en **cada llamada** con
  `bt_admin_sesion`/`bt_admin_sesion_mfa` (token + rol + TOTP).
- Las primitivas siguen cerradas a `anon`; solo se abren los envoltorios
  `bt_admin_*`, que reciben `p_token`.
- RLS activo y `EXECUTE` revocado por defecto en funciones nuevas de `public`.
- TOTP calculado en PL/pgSQL con `extensions.hmac(...,'sha1')`, ventana ±1.

### 3.2 Estación secuencial

1. Se conecta el lector por Web Serial.
2. Se elige el lote y se pulsa **Iniciar secuencia**.
3. La consola pide el siguiente serial a `bt_admin_siguiente`, envía
   `ENROLAR,<serial>,0,<tarifa>` al ESP32 y espera `ENROLADA,serial=…,uid=…`.
4. Registra la pareja con `bt_admin_enrolar` y arma la siguiente sola.
5. **Detener** manda `ENROLAR_OFF`.

El firmware no sobrescribe chips ya grabados (`ya-grabada`) y devuelve
`ERROR,enrolado,<motivo>` ante fallos de serial, llave, escritura o lector.

> Estado: flujo implementado y probado por serie/`pyserial`; la Web Serial no se
> puede automatizar en un navegador headless y la prueba física completa sigue
> pendiente (tarea #28).

---

## 4. Base de datos y reglas de negocio

Migraciones aplicadas o versionadas en `supabase/migrations/`:

| Migración | Aporte |
| --- | --- |
| `0001_tarjeta` | Esquema canónico: tarjetas, lotes, rutas, unidades, recargas, viajes, movimientos, sesiones, liquidaciones |
| `0002_demo` | Semilla de demostración (ya purgada en producción) |
| `0003_operacion` | Emisión con Luhn, enrolado, cobro, aprobación/rechazo de recargas, pérdida, liquidación (solo `service_role`) |
| `0004_validador_token` | Token de sincronización por unidad; el ESP32 nunca lleva la llave secreta |
| `0005_cuentas` | Cuentas, tarjetas vinculadas, sesiones y RPC del portal |
| `0006_lotes_corporativos` | Estado `FABRICADA`, activación por reclamo, estación UID↔serial, bitácora `card_events`, roles y purga archivada |
| `0007_backoffice_mfa` | TOTP, sesión de operador y envoltorios `bt_admin_*` |
| `0008_backoffice_lectura` | Lotes y tarjetas de solo lectura para el panel |
| `0009_serie_siete_digitos` | Luhn sobre serial completo y primer formato de 7 dígitos |
| `0010_maestra_once_digitos` | Maestra `00-0-0000000-0` (luego reemplazada por la serie 5+3) |
| `0011_estacion_secuencial` | `bt_admin_siguiente`: entrega la siguiente `FABRICADA` sin UID |
| `0012_asignar_exige_enrolada` | No se asigna un plástico sin `chip_uid` |
| `0013_portal_exige_enrolada` | El portal tampoco activa tarjetas sin chip enrolado |
| `0014_serie_cinco_mas_tres` | Serie `T-LLLLL-UUU-V`, tarjeta Alfa, `SCRAP`, eventos `RFPGC`/`CHIP_ERR`, bolívares enteros |
| `0015_lotes_con_mermas` | Conteos exactos de desechadas y sin enrolar |
| `0016_corrige_alfabeto_verificador` | Corrige el alfabeto del verificador (incluye la `U`) |

### 4.1 Identificadores

- **Serie 5+3**: `G-00001-001-N`; letra de tarifa (`A` maestra, `E` estudiante,
  `G` general), 5 dígitos de lote, 3 de secuencia y letra verificadora **Luhn
  mod 23** del alfabeto `ABCDEFGHJKLMNPRSTUVWXYZ`.
- **Serial compacto** (10 caracteres, `G00001001N`) impreso como Code 128 en el
  reverso y escrito en el chip.
- **Tarjeta Alfa** del propietario: `A-00000-000-H`, creada con
  `bt_crear_tarjeta_alfa`, activa y asignada a `V-34201580`.
- **Estados**: `FABRICADA` → `ACTIVA` (por reclamo) / `BLOQUEADA` /
  `PERDIDA` / `SCRAP`.
- **Tarifas**: 0 maestra, 1 general (Bs 500), 2 estudiante (Bs 250).

### 4.2 Seguridad de la base

- `EXECUTE` revocado de `public, anon, authenticated` en las funciones internas;
  solo las RPC del portal y los envoltorios `bt_admin_*` quedan abiertos.
- Fallos de PIN vuelven como `{error, mensaje}` con HTTP 200 para que el
  contador de intentos y el bloqueo se confirmen (una excepción los revertiría).
- Bitácora `card_events` con RLS y respaldo de la purga en `respaldo.*`.

---

## 5. Firmware del validador (v6)

ESP32 con MFRC522 (13,56 MHz) y pantalla ST7789 de 1,54" 240×240.

### 5.1 Hardware

| Señal | GPIO |
| --- | --- |
| SPI SCK / MOSI | 18 / 23 (compartido pantalla y lector) |
| Lector CS / RST | 5 / 4 |
| Pantalla CS / DC / RST | 25 / 27 / 4 (RST compartido con el lector) |
| Buzzer | 13 |
| GPS | UART2 |

La pantalla se inicializa **antes** de `PCD_Init()` porque su reset comparte D4
con el del RC522; en marcha D4 queda en HIGH (estado activo del lector).

### 5.2 Tarjeta

- **Sector 1, bloque 4**: identidad v3 (serial compacto, longitud, tarifa,
  estado, versión y CRC-8); se siguen leyendo bloques v1/v2.
- **Sector 2, bloques 8–10**: saldo y contador como **bloques de valor nativos**
  de MIFARE, más CRC de integridad.
- **Sector 3, bloque 12**: buzón de viaje.
- **Llaves diversificadas** `HMAC-SHA256(MASTER_KEY, etiqueta || UID)` por
  sector; al enrolar se escriben los trailers con esas llaves.
- Cobro offline atómico (decremento + contador) y recarga (incremento); rechazo
  local con LED/buzzer y motivo.

> Pendiente: la `MASTER_KEY` del `config.h` sigue siendo de demostración y debe
> reemplazarse antes de producir lotes.

### 5.3 Red y sincronización

- Wi-Fi por NVS (`WIFI,ssid,clave`), NTP y POST HTTPS con CA integrada +
  ArduinoJson 7.
- Sincroniza al arrancar, cada minuto si hay cola y cada 5 sin ella; `DUMP/ACK`
  por serie como respaldo.
- Token de unidad emitido por `bt_validador_emitir_token` (se muestra una vez) y
  validado por `bt_validador_sincronizar_token`.
- Colas NVS de pendientes, bloqueadas y log; lista negra y recargas pendientes.
- GPS y sincronización visibles en pantalla.

### 5.4 Pantalla

Franjas con cabecera «BLINK», placa, Wi-Fi/IP/token/sync, versión, **datos de la
tarjeta** (tipo, estado, serial, saldo, UID), resultado del toque, cola local y
GPS. En modo enrolado pinta «MODO ENROLADO», serial y cuenta atrás de 60 s. Las
franjas se redibujan solo cuando cambian.

### 5.5 Protocolo serie (resumen)

`PING`, `INFO`, `RED`, `WIFI`, `OLVIDAR_WIFI`, `TOKEN`, `VEHICULO`, `TARIFA`,
`DUMP`, `ACK`, `LIMPIAR_RECARGAS`, `LIMPIAR_BLOQUEADAS`, `BORRAR_LOG`,
`ENROLAR` (con `FORZAR`), `ENROLAR_OFF`; eventos `READY`, `TAP`, `TARJETA`,
`ENROLADA`, `ENROLAR_TIMEUP`, `SYNC`, `PONG`, `ERROR`.

---

## 6. Generación de lotes e impresión

`npm run lote` (en el portal) produce:

- Seriales con verificador Luhn mod 23 y CSV de producción.
- Hoja A4 imprimible con **Code 128** (juegos B/C) y **QR** del portal.
- Códigos verificados con `zbarimg`.

Salidas en `lotes/` (ignoradas por git), cuadradas contra la base.

---

## 7. Documentación y calidad

- Suite ISO en `docs/`: alcance, arquitectura, modelo de datos, API RPC,
  seguridad, operación, pruebas, manual, riesgos, guía de retoma, rotación de
  claves, enrolado de lotes, seguridad bancaria/offline (BLINK-DOC-SEC-01
  1.0.0) y estándares industriales (BLINK-DOC-13 2.0.0). Índice BLINK-DOC-00
  1.5.1.
- `README.md` y `CHANGELOG.md` (Keep a Changelog + SemVer) en cada producto.
- Portal: **74 pruebas** en 6 archivos (dominio, formato, códigos, lotes, modo
  local y copia offline) + `tsc --noEmit`.
- Pruebas SQL de aceptación en `supabase/pruebas/0006_lotes.sql` y
  `0009_serie.sql`, ejecutadas contra producción dentro de una transacción con
  `ROLLBACK`.
- Despliegue continuo por GitHub Actions → Pages en cada push a `main`.
- El back-office todavía no tiene pruebas automatizadas propias (deuda D-04) y
  no hay E2E en CI.

---

## 8. Registro de despliegue

| Fecha | Hito |
| --- | --- |
| 2026-10-29 | Portal publicado; migraciones 0001–0008 aplicadas; back-office en Pages |
| 2026-10-30 | Series de 7 dígitos, maestra, estación secuencial, pantalla del validador |
| 2026-10-31 | Serie 5+3 y tarjeta Alfa (0014–0016), firmware v6, portal offline y endurecimiento de seguridad |

---

## 9. Lo que falta (no es riesgo aceptado: es trabajo pendiente)

1. **Enrolado físico de punta a punta** de la tarjeta Alfa y de un lote real
   (tarea #28), incluido el reemplazo de la `MASTER_KEY` de demostración.
2. **Restaurar MFA** del back-office (hoy hay un bypass temporal en la base) e
   inscribir el TOTP del propietario.
3. **Rotar** la contraseña de PostgreSQL y los tokens expuestos en chat
   (BLINK-DOC-11).
4. Carga de artes y paquete VDP/PDF-VT para la imprenta (B-16).
5. Restringir la estación al rol del propietario (B-17).
6. Recuperación de PIN, notificaciones al pasajero y exportación fiscal.
7. Mover el firmware a un repositorio versionado.

---

## 10. Riesgos aceptados: qué significan y por qué se aceptan

Un riesgo **aceptado** no es un riesgo ignorado: es uno que se conoce, se
documentó y se decidió **no mitigar todavía** porque el costo de la mitigación
supera el daño esperado en el escenario actual. Se revisa cuando cambia el
escenario (más usuarios, más operadores, requisito regulatorio o un incidente).
Se distingue de:

- **Abierto**: hay que corregirlo; hoy no está cubierto (R-01, R-02, R-03, R-06).
- **Mitigado**: hay un control que reduce la probabilidad o el impacto.
- **Mitigado (residual aceptado)**: hay control, pero queda una exposición
  pequeña que se asume conscientemente (R-10).

### 10.1 R-05 — Un mismo Supabase aloja comercio y transporte

**Qué es.** El POS (comercio) y el transporte (cuentas, tarjetas, recargas,
viajes) comparten proyecto de base de datos.

**Por qué se acepta.** Hoy lo opera una sola organización pequeña; separar
proyectos duplica costos, migraciones, respaldos y rotación de claves sin
beneficio operativo inmediato. El aislamiento se logra por diseño: dominios sin
claves foráneas cruzadas, RLS estricto, funciones `security definer` acotadas y
credenciales distintas por aplicación.

**Qué lo compensa.** El navegador solo tiene llaves publishable; las funciones
de comercio y de transporte no comparten parámetros ni tablas puente, de modo
que un fallo en un dominio no da acceso al otro. El daño de una fuga queda
acotado al dominio afectado.

**Cuándo se revisa.** Si aparece un requisito regulatorio de segregación, si
crece el número de comercios, o tras cualquier incidente que cruce dominios.

### 10.2 R-08 — Pérdida del teléfono del operador (TOTP solo se reinicia por SQL)

**Qué es.** Si el operador pierde el teléfono con el segundo factor, el reinicio
del TOTP requiere acceso a la base.

**Por qué se acepta.** Hay un único operador (el propietario) y también es quien
tiene acceso al panel de Supabase; el escenario de «no puedo recuperar mi
cuenta» se resuelve con el mismo acceso que ya se necesita para administrar el
sistema. Automatizar la recuperación (RPC con doble aprobación) añade una
superficie de ataque mayor que el problema que resuelve mientras haya un solo
operador.

**Qué lo compensa.** Procedimiento documentado (BLINK-DOC-06 §5.5) y secreto
TOTP que se muestra una sola vez; tras cualquier prueba se reinicia la
inscripción.

**Cuándo se revisa.** Al incorporar un segundo operador o al separar roles
(quien opera no debería ser quien administra la base).

### 10.3 R-10 residual — Copia sin conexión de datos personales sin cifrar

**Qué es.** Para abrir la tarjeta sin red, el teléfono guarda en `localStorage`
nombre, cédula, teléfono, correo, datos de Pago Móvil y el token de sesión. Si
alguien ejecuta código en la página (XSS) o usa un teléfono desbloqueado, puede
leerlos.

**Por qué se acepta (residual).** El cifrado con WebCrypto atado al PIN no
protege del caso principal: mientras la app está abierta, la clave está en
memoria y un XSS la obtiene igual. Añade complejidad de migración y fricción
(derivar clave, desbloquear, recuperar) sin cambiar el modelo de amenaza real,
que es «XSS en un origen estático» y «teléfono desbloqueado». Por eso se
prefirió **reducir la ventana** en lugar de fingir cifrado.

**Qué lo compensa.** Copia de solo lectura (no permite mover saldo), sin
capacidad de escritura ni claves de servicio; TTL de 12 h; rechazo de fechas
futuras; borrado al salir, al expirar o si el servidor rechaza la sesión; y una
superficie sin sinks de HTML (`dangerouslySetInnerHTML`, `innerHTML`, `eval`
ausentes) con enlaces externos `rel="noreferrer"`.

**Cuándo se revisa.** Si el portal se usa en equipos compartidos, si entra en
alcance regulatorio de datos personales, o cuando exista CSP (requiere dejar
GitHub Pages, L-03). Plan: D-09 y acción 11 del registro.

### 10.4 Límites de plataforma asumidos (L-01 a L-05)

No son decisiones de producto, sino restricciones del entorno que se aceptan con
un rodeo conocido:

- **L-01 Web Serial solo en Chromium de escritorio**: la estación es un puesto
  fijo; no se pretende enrolar desde el móvil.
- **L-02 Supabase solo IPv6 en el host directo**: la operación usa el pooler
  IPv4.
- **L-03 GitHub Pages sin cabeceras propias**: no hay CSP/HSTS configurables; se
  compensa con código sin inyección, `noreferrer` y un service worker acotado.
  Es la razón de fondo de que R-10 sea residual.
- **L-04 Base `/TARJETA/`**: mover a subdominio exige recompilar; se asume
  mientras se use Pages.
- **L-05 La tarjeta Alfa se crea por consola**: es una operación única del
  propietario; automatizarla en el panel es trabajo pendiente, no un riesgo
  operativo diario.

### 10.5 Riesgos que **no** están aceptados

Para que no se confundan con los anteriores:

- **R-01 / R-02 / R-03**: contraseña de PostgreSQL y tokens expuestos, y falta de
  2FA obligatorio en la organización. Requieren rotación y activación (tarea
  #29).
- **R-06**: `bt_registrar` sin límite por IP; falta *rate limiting* o captcha.
- **R-07**: TOTP implementado pero el operador aún no inscribió su teléfono; el
  bypass temporal de MFA debe retirarse al terminar las pruebas.

---

## 11. Cómo retomar

1. Leer `docs/10-guia-de-retoma.md` y `docs/09-riesgos-y-brechas.md`.
2. `cd ~/BLINK_Tarjeta && npm install && npm run dev` para el portal;
   `~/BLINK_Backoffice` en el puerto 5176 para el panel.
3. Variables: `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` (variables del
   repositorio en GitHub Actions; publishable por diseño).
4. Pruebas: `npm run typecheck && npm test`; SQL de aceptación en
   `supabase/pruebas/` **siempre** dentro de una transacción con `ROLLBACK`.
5. Migraciones por el pooler IPv4, nunca por el host directo.
