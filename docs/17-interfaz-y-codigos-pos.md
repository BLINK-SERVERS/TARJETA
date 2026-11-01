# BLINK · interfaz del validador y códigos de respuesta POS

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-17 |
| Versión | 1.0.0 |
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
| Tiempos de retención ergonómicos | Cumplido: 5 s y vuelta a espera | §5 |

## 3. Pantalla real (ST7789 240×240)

La pantalla conserva el panel de diagnóstico y añade la lectura POS en la franja
del último toque. Zonas, de arriba abajo:

| Franja | Alto | Contenido |
| --- | --- | --- |
| Cabecera | 34 px | `BLINK` en azul corporativo, unidad y placa |
| Enlace | 24 px | Wi-Fi, IP, token, última sincronización y firmware |
| Tarjeta | 48 px | Tipo, estado, serial, saldo y UID de la última lectura |
| Resultado | 76 px | Título, **icono + código**, monto y saldo (o serial si se rechaza) |
| Cola local | 18 px | Pendientes, bloqueadas y log |
| Pie | 32 px | GPS y minutos encendido |

En la franja de resultado, la composición sigue a la especificación:

- **Aprobado**: `COBRO OK` en verde, visto bueno dibujado con líneas y
  `[ISO-00]` en letra doble, el monto debitado y el saldo restante.
- **Rechazo**: motivo en rojo, cruz y `[ERR-xx]`, el serial y, si existe, el
  saldo.
- **Espera**: `ACERCA TU TARJETA` centrado, con el estado del equipo encima.

El icono se traza con `drawLine` porque la fuente del panel es ASCII y no
incluye `✓` ni `✗`; no se añaden fuentes ni mapas de bits para no gastar
flash (el sketch ya usa el 92 %).

## 4. Catálogo de códigos

Los códigos son estables y salen por el puerto serie (`codigo=` en cada
`TAP`) y en la pantalla. El motivo interno sigue existiendo para diagnóstico,
pero el anfitrión debe decidir con el código.

| Código | Motivo interno | Cuándo | Pantalla | Acción |
| --- | --- | --- | --- | --- |
| `ISO-00` | *(vacío)* | Cobro aplicado y verificado | `COBRO OK` + monto + saldo | Buzzer de éxito |
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
| Retención del resultado | 5 s (`RESULTADO_MS`) | Se puede leer de pie, junto al conductor, sin tapar el siguiente pasaje |
| Vuelta a espera | Automática | La pantalla nunca queda congelada en un rechazo |
| Espera | Persistente | `ACERCA TU TARJETA` y el estado del equipo siempre visibles |
| Contraste | Texto claro sobre azul oscuro | Legible a plena luz y sin deslumbrar de noche |
| Parpadeo | Ninguno | El aviso sonoro y el color bastan; el parpadeo cansa en cabina |

La especificación menciona «tiempos de retención ergonómica» sin fijar cifras;
se mantiene el valor ya probado en la unidad real y se documenta aquí.

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

**Decisión.** Se implementa el catálogo `ISO-00` / `ERR-xx` y los iconos, pero
se mantiene la ST7789 240×240 con el panel de diagnóstico.

**Motivo.** El hardware instalado no es de 128×128 y el panel de estado es un
requisito operativo del propietario (ver la red, la cola y el GPS sin consola).
Reducir la interfaz a tres zonas perdería información que ya se usa a diario.

**Contrapartida.** La geometría exacta de la especificación no se replica; sí
su jerarquía, su catálogo y sus tiempos.

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
| Pendiente | Toque real con saldo | Ver `ISO-00` en pantalla y `codigo=ISO-00` en serie |
| Pendiente | Retirar la tarjeta a media lectura | Ver `ERR-91` y `REPITA EL TOQUE` |

Los códigos de rechazo se validaron por revisión del código; el toque físico y
el corte a media lectura quedan como prueba pendiente (B-23).

## 9. Límites conocidos

1. El código no se guarda en la nube: `trips_telemetry` solo recibe cobros
   aprobados. Contar rechazos por código exige columnas nuevas (B-24).
2. La pantalla no es de 128×128 ni admite la geometría exacta de la
   especificación (ADR-12).
3. El icono es un trazado de líneas de 12×12, no un glifo tipográfico.
4. `ERR-41` distingue «sin identidad BLINK», no «no registrada en la nube»:
   eso solo lo sabe el servidor al sincronizar.

## 10. Referencias

- BLINK-DOC-16 (cobro offline, RAW, inciertas, ADR-09 a ADR-11).
- BLINK-DOC-07 §4.5 (prueba física) y §4.6 (compilación del firmware 7).
- `firmware/validador/README.md` (protocolo serie y códigos).
