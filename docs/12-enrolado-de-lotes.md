# Enrolado de lotes de tarjetas

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-12 |
| Versión | 1.1.0 |
| Fecha | 2026-10-30 |
| Estado | Vigente |
| Normas | ISO/IEC 7812-1 · ISO/IEC 7810 · ISO/IEC/IEEE 26511 · 26514 |
| Público | Propietario, taquilla, operador de la estación de enrolado |

## 1. Objeto

Este documento describe cómo se pasa un plástico en blanco a tarjeta BLINK
operativa, en qué orden, con qué comandos y cómo se comprueba que quedó bien.
Cubre dos casos:

1. **La tarjeta maestra del propietario**, `00-0-000000-0`, que va primero y
   sirve de patrón de verificación del sistema.
2. **Los lotes de producción**, que continúan la serie `23-1-0000001-…`
   (`23-1-0000002-…`, `23-1-0000003-…` y así sucesivamente).

El documento presupone la migración `0009_serie_siete_digitos.sql` aplicada:
es la que habilita la serie de siete dígitos y la tarjeta maestra. Ver §3.4
para lo que cambia respecto de la serie anterior de seis dígitos.

## 2. La serie de identificación

### 2.1 Estructura

```
 23      -  1     -  0000001  -  9
 │          │        │           └── verificador de Luhn (ISO/IEC 7812-1)
 │          │        └────────────── secuencial (7 dígitos; 6 en la serie heredada)
 │          └─────────────────────── tipo de tarifa
 └────────────────────────────────── código de entidad federal
```

| Bloque | Dígitos | Valores |
| --- | --- | --- |
| Entidad | 2 | `00` serie del emisor (maestra) · `23` Zulia · `01`–`99` otras entidades |
| Tarifa | 1 | `0` maestra del propietario · `1` general · `2` estudiante / tercera edad |
| Secuencial | 6 o 7 | `000001`–`999999` (heredada) · `0000001`–`9999999` (nueva) |
| Luhn | 1 | Se calcula sobre todos los dígitos anteriores |

El verificador se calcula **de derecha a izquierda**: se duplican las posiciones
pares contando desde la derecha del número completo. Así la misma regla sirve
para el serial de 10 dígitos y para el de 11.

### 2.2 Ejemplos

| Serial | Dígitos | Significado |
| --- | --- | --- |
| `00-0-000000-0` | 10 | Tarjeta maestra del propietario (serie del emisor, tarifa 0) |
| `23-1-0000001-9` | 11 | Primera tarjeta general de Zulia de la serie nueva |
| `23-1-0000002-7` | 11 | Segunda |
| `23-2-0000001-8` | 11 | Primera tarjeta estudiantil de Zulia |
| `23-1-000001-9` | 10 | Serie heredada: sigue siendo válida y legible |

### 2.3 La tarjeta maestra

`00-0-000000-0` es la tarjeta del propietario del sistema. Sus reglas son
distintas a las de un lote:

- **No pertenece a ningún lote** (`batch_id` nulo) y `bt_generar_lote` nunca la
  produce: solo acepta entidades `01`–`99` y tarifas `1` o `2`.
- **Nace activa y asignada** a la cuenta del propietario, no pasa por el estado
  `FABRICADA`.
- **Viaja con la tarifa general**: la tarifa 0 identifica el plástico, no lo
  exime del pago. Si más adelante se define una tarifa exenta, se implementa en
  el cobro y se documenta aparte.
- **Es el patrón de verificación**: si la maestra cobra bien, el validador, la
  red y la base están sanos.

### 2.4 Reglas que la base hace cumplir

| Regla | Dónde |
| --- | --- |
| Formato `^\d{2}-\d-\d{6,7}-\d$` | Restricción `cards_visible_id_check` |
| Luhn válido sobre el serial completo | Misma restricción, con `bt_luhn_valido` |
| Entidad, tarifa y serial coinciden entre columnas y texto | `cards_identificador_coherente` |
| Tarifa solo `0`, `1` o `2` | `cards_fare_type_check` |
| Serial único y código de barras único | Índices `cards_visible_id_key` y `cards_barcode_idx` |
| Una tarjeta nueva nace `FABRICADA` | `bt_generar_lote` |

## 3. Estados del plástico

```
        bt_generar_lote                bt_estacion_enrolar
  ─────────────────────▶  FABRICADA  ─────────────────────▶  (UID grabado)
                              │                                   │
                              │ bt_vincular (portal)              │ bt_estacion_asignar (taquilla)
                              ▼                                   ▼
                           ACTIVE  ◀──────────────────────────────┘
                              │
                              │ bt_reportar_perdida
                              ▼
                            LOST
```

| Estado | Qué significa | Quién lo pone |
| --- | --- | --- |
| `FABRICADA` | Existe en el inventario, sin dueño, sin UID y sin saldo | `bt_generar_lote` |
| `ACTIVE` | Tiene dueño (cuenta) | `bt_vincular` o `bt_estacion_asignar` |
| `LOST` | Reportada como perdida; ya no viaja | `bt_reportar_perdida` |
| `BLOCKED` | Bloqueada por el administrador | Back-office |

Enrolar (grabar el UID) y asignar (dar dueño) son pasos **independientes**: un
lote puede quedar completamente enrolado y seguir `FABRICADA` hasta que alguien
lo reclame.

### 3.4 Qué cambia con la migración 0009

- El serial acepta 6 o 7 dígitos secuenciales. La serie heredada de 10 dígitos
  sigue validando y sigue siendo legible por el portal y el validador.
- El lote de arranque de 20 tarjetas, que estaba sin enrolar y sin dueño, se
  renumeró a `23-1-0000001-9` … `23-1-0000020-9`. La serie nueva continúa en
  `23-1-0000021-…`.
- El **firmware del validador v4** graba el serial en un bloque de identidad
  nuevo (hasta 11 dígitos). Un validador con firmware v3 solo entiende la serie
  heredada de 10 dígitos: hay que actualizarlo antes de poner en circulación la
  serie nueva (ver §7.5).
- El Code 128 del reverso codifica la serie nueva cambiando del juego C al B en
  el último dígito; la hoja de impresión ya lo genera así.

Estado en producción al 2026-10-30, tras aplicar 0009: 21 tarjetas — la maestra
`00-0-000000-0` (`ACTIVE`, asignada al propietario, sin UID) y las 20 del lote de
arranque `23-1-0000001-9` … `23-1-0000020-9` (`FABRICADA`, sin UID). El siguiente
secuencial libre es **21**.

## 4. Requisitos previos

| Elemento | Detalle |
| --- | --- |
| Cuenta del propietario | Registrada en el portal con cédula y PIN (la maestra se asigna a ella) |
| Cuenta ADMIN | Para entrar al back-office y crear lotes |
| Back-office | `https://blink-servers.github.io/BACKOFFICE/` (o `npm run dev` en `~/BLINK_Backoffice`) |
| Validador | ESP32 con firmware **v4** y el MFRC522 conectado |
| Navegador de la estación | Chrome o Edge de escritorio: Web Serial no existe en móvil |
| Plásticos | MIFARE Classic 1K en blanco, uno por serial |
| Conexión a la base | Solo para tareas de administración (§9); el operador no la necesita |

Los plásticos deben estar **en blanco**: si un chip ya tiene datos de otra
tarjeta, el enrolado falla con «Ya está enrolada con el UID …» o «El UID ya
pertenece a otra tarjeta».

## 5. Procedimiento A — la tarjeta maestra del propietario

Se hace **una sola vez**. Dura unos 3 minutos.

> **Hecho el 2026-10-30.** La fila ya existe en producción, asignada a
> `V-34201580`, sin UID. Falta solo el paso A.2 (apoyar el plástico en el
> lector) cuando haya un validador a mano. Sirve como referencia si se instala
> otro entorno.

### A.1 Crear la fila en la base

Con la cédula de la cuenta dueña. El segundo argumento es el UID del plástico;
se puede omitir y enrolarlo después en la estación.

```sql
-- Sin UID: se enrola luego con el lector.
select public.bt_crear_tarjeta_maestra('34201580', null, 'propietario');

-- O con el UID ya conocido, si el plástico está a mano.
select public.bt_crear_tarjeta_maestra('34201580', '3981BF06', 'propietario');
```

La función devuelve la tarjeta y la cuenta:

```json
{
  "tarjeta": {
    "serial": "00-0-000000-0",
    "uid": "",
    "titular": { "nombre": "Diego Beleño", "cedula": "V-34201580" },
    "saldo": 0,
    "estado": "activa",
    "tarifa": 15
  },
  "cuenta": { "id": "…", "titular": "Diego Beleño", "cedula": "V-34201580" }
}
```

Si el serial ya existe, responde «La tarjeta maestra 00-0-000000-0 ya existe»:
no se duplica, se consulta (§9).

### A.2 Enrolar el chip (si se creó sin UID)

En el back-office, **Estación**:

1. Conectar el ESP32 y pulsar **Conectar lector**.
2. Escribir en *Serial* `00-0-000000-0`.
3. Apoyar el plástico en el lector hasta que aparezca el UID.
4. Pulsar **Agregar** y luego **Subir al inventario**.

La estación envía el par a `bt_estacion_enrolar`. Como la maestra no pertenece
a un lote, la carga se hace sin lote seleccionado.

### A.3 Verificar

```sql
select visible_id, state_code, fare_type, status, chip_uid, nombre
  from public.cards
 where visible_id = '00-0-000000-0';
```

Debe mostrar `state_code = 0`, `fare_type = 0`, `status = ACTIVE` y el UID si se
enroló. En la bitácora tienen que estar los eventos `ASIGNADA` y, si hubo UID,
`ENROLADA`:

```sql
select e.evento, e.canal, e.operador, e.at
  from public.card_events e
  join public.cards c on c.id = e.card_id
 where c.visible_id = '00-0-000000-0'
 order by e.at;
```

### A.4 Primera recarga y prueba

1. Entrar al portal con la cuenta del propietario: la maestra aparece en la
   billetera con saldo 0.
2. Reportar una recarga por Pago Móvil y aprobarla desde el back-office
   (`bt_aprobar_recarga`).
3. Pasar la maestra por el validador de una unidad: debe descontar la tarifa
   general y encender el LED verde.

## 6. Procedimiento B — pre-generar un lote

Un lote se genera **antes** de imprimir: primero existen los seriales, después
el plástico y después el UID. Cantidad razonable por tanda: 20 a 500 tarjetas.

### B.1 Desde el back-office

**Lotes → Nuevo lote**. Se indica cantidad, patrocinante (opcional), estado
(`23`) y tarifa (`1` o `2`). La respuesta trae el número de lote y los seriales
`desde`/`hasta`.

### B.2 Desde SQL (con un inicio explícito)

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

Sin `p_desde`, la función toma el siguiente secuencial libre de esa entidad y
tarifa. Si el rango se solapa con tarjetas existentes, responde «La serie 23-1
ya tiene tarjetas entre … y …» y no crea nada: es una transacción, no deja
lotes a medias.

### B.3 Con el generador de la línea de producción

```bash
cd ~/BLINK_Tarjeta
npm run lote -- --cantidad 100 --desde 21 --lote 2 \
  --patrocinante "Comercial, C.A." --tarifa 1
```

Escribe en `lotes/`:

| Archivo | Para qué |
| --- | --- |
| `lote-002.csv` | Serial, código de barras y columna `uid` vacía para la estación |
| `lote-002.html` | Hoja A4 con 8 tarjetas por página, Code 128 vertical y QR del portal |

La hoja del lote de arranque ya está generada y cuadrada contra la base:
`lotes/lote-001.csv` y `lotes/lote-001.html` cubren
`23-1-0000001-9` … `23-1-0000020-9` (3 páginas A4). Para reproducirla:

```bash
npm run lote -- --cantidad 20 --desde 1 --lote 1 --patrocinante "Arranque corporativo"
```

El CSV es la lista de contraste: cada línea debe coincidir con
`select visible_id, barcode_data from public.cards where batch_id is not null`.

Este generador es **independiente de la base**: sirve para mandar la orden al
fabricante. Si se usa junto con `bt_generar_lote`, los dos tienen que partir del
mismo `--desde`; si no, los seriales no coinciden.

### B.4 Imprimir

1. Abrir `lotes/lote-002.html` en el navegador.
2. `Ctrl+P` → tamaño A4, márgenes mínimos, sin encabezado ni pie.
3. Imprimir sobre el plástico o sobre etiqueta y adherir al reverso.
4. Comprobar una hoja con el lector de códigos: el Code 128 debe devolver los
   dígitos sin guiones (`2310000021…`).

## 7. Procedimiento C — enrolar UID y serial

Enrolar es grabar en el chip el serial impreso y las llaves derivadas del UID.
Se hace en la **estación**, con el back-office abierto en Chrome o Edge.

### C.1 Conectar el lector

1. Enchufar el ESP32 por USB.
2. **Estación → Conectar lector** y elegir el puerto.
3. El lector responde `READY,BLINK,1`. Si no aparece, revisar el cable y el
   permiso del puerto (`dialout`).

### C.2 Capturar la tanda

El ciclo por tarjeta es siempre el mismo:

1. Escanear el Code 128 del reverso en el campo *Serial impreso* (o escribirlo).
2. Apoyar el plástico en el lector hasta que aparezca el UID.
3. Pulsar *Añadir a la lista*.
4. Retirar el plástico y repetir con el siguiente.

Se pueden acumular hasta 5.000 pares antes de subir. El CSV del lote no se
importa en la estación: sirve para la impresora, para la consola serie y para
cuadrar la lista contra el inventario. Si se captura en el orden del CSV, el
serial escaneado siempre coincide con el que toca.

La pantalla muestra la lista de capturas y, al subir, el resultado por tarjeta:

```json
{ "ok": true, "enroladas": 98, "rechazadas": 2,
  "errores": [ { "serial": "23-1-0000050-4", "motivo": "El UID ya pertenece a otra tarjeta" } ] }
```

### C.3 Enrolado por consola serie (sin back-office)

El validador también acepta el comando por el puerto serie a 115200 baudios:

```
ENROLAR,23-1-0000021-7,50000,1
```

- `serial`: el ID impreso.
- `saldo`: saldo inicial en céntimos (50000 = Bs 500,00). Usar `0` en producción.
- `tarifa`: `1` general, `2` estudiante, `0` maestra.
- Un quinto campo opcional fuerza el UID esperado:
  `ENROLAR,23-1-0000021-7,0,1,3981BF06`.

Respuestas: `ENROLAR_LISTO,serial=…,uid=…` al armarse y `ENROLADA,serial=…,uid=…`
al grabar. Se desarma solo a los 60 s.

### C.4 Reglas del enrolado

| Situación | Resultado |
| --- | --- |
| Serial inexistente en la base | `Serial no registrado` |
| Serial de otro lote | `El serial no pertenece al lote` |
| Chip ya grabado con otro UID | `Ya está enrolada con el UID …` |
| UID ya usado por otra tarjeta | `El UID ya pertenece a otra tarjeta` |
| Serial con Luhn inválido | `Serial inválido` |

Un rechazo no detiene la tanda: se corrige esa fila y se vuelve a subir solo la
que falló.

## 8. Procedimiento D — entregar la tarjeta

### D.1 Reclamo desde el portal (autoservicio)

El pasajero entra a `https://blink-servers.github.io/TARJETA/`, inicia sesión y
en **Vincular tarjeta** escribe el serial del reverso. `bt_vincular` comprueba
que exista, que no tenga dueño y que no esté vencida; entonces la pasa a
`ACTIVE` y la suma a la billetera.

### D.2 Taquilla

En el back-office, **Taquilla**: serial + cédula del titular. `bt_estacion_asignar`
hace lo mismo pero con un operador identificado. Sirve cuando el pasajero no
tiene acceso al portal en ese momento.

### D.3 Qué no se puede deshacer

- Una tarjeta ya asignada **no** se transfiere a otra cuenta: hay que reportarla
  como perdida y emitir otra.
- `LOST` es irreversible desde el portal.

## 9. Procedimiento E — verificación y control

### E.1 Consultas de control

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

### E.2 Prueba de aceptación de la serie

El archivo `supabase/pruebas/0009_serie.sql` recorre en una transacción que
termina en `ROLLBACK`:

1. Luhn de la serie heredada y de la nueva.
2. Formato y verificador de todas las tarjetas almacenadas.
3. Alta de la maestra y rechazo de la duplicada.
4. Lote con inicio explícito y rechazo del solapado.
5. Enrolado de un serial de 11 dígitos y su evento en la bitácora.
6. Rechazo de la tarifa 0 en un lote.

```bash
psql "$CADENA" -v ON_ERROR_STOP=1 -f supabase/pruebas/0009_serie.sql
# NOTICE:  PRUEBAS_0009_OK
```

La suite es idempotente: si la maestra ya existe (producción), la retira dentro
de la transacción para probar el alta desde cero y el `ROLLBACK` la devuelve
intacta. Se ejecutó en producción el 2026-10-30 con `PRUEBAS_0009_OK` y sin
dejar rastro.

### E.3 Semáforo de una tarjeta lista para entregar

| Comprobación | Cómo |
| --- | --- |
| Existe y está `FABRICADA` | Consulta E.1 |
| Tiene UID | Columna `chip_uid` no nula |
| Imprime el serial correcto | Code 128 leído = dígitos del serial |
| El validador la lee | Pasar el plástico: `CARD,<uid>` y sin error |
| Tiene saldo o se recarga | Portal o taquilla |

## 10. Problemas frecuentes

| Síntoma | Causa | Solución |
| --- | --- | --- |
| `Serial inválido` | Guion de más, dígito cambiado o serie de 12 dígitos | Revisar contra el CSV del lote |
| `No encontramos ese serial` | El lote no se generó en la base | Crear el lote (§6) antes de enrolar |
| `El serial no pertenece al lote` | Se eligió otro lote en la estación | Seleccionar el lote correcto |
| `El UID ya pertenece a otra tarjeta` | El plástico se usó antes | Usar un plástico en blanco |
| El lector no aparece en el navegador | Web Serial no disponible o puerto ocupado | Chrome/Edge de escritorio, HTTPS, cerrar el monitor serie |
| `no-enrolada` al pasar la tarjeta | El chip no tiene las llaves derivadas | Volver a enrolar |
| `corrupta` al pasar la tarjeta | Bloque de identidad ilegible | Re-enrolar; si persiste, descartar el plástico |
| El lote dice «ya tiene tarjetas entre …» | El rango se solapa | Usar `p_desde` con el siguiente libre |

## 11. Trazabilidad

Cada paso queda en `public.card_events`:

| Evento | Cuándo | Canal |
| --- | --- | --- |
| `ENROLADA` | Se grabó el UID | `estacion` |
| `ASIGNADA` | Se vinculó a una cuenta | `portal` o `taquilla` |
| `PERDIDA` | Se reportó el extravío | `sistema` |

La tabla tiene RLS activo y no es legible desde el navegador: se consulta con la
conexión de administración. Es la evidencia para auditar quién enroló, quién
entregó y cuándo.

## 12. Resumen operativo

```
1. Cuenta del propietario registrada            (una vez)
2. bt_crear_tarjeta_maestra  → 00-0-000000-0    (una vez)
3. bt_generar_lote           → 23-1-0000021…    (por lote)
4. npm run lote              → CSV + hoja A4    (por lote)
5. Imprimir y adherir el reverso
6. Estación: UID ↔ serial    → bt_estacion_enrolar
7. Entregar: portal o taquilla → ACTIVE
8. Recargar y probar el cobro
```

## 13. Referencias

- [Modelo de datos](03-modelo-de-datos.md) — tablas, restricciones y migraciones.
- [API RPC](04-api-rpc.md) — firmas de `bt_generar_lote`, `bt_estacion_enrolar`,
  `bt_crear_tarjeta_maestra`.
- [Operación y despliegue](06-operacion-y-despliegue.md) — back-office y Pages.
- [Pruebas y calidad](07-pruebas-y-calidad.md) — suite `0009_serie.sql`.
- [Manual de usuario](08-manual-de-usuario.md) — recorrido del pasajero.
