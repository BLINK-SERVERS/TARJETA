# Enrolado y Producción de Lotes de Tarjetas

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-12 |
| Versión | 2.0.1 |
| Fecha | 2026-10-31 |
| Estado | Vigente |
| Normas | ISO/IEC 7812-1 · ISO/IEC 7064 · ISO/IEC 7810 · ISO/IEC/IEEE 26511 · 26514 |
| Público | Exclusivo del Propietario (Diego Beleño) |

## 1. Objeto

Este documento describe cómo se pasa un plástico PVC en blanco a tarjeta BLINK operativa, en qué orden, bajo qué especificaciones gráficas e industriales y cómo se comprueba que quedó correctamente grabada. Cubre dos casos:

1. **La tarjeta Alfa del propietario**, `A-00000-000-H`, asignada de forma exclusiva a Diego Beleño (`V-34201580`), que va primero y sirve de patrón de verificación del sistema.
2. **Los lotes comerciales de producción**, que utilizan la estructura `5+3` empezando en `G-00001-001-N` (General) o `E-00001-001-V` (Estudiante / Tercera Edad) y se distribuyen ya enrolados a tiendas, kioscos y comercios.

El enrolado y la asignación en taquilla quedan descartados de la arquitectura: únicamente el propietario tiene acceso a la estación de enrolado, y toda tarjeta que sale a puntos de venta comerciales lleva su `chip_uid` y bloque de identidad previamente grabados en fábrica/estación.

---

## 2. La serie de identificación (`5+3`)

### 2.1 Estructura (`T-LLLLL-UUU-V`)

```text
 G       -  00001  -  001     -  N
 │          │         │          └── Letra verificadora (Luhn Mod 23 / ISO 7064)
 │          │         └───────────── Unidad dentro del lote (3 dígitos: 001–999)
 │          └─────────────────────── Número de lote (5 dígitos: 00001–99999)
 └────────────────────────────────── Prefijo de tarifa (A = Alfa, G = General, E = Estudiante)
```

| Bloque | Caracteres | Valores permitidos | Significado y alcance |
| --- | --- | --- | --- |
| **Tarifa (`T`)** | 1 letra | `A` · `G` · `E` | `A` Alfa del propietario (`fare_type = 0`) · `G` General (`fare_type = 1`) · `E` Estudiante / 3ra Edad (`fare_type = 2`) |
| **Lote (`LLLLL`)** | 5 dígitos | `00000` · `00001`–`99999` | `00000` exclusivo para tarjeta Alfa · `00001` a `99999` para lotes comerciales (hasta 99.999 lotes) |
| **Unidad (`UUU`)** | 3 dígitos | `000` · `001`–`999` | `000` exclusivo para tarjeta Alfa · `001` a `999` para tarjetas del lote (hasta 999 unidades por lote) |
| **Verificador (`V`)** | 1 letra | `A`–`Z` *(sin `I`, `O`, `Q`)* | Letra calculada con Luhn ponderado Mod 23 sobre `T + LLLLL + UUU` |

* **Longitud impresa:** 13 caracteres con guiones (`G-00001-001-N`).
* **Longitud compacta (Chip MIFARE y Code 128):** **10 caracteres exactos (`G00001001N`)**, ocupando 10 bytes de los 11 disponibles en el bloque de identidad del firmware v4.

### 2.2 Algoritmo de la letra verificadora (Luhn Mod 23)

Para proteger tanto la letra de tarifa inicial como los 8 dígitos centrales sin almacenar el valor ASCII en la tarjeta:

1. Se toma el código ASCII de 2 dígitos de la letra inicial (`A` = `65`, `E` = `69`, `G` = `71`) y se concatena con los 8 dígitos (`LLLLLUUU`), formando una cadena numérica temporal de 10 dígitos.
2. Se recorre de derecha a izquierda aplicando el doblado de Luhn (multiplicando por 2 las posiciones impares desde la derecha: 1.ª, 3.ª, 5.ª, 7.ª y 9.ª; si el producto es mayor a 9, se le resta 9).
3. Se calcula el residuo `Suma MOD 23` y se obtiene la letra correspondiente en el alfabeto seguro de 23 letras (que excluye `I`, `O`, `Q` para evitar confusión con `1` y `0`):
   * `0:A, 1:B, 2:C, 3:D, 4:E, 5:F, 6:G, 7:H, 8:J, 9:K, 10:L, 11:M, 12:N, 13:P, 14:R, 15:S, 16:T, 17:U, 18:V, 19:W, 20:X, 21:Y, 22:Z`.

### 2.3 Ejemplos de la serie

| Serial impreso | Cadena en chip / Barcode (10 chars) | Significado |
| --- | --- | --- |
| `A-00000-000-H` | `A00000000H` | **Tarjeta Alfa exclusiva del propietario** (Diego Beleño, `V-34201580`) |
| `G-00001-001-N` | `G00001001N` | Lote `00001`, Unidad `001`, Tarifa General |
| `G-00001-002-R` | `G00001002R` | Lote `00001`, Unidad `002`, Tarifa General |
| `G-00001-020-N` | `G00001020N` | Lote `00001`, Unidad `020`, Tarifa General |
| `G-00002-001-P` | `G00002001P` | Lote `00002`, Unidad `001`, Tarifa General |
| `E-00001-001-V` | `E00001001V` | Lote `00001`, Unidad `001`, Tarifa Estudiantil / 3ra Edad |

### 2.4 La tarjeta Alfa (`A-00000-000-H`)

`A-00000-000-H` es la tarjeta personal y exclusiva del propietario del sistema (Diego Beleño, `V-34201580`):

* **No pertenece a ningún lote** (`batch_id` nulo) y `bt_generar_lote` nunca la produce: el generador de lotes solo acepta tarifas `1` (`G`) o `2` (`E`), lotes `00001`–`99999` y unidades `001`–`999`.
* **Nace activa y asignada** a la cuenta `V-34201580`, sin pasar por el estado `FABRICADA`.
* **Viaja con la tarifa general:** la tarifa `0` (`A`) identifica la jerarquía del plástico en el sistema, pero descuenta el pasaje estándar para comprobar el flujo contable real.
* **Es el patrón de verificación:** si `A-00000-000-H` cobra bien, el validador ESP32, la red y la base de datos están sanos.

### 2.5 Reglas que la base de datos hace cumplir

| Regla | Restricción / Función en PostgreSQL |
| --- | --- |
| Formato `^[AGE]-\d{5}-\d{3}-[A-HJ-NPR-Z]$` | `cards_visible_id_check` |
| Letra verificadora válida (`Luhn Mod 23`) | `bt_luhn_valido(visible_id)` |
| Reserva exclusiva de `A-00000-000-H` | Solo permitido cuando `fare_type = 0` y titular es `V-34201580` |
| Coherencia entre texto y columnas | `cards_identificador_coherente` (`fare_type`, `batch_number`, `serial_number`) |
| Serial único y código de barras único | Índices `cards_visible_id_key` y `cards_barcode_idx` |

---

## 3. Estados del plástico y flujo comercial sin taquilla

```text
   bt_generar_lote          bt_estacion_enrolar (Propietario)       Distribución comercial
 ──────────────────▶ FABRICADA (sin UID) ──────────────────▶ FABRICADA (con UID grabado)
                                                                         │
                                                                         │ Compra en Kiosco/Tienda
                                                                         │ + bt_vincular (Portal Web)
                                                                         ▼
                                            LOST ◀──────────────────── ACTIVE
                                      bt_reportar_perdida
```

| Estado | Qué significa | Quién lo ejecuta |
| --- | --- | --- |
| `FABRICADA` *(sin UID)* | Registro pre-generado en el lote para imprenta; aún no ha pasado por el lector | `bt_generar_lote` |
| `FABRICADA` *(con UID)* | Plástico grabado en la estación del propietario; **listo para venderse en tiendas y kioscos** | `bt_estacion_enrolar` (solo Propietario) |
| `ACTIVE` | Reclamo completado por el pasajero en el portal web o tarjeta Alfa del propietario | `bt_vincular` (autoservicio portal) |
| `LOST` | Reportada como extraviada; rechazada permanentemente por los validadores | `bt_reportar_perdida` |
| `BLOCKED` | Bloqueada administrativamente por auditoría o lote defectuoso | Back-office (Propietario) |

---

## 4. Especificaciones de Diseño e Imprenta PVC (Estándar CR80)

La generación en masa de cada lote depende de dos capas gráficas:
1. **Diseño frontal (Estático por tarifa):** Identidad visual BLINK según tarifa (`G` General, `E` Estudiante, `A` Alfa).
2. **Diseño de reverso (Variable por lote y unidad):** Arte publicitario del patrocinante (`sponsor_name`) combinado con los elementos dinámicos generados por el sistema (Código de barras **Code 128**, serial impreso `T-LLLLL-UUU-V` y código QR del portal).

### 4.1 Dimensiones estándar de tarjeta PVC (ISO/IEC 7810 ID-1 / CR80)

| Zona de Diseño | Milímetros (mm) | Centímetros (cm) | Pulgadas (in) | Píxeles a 300 DPI | Píxeles a 600 DPI |
| --- | --- | --- | --- | --- | --- |
| **Tamaño con Sangrado (*Bleed* +2 mm)** | $89.60 \times 57.98\text{ mm}$ | $8.96 \times 5.80\text{ cm}$ | $3.528 \times 2.283\text{"}$ | $1058 \times 685\text{ px}$ | $2116 \times 1370\text{ px}$ |
| **Tamaño Real de Corte (*Trim / CR80*)** | **$85.60 \times 53.98\text{ mm}$** | **$8.56 \times 5.40\text{ cm}$** | **$3.370 \times 2.125\text{"}$** | $1011 \times 638\text{ px}$ | $2022 \times 1276\text{ px}$ |
| **Zona Segura Interior (*Safe Margin* -3 mm)** | $79.60 \times 47.98\text{ mm}$ | $7.96 \times 4.80\text{ cm}$ | $3.134 \times 1.889\text{"}$ | $940 \times 567\text{ px}$ | $1880 \times 1134\text{ px}$ |

* **Radio de esquinas:** $3.18\text{ mm}$ ($0.125\text{"}$).
* **Formatos de subida admitidos en el Back-office:** `SVG` (vectorial recomendado), `PDF` o `PNG` a $300/600\text{ DPI}$ sin compresión con pérdida.

### 4.2 Formato de salida para la imprenta (Semiautomático sin archivos masivos)

Para evitar enviar $1.000$ archivos de imagen independientes a la imprenta y garantizar que las cajas impresas mantengan el orden estricto de la unidad `001` a la `999`:

1. **Archivo de Impresión Consolidado (`lote-00001.pdf` bajo estándar PDF/VT o PDF Multipágina con XObject):**
   * El sistema incrusta el diseño frontal y el fondo publicitario del patrocinante **una sola vez** como plantilla maestra interna, y superpone en páginas numeradas de la `001` a la `N` únicamente el vector del **Code 128** (`G00001001N`) y el texto del serial (`G-00001-001-N`).
   * Un lote de $500$ o $999$ tarjetas ocupa un único archivo PDF ligero de pocos megabytes listo para imprenta industrial PVC o pliegos A4.
2. **Archivo de Datos Variables y Control (`lote-00001.csv`):**
   * Contiene las columnas `orden_impresion, visible_id, barcode_data, sponsor_name, uid`.
   * Sirve tanto para imprentas que utilicen cabezales de inyección UV/térmica de datos variables como para alimentar la **cola secuencial de enrolado** en la estación del propietario.
3. **Optimización del Code 128 en `5+3`:**
   * La cadena sin guiones (`G00001001N`) arranca en `Code 128B` para la letra `G`, conmuta a `Code 128C` para comprimir los **8 dígitos centrales en 4 pares exactos** (`00-00-10-01`) y cierra en `Code 128B` con la letra verificadora `N`.

---

## 5. Hardware de la Estación y del Validador

| Componente | Especificación |
| --- | --- |
| **Microcontrolador** | ESP32 con firmware **v4** (con *Flash Encryption* y llaves MIFARE diversificadas por UID) |
| **Lector RFID** | Módulo MFRC522 ($13.56\text{ MHz}$, SPI) ubicado en la mitad inferior de la carcasa |
| **Pantalla integrada** | Módulo **`ZJY-1.54IPS`** ($1.54\text{"}$, panel IPS a color $240 \times 240\text{ px}$, driver ST7789 por bus SPI) ubicado en la mitad superior |
| **Carcasa proporcional** | Relación de aspecto ISO ID-1 ($1 : 1.586$), sugerida en escala $1.6\text{x}$ ($86 \times 136\text{ mm}$) con pantalla arriba y zona de contacto NFC abajo |
| **Navegador de estación** | Chrome o Edge de escritorio con API Web Serial habilitada |

---

## 6. Procedimiento A — La tarjeta Alfa del propietario (`A-00000-000-H`)

Se ejecuta **una sola vez** para dar de alta y grabar tu tarjeta personal.

### A.1 Crear o actualizar la fila en la base de datos

```sql
select public.bt_crear_tarjeta_alfa('34201580', null, 'propietario');
```

Devuelve el registro maestro activo:

```json
{
  "tarjeta": {
    "serial": "A-00000-000-H",
    "barcode": "A00000000H",
    "uid": "",
    "titular": { "nombre": "Diego Beleño", "cedula": "V-34201580" },
    "saldo": 0,
    "estado": "ACTIVE",
    "tarifa": 15
  }
}
```

### A.2 Grabar el plástico Alfa en la estación

1. En el back-office (**Estación**), conectar el ESP32 por USB y pulsar **Conectar lector**.
2. Ingresar el serial `A-00000-000-H`.
3. Apoyar tu plástico exclusivo sobre el lector MFRC522 hasta que capture el `chip_uid` y grave los 10 bytes (`A00000000H`) en el bloque de identidad.
4. Pulsar **Subir al inventario** para registrar el evento `ENROLADA` en `public.card_events`.

---

## 7. Procedimiento B — Generar e imprimir un lote comercial (`5+3`)

1. **Subir artes y crear lote en Back-office (`Lotes → Nuevo lote`):**
   * Seleccionar tarifa (`G` = `1` o `E` = `2`), cantidad ($1$ a $999$), patrocinante (`sponsor_name`), estado (`23` Zulia) y adjuntar el arte del reverso.
2. **Ejecución en base de datos (`bt_generar_lote`):**
   ```sql
   select public.bt_generar_lote(
     p_cantidad     => 200,
     p_patrocinante => 'Comercial, C.A.',
     p_estado       => 23,
     p_tarifa       => 1,
     p_origen       => 'FABRICANTE'
   );
   ```
3. **Exportación para imprenta:**
   * Descargar el paquete del lote compuesto por `lote-00001.pdf` (plantilla optimizada lista para imprenta) y `lote-00001.csv` (lista secuencial de control).

---

## 8. Procedimiento C — Enrolado secuencial en tu Estación Personal

Cuando la imprenta te entrega la caja de tarjetas físicas impresas en orden (`001` al `200`), tienes dos modos de operación en tu estación personal:

### Modo 1: Cola Secuencial Automática (*Tap & Next* — Recomendado para cajas nuevas en orden)
1. En **Estación**, seleccionar el lote (`Lote 00001`). El sistema carga en pantalla la cola ordenada empezando por `G-00001-001-N`.
2. Activar **Avance Secuencial Automático**.
3. Apoyar la primera tarjeta de la pila en el lector ESP32:
   * El ESP32 lee el `chip_uid`, deriva las llaves criptográficas del plástico, escribe `G00001001N` en el bloque de identidad y emite confirmación en la pantalla `ZJY-1.54IPS`.
   * La estación guarda el par `(G-00001-001-N, UID)` y salta automáticamente a `G-00001-002-R` sin tocar el teclado ni el lector de barras.
4. Cada 50 o 100 tarjetas, hacer una verificación visual rápida confirmando que el serial impreso en el plástico en tu mano coincide con el que pide la pantalla.

### Modo 2: Verificación Óptica por Código de Barras (Para tarjetas sueltas o re-enrolado)
1. Escanear con lector óptico el Code 128 del reverso (`G00001001N`).
2. Apoyar el plástico en el lector ESP32 para asociar y grabar su UID.
3. Al finalizar la tanda, pulsar **Subir al inventario** (`bt_estacion_enrolar`).

---

## 9. Procedimiento D — Distribución a comercios y activación por el usuario

1. **Entrega a kioscos y tiendas:** Los lotes ya enrolados (`FABRICADA` + `chip_uid` no nulo) se entregan en paquetes cerrados a los comercios afiliados.
2. **Reclamo en el portal (Autoservicio):** El pasajero compra su tarjeta física, entra a `https://blink-servers.github.io/TARJETA/` y en **Vincular tarjeta** selecciona el prefijo (`G` o `E`) e introduce los dígitos y letra verificadora.
3. **Validación instantánea:** El navegador valida localmente la letra verificadora con Luhn Mod 23 antes de enviar la petición; luego `bt_vincular` verifica que la tarjeta exista, tenga su `chip_uid` grabado y no tenga dueño, pasándola a estado `ACTIVE` en la billetera del usuario.

---

## 10. Resumen operativo

```text
1. Cuenta del propietario registrada (V-34201580)                     (una vez)
2. bt_crear_tarjeta_alfa     → A-00000-000-H (Activa y asignada)      (una vez)
3. Subir diseño + bt_generar_lote → Lote 00001 (G-00001-001-N …)      (por lote)
4. Exportar PDF/VT + CSV     → Orden única ligera para la imprenta    (por lote)
5. Estación del Propietario  → Grabado secuencial (UID ↔ Serial)      (por lote)
6. Distribución comercial    → Venta en kioscos/tiendas (ya enroladas)
7. Reclamo en Portal Web     → bt_vincular pasa la tarjeta a ACTIVE
```

**Estado del grabado físico (2026-10-31).** El paso 5 se verificó con el
validador v6 y la maestra blanca (UID `3981BF06`): la consola serie
`ENROLAR,A-00000-000-H,0,0,3981BF06,FORZAR` escribió el bloque de identidad v3,
el saldo y los sectores con sus llaves derivadas. La estación web todavía no
graba el chip (B-14); el procedimiento D sigue dependiendo de la consola serie
hasta que se conecte el lector a la interfaz. La prueba completa está en
BLINK-DOC-07 §4.4 y BLINK-DOC-15 §8.4.