# Enrolado y producción de lotes de tarjetas

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-12 |
| Versión | 2.0.0 |
| Fecha | 2026-10-30 |
| Estado | Vigente |
| Normas | ISO/IEC 7812-1 · ISO/IEC 7810 (ID-1 / CR80) · ISO/IEC 15417 (Code 128) · ISO/IEC/IEEE 26511 · 26514 · PDF/VT |
| Público | Propietario y Administrador Principal (Diego Beleño) |

## 1. Objeto y alcance

Este documento describe cómo se pasa un plástico MIFARE en blanco a tarjeta
BLINK lista para vender en tiendas, kioscos y comercios aliados: qué se genera
en la base, qué se manda a la imprenta, cómo se graba el chip y cómo se
comprueba que quedó bien.

Rigen tres principios:

1. **Exclusividad de la estación.** El enrolado y la generación de lotes **no se
   hacen en taquilla ni en comercios**. Solo el propietario (**Diego Beleño,
   `V-34201580`**) opera la estación desde el back-office.
2. **Distribución pre-enrolada.** Toda tarjeta física que sale a un punto de
   venta externo sale de la estación con el chip ya grabado y su `chip_uid`
   registrado en la base. El comercio solo entrega el plástico; el pasajero lo
   reclama desde su aplicación web o móvil.
3. **Cobertura.** Se cubren dos casos:
   - **La tarjeta maestra del propietario**, `00-0-0000000-0`, exclusiva y
     permanente de Diego Beleño, que actúa como patrón de verificación del
     ecosistema.
   - **Los lotes de producción comercial**, serie de siete dígitos
     (`23-1-0000001-9`, `23-1-0000002-7`, …) con frente corporativo y reverso
     variable por patrocinante.

Presupone aplicadas las migraciones `0009_serie_siete_digitos.sql` (serie de
siete dígitos) y `0010_maestra_once_digitos.sql` (serial maestro de once
dígitos). §10 dice qué parte de este estándar ya está implementada y qué parte
sigue pendiente.

## 2. La serie de identificación

### 2.1 Estructura del serial (11 dígitos)

```
 23      -  1     -  0000001  -  9
 │          │        │           └── verificador de Luhn (ISO/IEC 7812-1)
 │          │        └────────────── secuencial de 7 dígitos (0000000 a 9999999)
 │          └─────────────────────── tipo de tarifa
 └────────────────────────────────── código de entidad federal
```

| Bloque | Dígitos | Valores permitidos |
| --- | --- | --- |
| Entidad | 2 | `00` serie exclusiva del emisor (maestra) · `23` Zulia · `01`–`99` otras entidades |
| Tarifa | 1 | `0` maestra del propietario · `1` general · `2` estudiante / tercera edad |
| Secuencial | 7 | `0000000` (exclusivo de la maestra) · `0000001`–`9999999` (producción) |
| Luhn | 1 | Verificador calculado sobre los 10 dígitos anteriores |

El verificador se calcula **de derecha a izquierda**, duplicando el valor de las
posiciones pares contando desde el extremo derecho del número sin guiones.

La base conserva la serie heredada de seis dígitos (`23-1-000001-9`) como
válida y legible: el formato aceptado es `^\d{2}-\d-\d{6,7}-\d$` y la migración
`0009` renumeró el lote de arranque a la serie nueva.

### 2.2 Ejemplos

| Serial | Dígitos | Significado |
| --- | --- | --- |
| `00-0-0000000-0` | 11 | **Tarjeta maestra exclusiva de Diego Beleño (`V-34201580`)** |
| `23-1-0000001-9` | 11 | Primera tarjeta general de Zulia |
| `23-1-0000002-7` | 11 | Segunda tarjeta general de Zulia |
| `23-2-0000001-8` | 11 | Primera tarjeta estudiantil / tercera edad de Zulia |
| `23-1-000001-9` | 10 | Serie heredada: sigue validando y sigue siendo legible |

### 2.3 Reglas de la tarjeta maestra (`00-0-0000000-0`)

La maestra pertenece única y exclusivamente a **Diego Beleño (`V-34201580`)**:

- **Fuera de lotes comerciales.** Tiene `batch_id` nulo, y `bt_generar_lote`
  tiene prohibido producirla: solo acepta entidades `01`–`99` y tarifas `1` o
  `2`, así que nunca genera la entidad `00`, la tarifa `0` ni el secuencial
  `0000000`.
- **Nace activa y vinculada.** Se registra en estado `ACTIVE` bajo la
  titularidad de `V-34201580`, sin pasar por `FABRICADA`.
- **Patrón de diagnóstico en campo.** Permite verificar de extremo a extremo la
  lectura RFID, la derivación de llaves en el ESP32, la firma criptográfica y el
  descuento de saldo en base de datos.
- **Viaja con la tarifa general.** La tarifa `0` identifica el plástico, no lo
  exime del pago. Si se define una tarifa exenta se implementa en el cobro y se
  documenta aparte.

### 2.4 Reglas que la base hace cumplir

| Regla | Dónde |
| --- | --- |
| Formato `^\d{2}-\d-\d{6,7}-\d$` | Restricción `cards_visible_id_check` |
| Luhn válido sobre el serial completo | Misma restricción, con `bt_luhn_valido` |
| Entidad, tarifa y secuencial coinciden entre columnas y texto | `cards_identificador_coherente` |
| Tarifa solo `0`, `1` o `2` | `cards_fare_type_check` |
| Serial único y código de barras único | Índices `cards_visible_id_key` y `cards_barcode_idx` |
| Código de barras derivado del serial | Columna generada `barcode_data` = `regexp_replace(visible_id, '\D', '', 'g')` |
| Una tarjeta de lote nace `FABRICADA` | `bt_generar_lote` |

`barcode_data` es **columna generada**: nunca se escribe a mano, ni en SQL ni en
los formularios.

## 3. Diseño e impresión de tarjetas PVC (ID-1 / CR80)

Cada lote tiene dos componentes: el **diseño frontal** (fijo para el lote o la
marca) y el **reverso**, que combina el arte variable del patrocinante con los
elementos que genera el sistema (Code 128 y serial impreso).

### 3.1 Dimensiones

Para que el troquel no corte textos ni códigos, se trabaja con tres áreas
concéntricas bajo **ISO/IEC 7810 (ID-1 / CR80)**:

| Parámetro | Milímetros | Centímetros | Pulgadas | Píxeles a 300 DPI | Píxeles a 600 DPI |
| --- | --- | --- | --- | --- | --- |
| **Sangrado (*bleed*)** — tamaño del archivo que se sube | 89,60 × 57,98 mm (+2 mm por lado) | 8,96 × 5,80 cm | 3,527″ × 2,282″ | 1058 × 685 px | 2117 × 1370 px |
| **Corte final (*trim*)** — medida real del PVC | 85,60 × 53,98 mm | 8,56 × 5,40 cm | 3,375″ × 2,125″ | 1011 × 638 px | 2022 × 1275 px |
| **Área segura (*safe zone*)** — límite para textos, logos y códigos | 79,60 × 47,98 mm (−3 mm por lado) | 7,96 × 4,80 cm | 3,134″ × 1,889″ | 940 × 567 px | 1880 × 1133 px |

- **Grosor del sustrato:** 0,76 mm (760 µm ± 80 µm), equivalente a 30 mil en PVC
  laminado.
- **Radio de esquinas:** 3,18 mm (rango ISO entre 2,88 mm y 3,48 mm).

### 3.2 Formatos de arte admitidos

- **Vectorial (recomendado):** `.SVG` o `.PDF` vectorial. Escalado matemático
  sin pérdida de nitidez.
- **Mapa de bits:** `.PNG` o `.TIFF` sin compresión con pérdida, a **300 DPI**
  mínimo en las dimensiones de sangrado (1058 × 685 px).

### 3.3 Composición semiautomática del reverso

Al subir el arte del reverso, el sistema aplica:

1. **Ajuste con sangrado:** encaja el arte en el lienzo de 89,60 × 57,98 mm y
   muestra la línea de corte (85,60 × 53,98 mm) y la máscara de esquinas
   redondeadas.
2. **Reserva de zona blanca (*quiet zone*):** superpone o valida una ventana de
   blanco puro `#FFFFFF` en la coordenada designada para el **Code 128** y el
   **serial impreso**. Ningún código se imprime sobre fondos oscuros o tramas
   publicitarias.

La Code 128 codifica los dígitos del serial sin guiones en juego C; la serie de
11 dígitos cambia a juego B en el último dígito. La hoja imprimible que ya
genera `npm run lote` lo hace así y los códigos se verificaron con `zbarimg`.

## 4. Paquete de producción para la imprenta

El generador produce un **Paquete de Producción Industrial (`.ZIP`)** con dos
modalidades estándar en artes gráficas.

> **Estado (§10):** hoy el repositorio genera CSV y hoja A4 imprimible
> (`npm run lote`). El ZIP con las dos modalidades y la carga de artes desde el
> back-office están **pendientes**.

### 4.1 Modalidad 1 — Datos variables VDP

Compatible con *Adobe InDesign Data Merge*, *CardPresso*, *Bartender* y *Zebra
CardStudio*. La imprenta recibe tres archivos ligeros, sin importar si el lote
es de 100 o de 10 000 tarjetas:

1. `01_FRENTE_MAESTRO.pdf` (o `.png` / `.svg`): diseño frontal único del lote.
2. `02_REVERSO_BASE_PUBLICIDAD.pdf`: reverso publicitario con el espacio
   reservado en blanco para la variable.
3. `03_SECUENCIA_LOTE_XXX.csv`: tabla ordenada del 1 al N, con las columnas que
   espera la máquina:

```csv
orden_impresion,serial_visible,barcode_code128,lote_id,patrocinante
1,23-1-0000021-7,23100000217,LOTE-002,"Comercial, C.A."
2,23-1-0000022-5,23100000225,LOTE-002,"Comercial, C.A."
3,23-1-0000023-3,23100000233,LOTE-002,"Comercial, C.A."
```

### 4.2 Modalidad 2 — PDF multipágina (PDF/VT)

Para imprentas que reciben el arte final ya fusionado:

- Un solo `LOTE_002_IMPRESION_DIRECTA.pdf`.
- **Página 1:** frente maestro, común a toda la tirada.
- **Páginas 2 a N+1:** los N reversos numerados en estricto orden ascendente.
- **Optimización XObject master:** el arte del reverso se incrusta una sola vez
  como plantilla maestra y en cada página solo se dibujan los vectores ligeros
  del serial y las barras. Un PDF de 1000 tarjetas pesa entre 3 MB y 8 MB y la
  imprenta lo procesa de corrido.

### 4.3 Orden de producción

El orden del CSV y el de las páginas del PDF son la base del enrolado
secuencial: la imprenta entrega las pilas ordenadas de la primera a la última
tarjeta del lote.

## 5. Estados del plástico y flujo de vida

```
   bt_generar_lote (back-office)          estación de enrolado (solo propietario)
 ─────────────────────────────▶ FABRICADA ─────────────────────────────▶ FABRICADA
                                 (sin UID)                                (con chip_uid)
                                                                              │
                                                        bt_vincular (portal del pasajero)
                                                                              ▼
                                                                           ACTIVE
                                                                              │
                                                              bt_reportar_perdida
                                                                              ▼
                                                                            LOST
```

| Estado | Significado en base de datos | ¿Apta para vender en comercios? |
| --- | --- | --- |
| `FABRICADA` sin UID | Serial reservado e impreso, aún no pasó por el lector RFID de la estación | **No.** No se distribuye. |
| `FABRICADA` con `chip_uid` | Plástico pasado por la estación: chip grabado y asociado a su serial | **Sí.** Lista para kioscos y comercios. |
| `ACTIVE` | El pasajero la compró y reclamó el serial en su aplicación (`bt_vincular`) | En uso por el pasajero. |
| `LOST` / `BLOCKED` | Desactivada por extravío o bloqueo administrativo | Inoperativa en validadores. |

Enrolar (grabar el chip) y vincular (dar dueño) son pasos independientes: un
lote puede quedar completamente enrolado y seguir `FABRICADA` hasta que un
pasajero lo reclame. **No hay entrega por taquilla en el flujo comercial**: el
plástico se vende pre-enrolado en el comercio y el pasajero lo activa en su
app.

## 6. Procedimiento operativo

Todo se ejecuta en el back-office (`https://blink-servers.github.io/BACKOFFICE/`
o `npm run dev` en `~/BLINK_Backoffice`, puerto 5176) con la cuenta ADMIN y el
segundo factor TOTP activo.

### Paso 1 — Tarjeta maestra (`00-0-0000000-0`)

Se ejecuta **una sola vez** para crear y blindar el plástico maestro:

```sql
select public.bt_crear_tarjeta_maestra('34201580', null, 'propietario');
```

La función es de `service_role`: se ejecuta por la conexión de administración,
nunca desde el navegador. Devuelve la tarjeta y la cuenta; si el serial ya
existe responde «La tarjeta maestra 00-0-0000000-0 ya existe» y no duplica
nada.

Después, en la pestaña **Estación**:

1. Conectar el lector ESP32 por USB y elegir el puerto.
2. Seleccionar *Cualquier lote* (la maestra no pertenece a ninguno) y escribir
   el serial `00-0-0000000-0`.
3. Apoyar el plástico maestro en el lector hasta obtener el `chip_uid`.
4. Subir la captura al inventario.

El grabado del bloque de identidad y de las llaves diversificadas en el chip se
hace hoy por la consola del firmware (§7.3); desde la estación web queda
pendiente (§10).

**Verificación:**

```sql
select visible_id, state_code, fare_type, status, chip_uid
  from public.cards where visible_id = '00-0-0000000-0';
select e.evento, e.canal, e.operador, e.at
  from public.card_events e join public.cards c on c.id = e.card_id
 where c.visible_id = '00-0-0000000-0' order by e.at;
```

Esperado: `state_code = 0`, `fare_type = 0`, `status = ACTIVE`, `chip_uid`
informado y los eventos `ASIGNADA` (canal `taquilla`, operador `propietario`) y
`ASIGNADA` (canal `sistema`, operador `migracion-0010`, por la renumeración), más
`ENROLADA` cuando se grabe el chip.

### Paso 2 — Crear el lote y exportar a imprenta

1. **Lotes → Nuevo lote**: cantidad (p. ej. 500 o 1000 unidades), entidad `23`,
   tarifa `1` o `2` y nombre del patrocinante.
2. Subir el arte del **frente** y del **reverso publicitario** (`.SVG`, `.PDF` o
   `.PNG` a 300 DPI). La carga de artes está pendiente (§10); hoy el arte se
   prepara fuera y se entrega junto al CSV.
3. El sistema reserva los seriales (`bt_generar_lote`) y se descarga el paquete
   para la imprenta con el PDF y el CSV secuencial.

Equivalente por SQL, con inicio explícito:

```sql
-- 100 tarjetas generales de Zulia, empezando en el secuencial 21.
select public.bt_generar_lote(
  p_cantidad     => 100,
  p_patrocinante => 'Comercial, C.A.',
  p_estado       => 23,
  p_tarifa       => 1,
  p_origen       => 'FABRICANTE',
  p_desde        => 21
);
```

Sin `p_desde` toma el siguiente secuencial libre de esa entidad y tarifa. Si el
rango se solapa responde «La serie 23-1 ya tiene tarjetas entre … y …» y no crea
nada.

Generador actual de la línea de producción:

```bash
cd ~/BLINK_Tarjeta
npm run lote -- --cantidad 100 --desde 21 --lote 2 \
  --patrocinante "Comercial, C.A." --tarifa 1
```

Escribe en `lotes/` (ignorado por git) el `lote-002.csv` —serial, código de
barras y columna `uid` vacía— y el `lote-002.html`, hoja A4 con 8 tarjetas por
página, Code 128 vertical y QR del portal. Para imprimir: abrir el HTML,
`Ctrl+P`, A4, márgenes mínimos, sin encabezado ni pie; comprobar una hoja con
el lector (el Code 128 devuelve los dígitos sin guiones).

El generador es independiente de la base: si se usa junto con
`bt_generar_lote`, ambos deben partir del mismo `--desde` o los seriales no
coinciden.

### Paso 3 — Enrolado en ráfaga secuencial

La imprenta imprime en el orden estricto del PDF o del CSV, así que las pilas
llegan ordenadas de la primera a la última tarjeta del lote (por ejemplo, de la
`23-1-0000021-7` a la `23-1-0001020-3`).

1. **Seleccionar el lote** en la estación: el sistema carga en cola los seriales
   pendientes de UID en orden ascendente y apunta al primero.
2. **Validar el inicio de la pila:** escanear el Code 128 de la primera tarjeta
   física para confirmar que el mazo empieza exactamente en ese serial.
3. **Toque y avance automático (*tap & next*):** se apoya la tarjeta en el
   lector; el sistema lee el `chip_uid`, graba el serial y las llaves
   diversificadas en el chip, confirma con un pitido y avanza el puntero al
   siguiente serial.
4. **Punto de control anti-desfase:** cada 25 o 50 tarjetas (configurable), o a
   voluntad del operador, la estación pide confirmar que los últimos dígitos del
   plástico en la mano coinciden con el serial en pantalla. Evita que una
   tarjeta pegada desfase el resto de la pila.
5. **Sincronización con el inventario:** al terminar la tanda o en bloques, la
   estación ejecuta `bt_estacion_enrolar`, deja los `chip_uid` sellados y las
   tarjetas listas para empaquetar y enviar a los comercios.

Los pasos 2 a 4 (cola secuencial, *tap & next* y punto de control) son parte del
estándar y están **pendientes de implementación** en la estación web; hoy el
operador captura serial y UID uno por uno (§7.2) y el grabado del chip se hace
por consola (§7.3).

### Paso 4 — Distribución y reclamo

El comercio recibe la caja con las tarjetas pre-enroladas y solo entrega el
plástico. El pasajero entra a `https://blink-servers.github.io/TARJETA/`, inicia
sesión y en **Vincular tarjeta** escribe el serial del reverso. `bt_vincular`
comprueba que exista, que no tenga dueño y que no esté vencida, la pasa a
`ACTIVE` y la suma a su billetera.

Una tarjeta ya asignada **no** se transfiere a otra cuenta: se reporta como
perdida y se emite otra. `LOST` es irreversible desde el portal.

## 7. Operación con lo que hay hoy

### 7.1 Requisitos previos

| Elemento | Detalle |
| --- | --- |
| Cuenta del propietario | Registrada en el portal con cédula y PIN (la maestra se asigna a ella) |
| Cuenta ADMIN | Con TOTP confirmado para entrar al back-office |
| Back-office | `https://blink-servers.github.io/BACKOFFICE/` o `npm run dev` en `~/BLINK_Backoffice` |
| Validador | ESP32 con firmware **v4** (`VERSION_FW = 4`) y MFRC522 conectado |
| Navegador | Chrome o Edge de escritorio: Web Serial no existe en móvil |
| Plásticos | MIFARE Classic 1K en blanco, uno por serial |
| Conexión a la base | Solo para administración; el operador no la necesita |

Los plásticos deben estar **en blanco**. Si un chip ya tiene datos de otra
tarjeta, el enrolado falla con «Ya está enrolada con el UID …» o «El UID ya
pertenece a otra tarjeta».

### 7.2 Estación web (captura UID ↔ serial)

1. **Estación → Conectar lector** y elegir el puerto. El lector responde
   `READY,BLINK,<v>`.
2. Por cada tarjeta: escanear el Code 128 en *Serial impreso*, apoyar el
   plástico hasta que aparezca el UID y pulsar *Añadir a la lista*.
3. Al terminar la tanda, *Subir al inventario*: se envían los pares a
   `bt_estacion_enrolar` con el `p_token` de la sesión.

```json
{ "ok": true, "enroladas": 98, "rechazadas": 2,
  "errores": [ { "serial": "23-1-0000050-4", "motivo": "El UID ya pertenece a otra tarjeta" } ] }
```

Un rechazo no detiene la tanda: se corrige esa fila y se vuelve a subir solo la
que falló. La estación web **no graba el chip**: solo registra la pareja en la
base.

### 7.3 Grabado del chip por consola serie

El validador acepta comandos por el puerto serie a 115200 baudios:

```
ENROLAR,23-1-0000021-7,0,1
ENROLAR,23-1-0000021-7,0,1,3981BF06
```

- `serial`: el ID impreso (10 u 11 dígitos).
- `saldo`: saldo inicial en céntimos; usar `0` en producción.
- `tarifa`: `1` general, `2` estudiante, `0` maestra.
- Quinto campo opcional: fuerza el UID esperado del plástico.

Respuestas: `ENROLAR_LISTO,serial=…,uid=…` al armarse y `ENROLADA,serial=…,uid=…`
al grabar. Se desarma solo a los 60 s.

El firmware escribe el bloque de identidad v2 (dígitos ASCII, longitud, tarifa,
estado, versión y CRC-8) y deriva las llaves del UID. Lee también el bloque v1
de firmware anteriores, de modo que un plástico viejo sigue funcionando.

### 7.4 Reglas del enrolado

| Situación | Resultado |
| --- | --- |
| Serial inexistente en la base | `Serial no registrado` |
| Serial de otro lote | `El serial no pertenece al lote` |
| Chip ya grabado con otro UID | `Ya está enrolada con el UID …` |
| UID ya usado por otra tarjeta | `El UID ya pertenece a otra tarjeta` |
| Serial con Luhn inválido | `Serial inválido` |

### 7.5 Firmware

Un validador con firmware v3 solo entiende la serie heredada de 10 dígitos: hay
que actualizarlo a v4 antes de poner en circulación la serie nueva. Un plástico
grabado por v3 se sigue leyendo con v4.

## 8. Verificación y control

### 8.1 Consultas de control

```sql
-- Inventario por lote y estado.
select b.batch_number as lote, b.sponsor_name as patrocinante,
       count(*) filter (where c.status = 'FABRICADA') as fabricadas,
       count(*) filter (where c.status = 'ACTIVE')    as activas,
       count(c.chip_uid)                              as enroladas,
       min(c.visible_id) as desde, max(c.visible_id) as hasta
  from public.card_batches b
  join public.cards c on c.batch_id = b.id
 group by b.batch_number, b.sponsor_name
 order by b.batch_number;

-- Tarjetas sin UID (pendientes de pasar por el lector).
select visible_id from public.cards
 where chip_uid is null and fare_type <> 0
 order by visible_id;

-- Bitácora de una tarjeta.
select e.evento, e.canal, e.operador, e.at
  from public.card_events e
  join public.cards c on c.id = e.card_id
 where c.visible_id = '23-1-0000021-7'
 order by e.at;
```

### 8.2 Prueba de aceptación

`supabase/pruebas/0009_serie.sql` recorre en una transacción que termina en
`ROLLBACK`: Luhn de la serie heredada y de la nueva; formato y verificador de
todas las tarjetas almacenadas; alta de la maestra `00-0-0000000-0` y rechazo de
la duplicada; lote con inicio explícito y rechazo del solapado; enrolado de un
serial de 11 dígitos con su evento; rechazo de la tarifa 0 en un lote.

```bash
psql "$CADENA" -v ON_ERROR_STOP=1 -f supabase/pruebas/0009_serie.sql
# NOTICE:  PRUEBAS_0009_OK
```

Es idempotente: si la maestra ya existe, la retira dentro de la transacción para
probar el alta desde cero y el `ROLLBACK` la devuelve intacta. Ejecutada en
producción el 2026-10-30 con `PRUEBAS_0009_OK` y sin dejar rastro.

### 8.3 Semáforo de una tarjeta lista para vender

| Comprobación | Cómo |
| --- | --- |
| Existe y está `FABRICADA` | Consulta §8.1 |
| Tiene `chip_uid` | Columna no nula |
| El Code 128 coincide con el serial | Lectura con lector de códigos |
| El validador la lee | Pasar el plástico: `CARD,<uid>` sin error |
| El chip tiene las llaves | Sin `no-enrolada` ni `corrupta` al pasar |

## 9. Problemas frecuentes

| Síntoma | Causa | Solución |
| --- | --- | --- |
| `Serial inválido` | Guion de más, dígito cambiado o longitud distinta de 10/11 dígitos | Revisar contra el CSV del lote |
| `No encontramos ese serial` | El lote no se generó en la base | Crear el lote antes de enrolar |
| `El serial no pertenece al lote` | Se eligió otro lote en la estación | Seleccionar el lote correcto |
| `El UID ya pertenece a otra tarjeta` | El plástico se usó antes | Usar un plástico en blanco |
| El lector no aparece en el navegador | Web Serial no disponible o puerto ocupado | Chrome/Edge de escritorio, HTTPS, cerrar el monitor serie |
| `no-enrolada` al pasar la tarjeta | El chip no tiene las llaves derivadas | Volver a grabar con `ENROLAR` |
| `corrupta` al pasar la tarjeta | Bloque de identidad ilegible | Re-grabar; si persiste, descartar el plástico |
| El lote dice «ya tiene tarjetas entre …» | El rango se solapa | Usar `p_desde` con el siguiente libre |

## 10. Estado de implementación (2026-10-30)

| Requisito del estándar | Estado | Dónde |
| --- | --- | --- |
| Serial de 11 dígitos y Luhn | Implementado | `0009_serie_siete_digitos.sql` |
| Tarjeta maestra `00-0-0000000-0` exclusiva | Implementado | `0010_maestra_once_digitos.sql` |
| Lotes con inicio explícito y sin solape | Implementado | `bt_generar_lote` |
| Code 128 de 11 dígitos y hoja A4 | Implementado | `npm run lote` |
| CSV de secuencia para imprenta | Parcial: columnas `serial`, `barcode`, `uid`; falta `orden_impresion`, `lote_id` y `patrocinante` | `scripts/lote.ts` |
| Carga de artes y composición del reverso | Pendiente | — |
| ZIP de producción (VDP + PDF/VT con XObject) | Pendiente | — |
| Registro UID ↔ serial en la base | Implementado (captura manual) | `bt_estacion_enrolar` |
| Grabado del chip desde la estación web | Pendiente: hoy va por consola `ENROLAR` | firmware v4 |
| Cola secuencial, *tap & next* y punto de control | Pendiente | — |
| Estación reservada al propietario | Pendiente: `bt_admin_sesion_mfa` admite ADMIN y TAQUILLA | `0007_backoffice_mfa.sql` |
| Distribución pre-enrolada sin taquilla | Norma operativa vigente; el módulo Taquilla sigue existiendo para casos puntuales | back-office |

Los pendientes están también en [Riesgos y brechas](09-riesgos-y-brechas.md).
Ninguna tarjeta debe salir a un comercio hasta que tenga `chip_uid` grabado y
verificado con el validador.

## 11. Trazabilidad

Cada paso queda en `public.card_events`:

| Evento | Cuándo | Canal |
| --- | --- | --- |
| `ENROLADA` | Se grabó el UID | `estacion` |
| `ASIGNADA` | Se vinculó a una cuenta | `portal` o `taquilla`; `sistema` para la renumeración de la maestra |
| `PERDIDA` | Se reportó el extravío | `sistema` |

La tabla tiene RLS activo y no es legible desde el navegador: se consulta con la
conexión de administración. Es la evidencia para auditar quién enroló, quién
entregó y cuándo.

## 12. Resumen operativo

```
1. Cuenta del propietario registrada              (una vez)
2. bt_crear_tarjeta_maestra → 00-0-0000000-0      (una vez)
3. bt_generar_lote          → 23-1-0000021…       (por lote)
4. Arte + CSV/paquete       → imprenta            (por lote)
5. Imprimir en orden secuencial
6. Estación: grabar chip y registrar UID ↔ serial → bt_estacion_enrolar
7. Empaquetar y distribuir a comercios (solo con chip_uid)
8. El pasajero reclama en la app → ACTIVE
9. Recargar y probar el cobro
```

## 13. Referencias

- [Modelo de datos](03-modelo-de-datos.md) — tablas, restricciones y migraciones.
- [API RPC](04-api-rpc.md) — firmas de `bt_generar_lote`, `bt_estacion_enrolar`,
  `bt_crear_tarjeta_maestra`.
- [Operación y despliegue](06-operacion-y-despliegue.md) — back-office y Pages.
- [Pruebas y calidad](07-pruebas-y-calidad.md) — suite `0009_serie.sql`.
- [Riesgos y brechas](09-riesgos-y-brechas.md) — brechas frente a este estándar.
- [Manual de usuario](08-manual-de-usuario.md) — recorrido del pasajero.
