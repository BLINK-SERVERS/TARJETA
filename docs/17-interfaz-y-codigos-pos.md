# BLINK · interfaz del validador y códigos de respuesta POS

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-17 |
| Versión | 1.1.0 |
| Fecha | 2026-10-31 |
| Estado | Vigente |
| Autor | Equipo BLINK (desarrollo asistido) |
| Normas de referencia | ISO 9241 · ISO/IEC 25010 · ISO 8583 (analogía de códigos) · ISO/IEC/IEEE 26514 |

## 1. Objetivo

Contrastar la especificación externa `ISO-POS-015` —pantalla de 128×128 px y
catálogo de códigos `ISO-00` / `ERR-xx`— con el validador real, y dejar
asentado qué se adoptó, qué se adaptó y qué no aplica.

El equipo físico usa una **ST7789 de 240×240** gobernada por la librería
`Adafruit_ST7789`, no una ST7735 de 128×128, y su pantalla no solo informa la
transacción: también muestra el estado vivo del equipo (Wi-Fi, sincronización,
cola local, GPS), que el propietario pidió expresamente para operar sin
adivinar. Por eso se adopta el **lenguaje** de la especificación (códigos
estables e iconos) sin sustituir el panel de diagnóstico.

## 2. Veredicto por requisito

| Requisito de `ISO-POS-015` | Estado | Dónde |
| --- | --- | --- |
| Tres zonas (cabecera, núcleo, métricas) | Adaptado al panel de 240×240 | §3 |
| Geometría de 128×128 px | No aplica: el hardware es ST7789 240×240 | §3, ADR-12 |
| Cabecera con `BLINK` y conectividad | Cumplido (cabecera azul + franja de red) | §3 |
| Icono ✓ / ✗ y código de respuesta | Implementado 2026-10-31 (firmware 7) | §3, §4 |
| Métricas: monto y saldo en el pie | Cumplido | §3 |
| `[ISO-00]` en la aprobación | Cumplido | §4 |
| `ERR-12`, `ERR-30`, `ERR-41`, `ERR-54`, `ERR-63`, `ERR-91` | Cumplido con el mapeo de §4 | §4 |
| Multiplicador `(x2)` por multi-toque | No aplica: un toque = un pasaje | ADR-09 (DOC-16) |
| Apertura de relé | No aplica al hardware | ADR-11 (DOC-16) |
| Tiempos de retención ergonómicos | Cumplido: 2,5 s (aprobado) y 3,0 s (denegado), vuelta al panel | §5 |

## 3. Pantalla real (ST7789 240×240)

Desde el firmware 8 la interfaz sigue `ISO-UI-240-REV2`: el resultado del cobro
ocupa la pantalla completa y el reposo muestra el panel de estado vivo. El
detalle de zonas, colores y tiempos está en **BLINK-DOC-18**; aquí se resume lo
que afecta a los códigos.

| Vista | Qué se ve del código |
| --- | --- |
| Reposo | Nada: panel de diagnóstico (enlace, última tarjeta, cola, GPS y tarifa) |
| Aprobado (2,5 s) | Fondo verde, `APROBADO`, `ISO-00` al pie, monto y saldo |
| Denegado (3,0 s) | Fondo rojo, `DENEGADO`, motivo y `ERR-xx` al pie |

El motivo en pantalla y el código son el mismo mapeo de §4: la pantalla nunca
inventa un texto que el código no respalde.

El icono se traza con `drawLine` porque la fuente del panel es ASCII y no
incluye `✓` ni `✗`; no se añaden fuentes ni mapas de bits para no gastar
flash (el sketch ya usa el 93 %).

## 4. Catálogo de códigos

Los códigos son estables y salen por el puerto serie (`codigo=` en cada
`TAP`) y en la pantalla. El motivo interno sigue existiendo para diagnóstico,
pero el anfitrión debe decidir con el código.

| Código | Motivo interno | Cuándo | Pantalla | Acción |
| --- | --- | --- | --- | --- |
| `ISO-00` | *(vacío)* | Cobro aplicado y verificado | `APROBADO` + monto + saldo | Buzzer de éxito |
| `ERR-12` | `saldo` | Saldo menor que la tarifa | `SALDO INSUFICIENTE` | Recargar en el portal |
| `ERR-30` | `llave`, `lectura` | La llave derivada no autentica o el bloque no se lee | `NO LEGIBLE` | Reposicionar la tarjeta |
| `ERR-41` | `no-enrolada` | La tarjeta no tiene identidad BLINK | `NO LEGIBLE` | Tarjeta ajena al sistema |
| `ERR-54` | `bloqueada` | Estado no activo o lista negra | `BLOQUEADA` | No permitir el paso |
| `ERR-63` | `corrupta`, `valor`, `escritura`, `verificacion`, `incierta`, `recarga`, `cobro` | Integridad dudosa o estado incierto | `VERIFICAR`, `ERROR …` | Revisar el chip antes de operar |
| `ERR-91` | `tiempo` | La tarjeta dejó de responder a medio gesto | `REPITA EL TOQUE` | Retirar y volver a presentar |

Notas de mapeo:

- **`ERR-41` no bloquea una tarjeta válida.** El firmware cobra sin consultar
  la nube; una tarjeta con llaves BLINK correctas pero no registrada se cobra y
  la nube la reporta por serial. `ERR-41` es para plásticos sin identidad
  BLINK, el único caso que el equipo puede distinguir sin conexión.
- **`ERR-91` solo se emite antes de escribir.** Si el tiempo se agota durante
  el decremento, el contador o la relectura, el resultado es `ERR-63` y la
  tarjeta entra en `inciertas`, porque el equipo ya no puede asegurar si el
  chip quedó cobrado (ADR-13).
- El antiguo motivo de lectura `saldo` (bloque de valor corrupto) pasó a
  `valor` para no confundirse con `ERR-12`.

## 5. Retención y ergonomía

| Parámetro | Valor | Motivo |
| --- | --- | --- |
| Retención del aprobado | 2,5 s (`RESULTADO_OK_MS`) | Tiempo de asimilación de la especificación `ISO-UI-240-REV2` |
| Retención del denegado | 3,0 s (`RESULTADO_ERROR_MS`) | El rechazo necesita un instante más para leerse de pie |
| Vuelta al panel | Automática | La pantalla nunca queda congelada en un resultado |
| Espera | Persistente | `ACERQUE SU TARJETA` y el estado del equipo siempre visibles |
| Contraste | Fondo sólido verde/rojo con tinta contrastada | Importes en `#00331A` sobre verde (6,3:1) |
| Parpadeo | Ninguno | El aviso sonoro y el color bastan; el parpadeo cansa en cabina |

Los tiempos, la paleta y las mediciones de renderizado están en BLINK-DOC-18
§5–§7.

## 6. Protocolo serie

Los mensajes `TAP` incorporan el código; el resto del contrato no cambia.

```
TAP,ok=1,motivo=,codigo=ISO-00,uid=...,serial=...,saldo=...,monto=...,recarga=...,
    offline=...,contador=...,lat=...,lon=...,epoch=...
TAP,ok=0,motivo=saldo,codigo=ERR-12,uid=...,serial=...,saldo=...,monto=0,...
TAP,ok=0,motivo=tiempo,codigo=ERR-91,uid=...,serial=...
```

`INCIDENCIA` conserva su formato y `INFO` sigue informando `inciertas=` y
`fw=`. Un anfitrión que ignore `codigo=` sigue funcionando con `ok` y `motivo`.

## 7. Decisiones

### ADR-12 · Adoptar los códigos POS sin migrar la pantalla a 128×128

**Decisión.** Se implementa el catálogo `ISO-00` / `ERR-xx` y los iconos sobre
la ST7789 de 240×240. Desde el firmware 8 el resultado ocupa la pantalla
completa y el reposo conserva el panel de diagnóstico (ADR-14, BLINK-DOC-18).

**Motivo.** El hardware instalado no es de 128×128 y el panel de estado es un
requisito operativo del propietario (ver la red, la cola y el GPS sin consola).
La especificación `ISO-UI-240-REV2` confirma el formato de 240×240.

**Contrapartida.** La geometría exacta de `ISO-POS-015` no se replica; sí su
jerarquía, su catálogo y sus tiempos.

### ADR-13 · `ERR-91` reservado a la fase de lectura

**Decisión.** Un timeout antes de escribir se informa como `ERR-91` y no marca
la tarjeta. Un timeout durante la escritura o la verificación se informa como
`ERR-63` y la marca como incierta.

**Motivo.** Antes de tocar el bloque de valor no hay nada que reconciliar; a
partir del `Decrement`/`Transfer` el equipo no puede saber si el chip quedó
cobrado, y tratarlo como «repetir el toque» podría cobrar dos veces.

## 8. Verificación

| Fecha | Prueba | Resultado |
| --- | --- | --- |
| 2026-10-31 22:06 | Compilación del firmware 7 con códigos e iconos | 1 209 963 bytes (92 %), 51 788 bytes de RAM (15 %) |
| 2026-10-31 22:08 | Flasheo y arranque | `READY,BLINK,7,0,0`; monitor serie sin errores |
| 2026-10-31 23:31 | Firmware 8: pantalla completa y tiempos | `ms=39/vista=ok`, `ms=40/vista=no`; ver BLINK-DOC-18 §11 |
| Pendiente | Toque real con saldo | Ver `ISO-00` en pantalla y `codigo=ISO-00` en serie |
| Pendiente | Retirar la tarjeta a media lectura | Ver `ERR-91` y `REPITA EL TOQUE` |

Los códigos de rechazo se validaron por revisión del código; el toque físico y
el corte a media lectura quedan como prueba pendiente (B-23).

## 9. Límites conocidos

1. El código no se guarda en la nube: `trips_telemetry` solo recibe cobros
   aprobados. Contar rechazos por código exige columnas nuevas (B-24).
2. La geometría exacta de `ISO-POS-015` no se replica; la de
   `ISO-UI-240-REV2` sí, con las desviaciones de BLINK-DOC-18 §12.
3. El icono es un trazado de líneas, no un glifo tipográfico.
4. `ERR-41` distingue «sin identidad BLINK», no «no registrada en la nube»:
   eso solo lo sabe el servidor al sincronizar.

## 10. Referencias

- BLINK-DOC-16 (cobro offline, RAW, inciertas, ADR-09 a ADR-11).
- BLINK-DOC-18 (interfaz datáfono 240×240, ADR-14 y ADR-15).
- BLINK-DOC-07 §4.5 (prueba física), §4.6 (firmware 7) y §4.7 (firmware 8).
- `firmware/validador/README.md` (protocolo serie y códigos).
