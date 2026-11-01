# BLINK · cumplimiento de la especificación offline y del cobro MIFARE

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-16 |
| Versión | 1.0.0 |
| Fecha | 2026-10-31 |
| Estado | Vigente |
| Autor | Equipo BLINK (desarrollo asistido) |
| Normas de referencia | ISO/IEC 14443-3 · ISO/IEC 27001:2022 A.8 · ISO 9001 §7.5 |

## 1. Objetivo

Contrastar las dos especificaciones externas recibidas el 2026-10-31 —
«Sistema de cobro offline y persistencia de saldo en MIFARE Classic 1K» y
`ISO-SOP-014` «Arquitectura y proceso operativo» — con lo que el validador
BLINK hace realmente, registrar lo que ya estaba cumplido, lo que se
implementó ese día y lo que se decide **no** adoptar, con su motivo.

Las especificaciones son genéricas y proponen una maqueta de memoria
(sector 4, bloques 16–18), un relé de torniquete y un multi-toque acumulado
que no coinciden con el diseño vigente. Este documento es la fuente de
verdad cuando discrepan.

## 2. Veredicto por requisito

| Requisito de la especificación | Estado | Dónde |
| --- | --- | --- |
| Bloque de identidad protegido | Cumplido con otro esquema | §3, ADR-10 |
| Saldo en bloque de valor nativo MIFARE | Cumplido | `tarjeta.cpp` |
| Contador de transacciones por cobro | Cumplido (chip, telemetría y nube) | §5 |
| Autenticación con llave maestra | Cumplido con llave **derivada por tarjeta** | §3 |
| Decremento atómico + Read-After-Write | Implementado 2026-10-31 | §4.2 |
| Estado incierto y bloqueo preventivo | Implementado 2026-10-31 | §4.3 |
| Multi-pasaje por gestos en una sola operación | **No adoptado** (se cobra un pasaje por toque) | ADR-09 |
| Antirebote de 15 s para la misma tarjeta | **No adoptado** (ventana de 0,5 s) | ADR-09 |
| Relé de torniquete | No aplica al hardware actual | ADR-11 |
| HMAC parcial en bloque de seguridad | Sustituido por CRC + llave derivada | §3 |
| Subida de la cola offline por lotes | Cumplido | §5 |
| Tablas de transacciones offline y contadores | Cumplido; columna nueva `chip_counter` | §5.3 |

## 3. Mapa de memoria real

La propuesta coloca los datos en el sector 4 (bloques 16–18). BLINK usa tres
sectores distintos, elegidos para que un fallo en un sector no arrastre a los
demás y para dejar margen a futuras ampliaciones:

| Sector | Bloques | Contenido | Protección |
| --- | --- | --- | --- |
| 1 | 4 | Identidad v3: serial compacto (10 caracteres), longitud, tarifa, estado, versión y CRC-8 | Llave A derivada del UID |
| 2 | 8–10 | Bloque de valor del saldo, bloque de valor del contador y bloque de integridad con CRC-16 | Llaves A/B derivadas del UID |
| 3 | 12 | Telemetría del último viaje (unidad, fecha, monto, tarifa, firmware y CRC-16) | Llave A derivada del UID |

- **Llaves**: no hay una `Key A/B` compartida por toda la flota. Cada tarjeta
  usa `HMAC-SHA256(MASTER_KEY, UID, etiqueta)` con etiquetas distintas para ID,
  SALDO y VIAJE. Una tarjeta clonada con otro UID no acepta las llaves de la
  original.
- **Sin bloqueo permanente del bloque de identidad.** La propuesta pide
  bloquearlo con llave de fábrica. BLINK no lo hace a propósito: la maestra
  debe poder re-enrolarse (ADR-10) y el bloque queda protegido por la llave
  derivada, que un lector externo no puede calcular sin la `MASTER_KEY`.
- **Bloque de seguridad**: la propuesta pide un «HMAC parcial». Se descartó
  porque un HMAC truncado en 16 bytes sin clave por tarjeta no aporta más que
  el CRC y complica el formato. La integridad se cubre con CRC-8 del ID,
  CRC-16 del saldo+contador, CRC-16 del viaje y la autenticación Crypto1.

## 4. Ciclo de cobro

### 4.1 Un toque, un pasaje

El validador no acumula pasajes por cadencia de toques. Cada presentación de la
tarjeta lee, verifica y descuenta **un** pasaje, con confirmación en pantalla y
un `TAP,ok=1` en la cola. Para pagar dos pasajes se toca dos veces, retirando la
tarjeta entre toques. El motivo está en el ADR-09.

Cronología de un toque (v6, `REPETIR_MS = 500`):

1. `PICC_IsNewCardPresent()` + `PICC_ReadCardSerial()`.
2. Si el UID es el mismo que se acaba de cobrar y no hubo 0,8 s sin tarjeta,
   se ignora.
3. Se autentica y se lee el bloque de identidad, el saldo y el contador.
4. Se rechaza si la tarjeta está bloqueada por la nube o marcada como incierta.
5. Se aplica la recarga pendiente, si hay.
6. Se cobra con `MIFARE_Decrement` + `Transfer`, se incrementa el contador y se
   relee para verificar.
7. Se graba la telemetría del viaje (bloque 12), se emite el `TAP` y se guarda
   en la cola local.
8. `soltarTarjeta()`: `PICC_HaltA()` + `PCD_StopCrypto1()`.

### 4.2 Read-After-Write

Desde el 2026-10-31 cada cobro y cada recarga verifican en el chip:

- saldo leído == saldo anterior − tarifa (cobro) o + monto (recarga);
- contador leído == contador anterior + 1.

Si el decremento, el incremento del contador o la relectura fallan, la función
devuelve `escritura` o `verificacion`. Son errores distintos de `llave` o
`saldo`, que ocurren antes de tocar el chip.

### 4.3 Estado incierto

Un fallo de escritura o de verificación significa que el validador **no sabe**
si el chip quedó debidamente cobrado. En ese caso:

1. El serial de la tarjeta se guarda en la lista local `inciertas` (NVS, hasta
   16 tarjetas, sobrevive a reinicios).
2. Se emite `TAP,ok=0,motivo=incierta` y por serie `INCIDENCIA,serial=…,error=…`.
3. La pantalla muestra **VERIFICAR**.
4. Todo toque posterior de esa tarjeta se rechaza con el mismo motivo.

La lista **no se borra sola**: la sincronización con la nube no puede leer el
chip. Un operador debe mirar el saldo y el contador reales de la tarjeta y
enviar `LIMPIAR_INCIERTAS`. Esa desviación respecto de «hasta su
sincronización» evita que una tarjeta con el chip inconsistente vuelva a
cobrarse sola en la siguiente pasada.

## 5. Sincronización y esquema

### 5.1 Cola local y subida por lotes

Cada cobro guarda `serial|monto|saldo|offline_id|lat|lon|epoch` en la NVS. La
sincronización (`bt_validador_sincronizar_token`) envía la cola como `p_taps`,
marca las recargas ya grabadas en el chip y devuelve recargas pendientes y la
lista negra. El `offline_id` (`UID-epoch-contador-aleatorio`) es la clave de
idempotencia: reenviar el mismo lote no duplica pasajes.

### 5.2 Recargas pendientes

Las recargas aprobadas se descargan como `pendientes` y se aplican al chip en
el siguiente toque. Se acreditan en `recharges.synced_to_chip` solo después de
que el validador confirma que el bloque de valor se grabó.

### 5.3 Contador del chip en la nube (migración 0017)

`trips_telemetry.chip_counter` guarda el contador de transacciones que el chip
tenía tras el cobro. La función de sincronización no cambió: un trigger
`before insert` extrae el contador del tercer campo de `offline_id` y lo
escribe; las filas anteriores se rellenaron en la misma migración. Así se
puede auditar un salto o un retroceso (clonación o replay) con una consulta:

```sql
select card_id, chip_counter, chip_balance_after, tapped_at
  from public.trips_telemetry
 order by card_id, tapped_at;
```

## 6. Matriz de riesgos de la especificación

| Código | Riesgo | Cómo se atiende |
| --- | --- | --- |
| RSK-01 | Doble cobro accidental | La tarjeta cobrada queda en HALT y no responde hasta salir del campo; además hay una ventana de 0,5 s para el mismo UID y 0,8 s sin tarjeta antes de aceptarla de nuevo. Un toque = un pasaje, siempre visible en pantalla. |
| RSK-02 | Corte a media escritura | Bloques de valor MIFARE (operación atómica) + Read-After-Write + lista `inciertas`. |
| RSK-03 | Evasión sin saldo | El cobro solo se registra tras decremento verificado; saldo insuficiente muestra rechazo y emite error. Sin relé (ADR-11). |
| RSK-04 | Clonación de UID | La llave de cada sector se deriva del UID con la `MASTER_KEY`; un UID distinto no descifra ni autentica. El serial del bloque de identidad debe coincidir con la tarjeta registrada en la nube. |
| RSK-05 | Replay o saldo manipulado | Contador en chip verificado tras cada operación y persistido en `chip_counter`; la nube rechaza `offline_id` duplicados. |

La `MASTER_KEY` sigue siendo el punto único de confianza del firmware. Su
rotación y el re-enrolamiento de la flota están en BLINK-DOC-05 y BLINK-DOC-11.

## 7. Decisiones

### ADR-09 · Un toque, un pasaje (sin multi-toque acumulado)

**Decisión.** No se implementa el gesto «dos toques en menos de 2 s = 2
pasajes». Se cobra un pasaje por presentación y se mantiene una ventana de
0,5 s para el mismo UID.

**Motivo.** El gesto acumulado castiga justo el error que dice prevenir: un
doble toque involuntario dentro de la ventana cobra dos pasajes que el pasajero
no pidió. Cobrar por toque es determinista, cada cargo se ve en pantalla y
pagar por dos personas sigue siendo posible (dos toques). Tampoco se adopta el
antirebote de 15 s: impediría exactamente ese pago doble.

**Contrapartida.** Pagar por dos exige retirar la tarjeta entre toques durante
al menos medio segundo.

### ADR-10 · Llaves derivadas por tarjeta en lugar de bloqueo permanente

**Decisión.** El bloque de identidad no se bloquea de forma irreversible; queda
protegido por la llave derivada del UID.

**Motivo.** La tarjeta maestra debe poder re-enrolarse y la flota debe poder
migrar de formato (v1 → v2 → v3). Un bloqueo permanente convertiría cualquier
error de enrolado en plástico perdido.

**Contrapartida.** Quien conozca la `MASTER_KEY` puede reescribir cualquier
tarjeta. Es el riesgo ya registrado en BLINK-DOC-05.

### ADR-11 · Sin relé; el feedback es pantalla y buzzer

**Decisión.** El hardware actual no acciona torniquete ni puerta.

**Motivo.** El validador es una unidad de a bordo con pantalla ST7789 240×240,
buzzer y sin GPIO de potencia reservado. Añadir un relé cambia el modelo de
instalación y el consumo.

**Contrapartida.** «Cero saldo = cero acceso» depende del conductor o del
sistema de la unidad, no del validador. Queda como requisito para una futura
variante con torniquete.

## 8. Verificación

| Fecha | Prueba | Resultado |
| --- | --- | --- |
| 2026-10-31 21:41 | Dos toques separados de la maestra `A-00000-000-H`, sin reiniciar | `TAP,ok=1` ×2: 2000 → 1500 → 1000 Bs; contadores 8 y 9; dos filas en `trips_telemetry` con `chip_counter` 8 y 9 |
| 2026-10-31 21:48 | Compilación y flasheo del firmware con Read-After-Write e inciertas | 92 % flash, 15 % RAM; `READY,BLINK,6` |
| 2026-10-31 | Migración 0017 en producción | Columna, trigger y 8 filas históricas rellenadas |

Pendiente de prueba con hardware: forzar un corte a media escritura (retirar
la tarjeta durante el cobro) y comprobar que aparece `VERIFICAR` y que la
tarjeta queda en `inciertas` hasta `LIMPIAR_INCIERTAS`. También queda medir el
tiempo de cobro completo con un osciloscopio o con marcas de tiempo en serie;
la especificación pide 0,3–0,6 s y hoy solo se sabe que el toque se resuelve
antes del siguiente `SYNC` (60 s).

## 9. Límites conocidos

1. La ventana de 0,5 s y el HALT dependen de que la tarjeta salga del campo
   entre toques; una tarjeta olvidada sobre el lector no vuelve a cobrarse.
2. La lista `inciertas` se vacía a mano; no hay comando en la nube todavía.
3. El contador del chip no se valida contra una secuencia esperada en la nube:
   solo se guarda. La detección de saltos es manual o de un futuro panel fiscal.
4. El bloque de valor usa `MIFARE_Decrement`/`Increment`, atómicos en el chip,
   pero el orden «saldo, contador, telemetría» no es transaccional entre
   bloques: si falla el contador, el saldo ya cambió y la tarjeta queda
   incierta.
5. La lista negra y las recargas dependen de la nube; sin red se cobra con lo
   que ya está en la NVS.

## 10. Referencias

- BLINK-DOC-02 §7 (ADR), BLINK-DOC-05 (seguridad), BLINK-DOC-09 (riesgos),
  BLINK-DOC-12 (enrolado), BLINK-DOC-13 (operación offline).
- `firmware/validador/README.md` (mapa de bloques, Crypto1 y protocolo serie).
- Migración `0017_contador_de_chip.sql`.
