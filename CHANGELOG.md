# Changelog — BLINK TARJETA

Todos los cambios relevantes de este producto se documentan aquí.

Formato basado en [Keep a Changelog 1.1.0](https://keepachangelog.com/es-ES/1.1.0/)
y versionado [SemVer 2.0.0](https://semver.org/lang/es/). Las fechas usan ISO 8601.

## [No publicado]

### Añadido

- **BLINK-DOC-15**: auditoría de datos, RLS, integridad referencial y cierre
  del ciclo de recarga, con la evidencia de la prueba física.
- **Script de limpieza** `supabase/limpieza/2026-10-31_auditoria_y_purga.sql`:
  transaccional e idempotente, archiva lo que borra en
  `respaldo.purga_20261031` y se niega a tocar unidades con operación.
- **Prueba real de punta a punta**: la maestra `A-00000-000-H` quedó grabada
  en el chip (UID `3981BF06`); el primer toque aplicó una recarga de 5000 Bs y
  cobró 500, dejando `virtual_balance = last_chip_balance = 4500`, la recarga
  con `synced_to_chip = true` y una fila de telemetría.
- **BLINK-DOC-16** *Especificación offline del validador*: mapa real de
  memoria, ciclo de cobro con Read-After-Write, estado incierto, sincronización,
  matriz RSK-01…05, ADR-09 (un toque = un pasaje), ADR-10 (llaves derivadas) y
  ADR-11 (sin relé), con la tabla de verificación física del 2026-10-31.
- **Migración `0017_contador_de_chip.sql`**: columna
  `trips_telemetry.chip_counter` y disparador `bt_trip_contador_chip()` que la
  extrae del `offline_id` (`UID-epoch-contador-aleatorio`); 8 filas históricas
  rellenadas. Permite auditar la secuencia de escrituras del chip.
- **Verificación de escritura en el validador** (firmware v6): cada cobro y
  recarga relee el chip y exige saldo y contador exactos. Un fallo de escritura
  o de relectura emite `INCIDENCIA`, marca el serial como incierto y bloquea
  toques posteriores con **VERIFICAR** hasta que un operador envía
  `LIMPIAR_INCIERTAS`.

### Corregido

- **«Cobra una vez y luego no lee»** (firmware v6): tras autenticar, el
  MFRC522 quedaba en Crypto1 y el siguiente `REQA` viajaba cifrado, así que el
  lector no veía tarjetas nuevas hasta reiniciar. Todas las salidas pasan ahora
  por `soltarTarjeta()` (`PICC_HaltA()` + `PCD_StopCrypto1()`). Verificado con
  dos toques seguidos el 2026-10-31 21:41 (contadores 8 y 9).
- **Doble cobro latente por ciclo de antena**: el bucle re-energizaba la antena
  cada 2 s y despertaba la tarjeta en `HALT`, cobrándola en bucle. Se retiró el
  ciclo; la tarjeta cobrada queda en `HALT` hasta que se retira del campo.
- **Segundo toque perdido**: `REPETIR_MS` baja de 1500 a 500 ms para que un
  segundo toque deliberado (pagar dos pasajes) no caiga en la ventana de
  rebote.
- **Re-enrolado tras autenticación fallida (firmware v6)**: `reseleccionar()`
  corta y reenciende el campo RF antes de reintentar, porque el PICC no vuelve
  a IDLE por sí solo. El comando `ENROLAR … FORZAR` ya no termina en
  `ERROR,enrolado,lector`.

### Cambiado

- **Purga del vehículo demo `A99XY7Z`** (MAC `001122334455`, sin viajes ni
  liquidaciones); queda la unidad real `A12BC3D`. No se reiniciaron secuencias
  ni se tocaron cuentas, tarjetas, recargas, movimientos ni telemetría.
- **Suite documental 1.7.0**: DOC-07 §4.4 (prueba física), DOC-09 1.7.0
  (B-20, B-21, D-11) y DOC-15 nuevo. Pasa a 1.8.0 con DOC-16, DOC-07 §4.5,
  DOC-09 1.8.0 (B-23, D-12, L-07) y el cambio de política de ADR-09.
- **Un toque = un pasaje (ADR-09)**: se descarta acumular toques durante 2 s y
  el rebote de 15 s; cada presentación de la tarjeta cobra un pasaje, lo que
  permite pagar dos pasajes con dos toques.

### Pendiente

- Cargar el Pago Móvil real en `settings.publico` (hoy RIF y teléfono de
  ejemplo).
- Aplicar las guardas F-01/F-02 y la caducidad de pendientes (F-04).
- Revisar las recargas pendientes `6466` y `4346` reportadas durante la prueba.
- Probar el corte de energía a mitad de escritura y medir el tiempo de cobro
  (B-23); exponer `inciertas` en el back-office (B-22).
- Rotación de secretos y restauración del MFA.

## [1.5.0] — 2026-10-31

### Seguridad

- **Copia sin conexión con caducidad**: el respaldo local de la billetera
  (datos personales y token de sesión) vence a las 12 horas de la última
  sincronización, se descarta si la fecha está en el futuro y se borra al
  cerrar sesión, al expirar la sesión o al rechazarla el servidor. Una copia
  vencida o corrupta se elimina en vez de mostrarse.
- **Service worker acotado**: al actualizarse borra solo las cachés con
  prefijo `blink-tarjeta-` (el origen de GitHub Pages es compartido con las
  demás publicaciones), valida el origen y el ámbito de los mensajes, ignora
  URLs fuera de `/TARJETA/` y solo guarda recursos estáticos de su armazón;
  las respuestas de API nunca entran en la caché.
- Nuevas pruebas de la copia local: caducidad, desfase de reloj, formato
  anterior, JSON corrupto, aislamiento por token y almacenamiento lleno.
- Registro de riesgos actualizado con R-10 (datos en el teléfono) y R-11
  (cachés compartidas del origen) en BLINK-DOC-09.

### Añadido

- **Simulación local del flujo completo** (`simulacion/`): PostgreSQL 16,
  PostgREST v12 y un gateway nginx que reproduce `/rest/v1/rpc/*`. Los scripts
  `arrancar.sh`, `flujo.sh`, `portal.sh`, `backoffice.sh` y `detener.sh` cubren
  lote, enrolado, registro, reclamo, recarga, aprobación, sincronización con el
  validador, aplicación al chip, cobro y referencia duplicada, con aserciones y
  sin tocar producción. Incluye semilla de ruta, vehículo y cuenta `ADMIN`.
- **Redirección del dominio retirado**: `pasajes.blink.com.ve` lo sirve el
  repositorio `PASAJES-REDIRECT`, que lleva a BLINK TARJETA conservando el ancla.
- **Portal instalable y sin conexión**: service worker que guarda el armazón y
  los recursos, y copia local de la última billetera con sus movimientos. Sin
  red se abre la tarjeta y el saldo guardados, con el aviso «Saldo guardado en
  este teléfono · sin conexión». Recargar, vincular, cambiar PIN o datos de
  pago siguen necesitando internet.
- **Migración `0014_serie_cinco_mas_tres.sql`**: adopta BLINK-DOC-12 v2.0.0,
  BLINK-DOC-13 v2.0.0 y BLINK-DOC-SEC-01 v1.0.0.
  - Serie `T-LLLLL-UUU-V` con letra verificadora Luhn mod 23; el código de
    barras pasa a ser el serial compacto de 10 caracteres (`G00001001N`).
  - La tarjeta maestra `00-0-0000000-0` se renombra a `A-00000-000-H` y
    `bt_crear_tarjeta_alfa` reemplaza a `bt_crear_tarjeta_maestra`.
  - Lotes de 1 a 999 unidades y números de lote de 5 dígitos.
  - Estado `SCRAP` y eventos `RFPGC` / `CHIP_ERR`; nuevo `bt_admin_merma`.
  - Importes enteros en bolívares (pasaje 500, estudiante 250) en tarjetas,
    movimientos, recargas, rutas, viajes y liquidaciones.
- **Migración `0015_lotes_con_mermas.sql`**: `bt_admin_lotes` entrega
  `desechadas` y `sinEnrolar` exactos para que la estación no cuente las
  mermas como trabajo pendiente.
- **Migración `0016_corrige_alfabeto_verificador.sql`**: la clase de
  caracteres de 0014 excluía la `U` del alfabeto verificador; ahora el CHECK y
  las funciones aceptan seriales como `G-00007-005-U`.
- **Firmware v6 del validador**: bloque de identidad v3 con los 10 caracteres
  del serial compacto (`G00001001N`) en el sector 1, tarifa por defecto de
  Bs 500 y montos enteros en el protocolo serie, la pantalla y las colas NVS.
  Las colas heredadas en céntimos se convierten solas al arrancar. El comando
  `ENROLAR` admite `FORZAR` y re-enrolla la maestra en su sitio.
- Documentos BLINK-DOC-12 v2.0.0, BLINK-DOC-13 y BLINK-DOC-14 en `docs/`.

### Cambiado

- **Se retira BLINK PASAJES**: el panel de la línea se archiva y su dominio pasa
  a redirigir a este portal. El perfil ya no muestra el enlace «Panel de la línea»
  y las referencias visibles dicen **BLINK TARJETA** (el titular legal de la
  cuenta de Pago Móvil sigue siendo BLINK PASAJES, C.A.).
- El back-office deja de ofrecer la asignación en taquilla: el flujo es
  estación del propietario → venta en comercios → reclamo en el portal.
- `bs()` del back-office muestra bolívares enteros, sin céntimos.
- El portal del pasajero también muestra bolívares enteros y valida montos sin
  céntimos; la tarjeta virtual oculta la coma cuando no hay decimales.
- El portal vincula con la máscara `G-00001-001-N`, exige la letra
  verificadora mod 23 y el Code 128 del reverso codifica el serial compacto
  alfanumérico con los juegos B y C.
- La semilla de demostración del portal usa la serie nueva y la tarifa de
  500 bolívares.

### Corregido

- **Tarjeta virtual en navegadores sin *container queries*** (iOS 15 y
  anteriores, Android viejo): cada medida del naipe lleva una unidad de
  respaldo proporcional al ancho (`--np`) antes del valor en `cqw`, de modo que
  la maqueta se mantiene aunque el navegador no entienda contenedores. La
  leyenda del reverso se reparte equilibrada y el sello de sincronización queda
  pegado al texto cuando ocupa dos líneas.
- **Migración `0012_asignar_exige_enrolada.sql`**: `bt_estacion_asignar` ya no
  activa plásticos sin `chip_uid`. Antes la taquilla podía asignar una tarjeta
  que el validador no podía leer; ahora responde `bt:sin-enrolar` y remite a la
  estación de enrolado.
- **Migración `0013_portal_exige_enrolada.sql`**: misma guarda en `bt_vincular`
  y en la heredada `bt_activar`; el portal y el back-office reconocen el código
  `sin-enrolar` y muestran el mensaje de la base.

### Documentación

- **Suite documental 1.6.0 (BLINK-DOC-00)**: alcance reducido a TARJETA +
  BACK-OFFICE con el panel fiscal como próximo hito; retiro de PASAJES,
  redirección del dominio y consolidación en `~/BLINK`.
- **BLINK-DOC-06 1.5.0 §5.7** y **BLINK-DOC-07 1.4.0 §4.3**: simulación local del
  flujo completo, puertos, semilla y resultados de la prueba del 2026-10-31.
- **BLINK-DOC-09 1.6.0**: brechas B-03 cerrada y B-04/B-18/B-19 actualizadas,
  deuda D-10 y limitación L-06 del redirect.
- **BLINK-DOC-06 1.4.0 §5.6**: ciclo completo de una recarga (reporte del
  pasajero, bandeja `bt_recargas_pendientes`, revisión contra el banco,
  aprobación/rechazo, entrega al chip por el validador y consultas de
  verificación), con los efectos exactos de cada RPC y los errores típicos.
- **BLINK-DOC-08 1.3.0 §5.1**: resumen operativo de la aprobación para el
  administrador de línea. Suite documental 1.5.2.

### Pendiente

- Recuperación de PIN en el portal.
- Interfaz de aprobación de recargas para el administrador.
- Notificaciones por correo al acreditar una recarga.
- Gestión de operadores y reinicio de TOTP desde la interfaz del back-office.
- Prueba física de enrolado y cobro con el lector (tarea #28).
- Grabado del chip desde la estación web y cola secuencial con *tap & next*.
- Carga de artes y paquete de producción ZIP VDP / PDF-VT.

## [1.4.0] — 2026-10-30

Serial maestro de once dígitos `00-0-0000000-0` y alineación de la guía de
enrolado con el estándar de producción del propietario (impresión ID-1/CR80,
paquete de datos variables y enrolado secuencial).

### Añadido

- **Migración `0010_maestra_once_digitos.sql`**: `bt_crear_tarjeta_maestra` crea
  `00-0-0000000-0` y el evento `ASIGNADA` queda en canal `sistema`; el bloque
  final renumera la maestra existente desde el serial heredado de 10 dígitos y
  registra el cambio en `card_events`.
- **BLINK-DOC-12 v2.0.0**: exclusividad de la estación, distribución pre-enrolada
  sin taquilla, medidas de sangrado/corte/zona segura, paquete ZIP VDP y PDF/VT,
  enrolado en ráfaga con *tap & next* y punto de control, y tabla de estado de
  implementación.
- **Suite de aceptación ampliada** con el serial maestro heredado como caso de
  compatibilidad (BLINK-DOC-07 §3.6).

### Cambiado

- El serial maestro pasa de 10 a 11 dígitos: `barcode_data` queda en
  `00000000000`. La serie de lote no cambia.
- BLINK-DOC-03, 04, 07 y 09 reflejan la migración `0010`; el registro de brechas
  añade B-14 a B-17 (grabado del chip desde el panel, *tap & next*, artes y
  paquete de imprenta, estación exclusiva del propietario).

### Base de datos

- `0010` aplicada en producción el 2026-10-30: la maestra quedó `ACTIVE`,
  `state_code = 0`, `fare_type = 0`, sin `batch_id` y sin UID, con los eventos
  `ASIGNADA` originales más el de la renumeración. Suite `PRUEBAS_0009_OK`.

## [1.3.0] — 2026-10-30

Serie de identificación de siete dígitos (`23-1-0000001-9`), tarjeta maestra del
propietario y guía de enrolado por lotes. La serie heredada de seis dígitos sigue
siendo válida.

### Añadido

- **Migración `0009_serie_siete_digitos.sql`**: `bt_luhn_digito` y
  `bt_luhn_valido` aceptan 10 y 11 dígitos; `bt_generar_lote` numera a siete
  dígitos con `p_desde` opcional y rechaza rangos que se solapan.
- **Tarjeta maestra**: `bt_crear_tarjeta_maestra(cedula, uid, operador, tarifa)`
  la crea activa, asignada a la cuenta dueña, con `fare_type = 0`, fuera de todo
  lote y con bitácora `ASIGNADA`/`ENROLADA`. Solo `service_role`. Nació con el
  serial de 10 dígitos `00-0-000000-0`; `0010` la renumeró a `00-0-0000000-0`.
- **BLINK-DOC-12**: guía de enrolado de lotes, desde la maestra hasta la entrega,
  con verificación y resolución de problemas.
- **Hoja imprimible del lote de arranque** (`lotes/lote-001.csv` y `.html`):
  20 tarjetas `23-1-0000001-9` … `23-1-0000020-9`, cuadradas contra la base.
- **Suite `supabase/pruebas/0009_serie.sql`** con nueve comprobaciones dentro de
  una transacción que termina en `ROLLBACK`.

### Cambiado

- El portal formatea y valida seriales de 10 y 11 dígitos; el Code 128 usa juego
  C con símbolo de cambio a B para el dígito final.
- `cards_visible_id_check` admite `\d{6,7}` en el bloque secuencial;
  `cards_fare_type_check` admite `0` para la maestra.
- La renumeración del lote de arranque es idempotente: se aplica solo a tarjetas
  `FABRICADA` sin UID, sin cuenta y sin movimientos.

### Corregido

- `npm run lote` volvía a fallar con Node 22 por un import sin extensión en
  `src/lib/dominio.ts`; el generador de hojas ya corre con el Node del sistema.

### Firmware (fuera de git: `~/Arduino/BLINK_Validador`)

- Bloque de identidad v2 con el serial en ASCII y longitud explícita (hasta 11
  dígitos); las tarjetas v1 se siguen leyendo. `VERSION_FW = 4`.
- `ENROLAR` acepta seriales de 13 o 14 caracteres y tarifas `0`, `1` y `2`.

### Base de datos

- `0009` aplicada en producción el 2026-10-30: 20 tarjetas renumeradas a
  `23-1-0000001-9` … `23-1-0000020-9`, maestra creada para `V-34201580` (sin
  UID) y suite de aceptación en verde (`PRUEBAS_0009_OK`). El siguiente
  secuencial libre es `21`.

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
