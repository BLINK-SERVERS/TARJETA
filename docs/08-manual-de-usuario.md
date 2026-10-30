# Manual de usuario

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-08 |
| Versión | 1.0.0 |
| Fecha | 2026-10-29 |
| Estado | Vigente |
| Normas | ISO/IEC/IEEE 26511 · 26512 |
| Público | Pasajero, chofer, administrador de línea |

## 1. BLINK TARJETA — el pasajero

Sitio: https://blink-servers.github.io/TARJETA/

### 1.1 Crear la cuenta

1. Abre el portal y toca **Crear cuenta**.
2. **Paso 1 – Tus datos:** nombres, apellidos, cédula (elige `V` o `E`), teléfono
   móvil, correo y un **PIN de 6 dígitos**. El PIN no puede ser todo igual
   (`111111`) ni una secuencia (`123456`).
3. Toca **Continuar**.
4. **Paso 2 – Pago Móvil:** si vas a recargar con tu propio teléfono y cédula,
   elige **Sí, usar mis datos**. Si un familiar paga las recargas, elige
   **No, configurar otra cuenta** y completa banco, teléfono y cédula del titular
   de esa cuenta.
5. Al terminar entras directo a tu billetera.

> Anota tu PIN: es la única forma de entrar. Atención al cliente puede recuperarlo,
> pero no se muestra por seguridad.

### 1.2 Vincular una tarjeta

1. En el inicio toca **Vincular tarjeta** (o **Vincular mi primera tarjeta**).
2. Escribe el **serial** impreso al reverso del plástico, debajo del código de
   barras (formato `23-1-000001-9`).
3. Toca **Vincular**. Puedes repetir el proceso con la tarjeta de un hijo o de otro
   familiar: todas quedan en la misma cuenta y se deslizan en el carrusel.

Si el serial aparece como inválido, revisa que hayas copiado los 10 dígitos y los
guiones. Si dice que la tarjeta pertenece a otra cuenta, acude a taquilla.

### 1.3 Consultar saldo y movimientos

- El **inicio** muestra la tarjeta seleccionada con saldo, tarifa actual y el
  estado de sincronización.
- El ojo oculta el saldo si estás en un lugar público.
- **Movimientos** lista recargas y viajes por fecha, con banco y referencia.
- Toca la tarjeta para ver el **reverso**: código de barras, serial y QR del portal.

### 1.4 Recargar con Pago Móvil

1. Toca **Recargar** y elige un monto (o escríbelo). El tope por operación se
   muestra en pantalla (hoy Bs 5.000,00).
2. Revisa los datos de BLINK para hacer el Pago Móvil desde tu banco:
   banco, RIF, teléfono y titular. Puedes **copiarlos** con un toque.
3. Transfiere exactamente el monto indicado.
4. De vuelta en el portal, elige tu **banco emisor**, confirma el teléfono desde el
   que pagaste y escribe los **últimos 4 dígitos de la referencia**.
5. Toca **Revisar** y luego **Confirmar recarga**. Verás el comprobante en estado
   **En revisión**.
6. Cuando el administrador verifica el pago, el saldo se acredita y el movimiento
   cambia de estado. El saldo también se actualiza en el próximo tap del validador.

**Errores frecuentes**

| Mensaje | Qué hacer |
| --- | --- |
| "Ya reportaste esa referencia" | Revisa Movimientos; no envíes dos veces la misma recarga. |
| "Demasiados reportes seguidos" | Espera unos minutos antes de reportar otra. |
| "El monto mínimo es Bs 1,00" / "tope por recarga" | Ajusta el monto o divide el pago. |
| "La sesión expiró" | Vuelve a entrar con tu cédula y PIN. |

### 1.5 Cambiar el PIN o los datos de pago

- **Perfil › Seguridad › Cambiar PIN:** pide el PIN actual y el nuevo.
- **Perfil › Fuente de pago › Editar:** permite usar los datos del registro o
  configurar banco, teléfono y cédula de un familiar.

### 1.6 Cerrar sesión

En **Perfil**, al final, toca **Cerrar sesión**. La sesión también expira sola a
las 12 horas.

## 2. BLINK PASAJES — el chofer

Sitio: https://pasajes.blink.com.ve/ · Módulo **Lector**

1. Conecta el lector al puerto USB.
2. Toca **Conectar lector** y selecciona el puerto serie (solo navegadores
   Chromium en escritorio).
3. El estado debe mostrar `READY,BLINK,1`.
4. Acerca la tarjeta: el lector envía `CARD,<UID>` y el panel muestra el resultado
   del cobro (saldo, tarifa y estado).
5. Si no hay respuesta, pulsa **Probar** (envía `PING` y espera `PONG`).

Módulos **Fiscal** y **Admin** del panel muestran los totales del día y permiten
aprobar recargas y liquidar la unidad, según el rol del operador.

## 3. BLINK POS — el comercio

Sitio: https://www.blink.com.ve/

1. Crea la cuenta con correo y contraseña y confirma el código que llega al correo.
2. Inicia sesión: cada comercio ve solo sus datos.
3. Usa el menú para ventas, catálogo, caja, inventario y reportes.
4. **Instalar como app:** desde el navegador, "Añadir a la pantalla de inicio".
5. Cada 12 h se pide la sesión de nuevo por seguridad.

## 4. Administración de la línea

Tareas que hoy se hacen por RPC de servicio o consola:

| Tarea | Función |
| --- | --- |
| Ver recargas por revisar | `bt_recargas_pendientes(100)` |
| Aprobar una recarga | `bt_aprobar_recarga(<id>, 'admin')` |
| Rechazar una recarga | `bt_rechazar_recarga(<id>, 'admin', 'motivo')` |
| Emitir tarjeta | `bt_emitir_tarjeta(serial, nombre, cédula, teléfono, tarifa)` |
| Enrolar chip | `bt_enrolar_tarjeta(serial, uid)` |
| Bloquear / desbloquear | `bt_bloquear_tarjeta(serial, motivo)` / `bt_desbloquear_tarjeta(serial)` |
| Reportar pérdida | `bt_reportar_perdida(serial, motivo)` |
| Liquidar unidad | `bt_liquidar(<vehicle>, desde, hasta)` |
| Provisionar validador | `bt_validador_emitir_token(<mac>)` |

## 5. Soporte

- **Atención al cliente:** 0800-BLINK-00 (valor en `settings.publico.atencion`).
- **Recuperación de PIN:** solo presencial o por el canal de atención; el PIN no se
  envía por correo.
- **Tarjeta perdida:** el administrador la marca `LOST`; desaparece de la
  billetera y no puede cobrarse.
