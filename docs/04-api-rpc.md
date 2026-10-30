# API de funciones RPC

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-04 |
| Versión | 1.0.0 |
| Fecha | 2026-10-29 |
| Estado | Vigente |
| Norma | ISO/IEC/IEEE 26514 |
| Transporte | PostgREST (`POST /rest/v1/rpc/<función>`) |

## 1. Contrato general

- Todas las funciones viven en el esquema `public` y son `security definer` con
  `search_path` fijo (`public` o `public, extensions`).
- El cuerpo se envía como JSON con los nombres de parámetro.
- Los errores de negocio se lanzan con el formato
  `bt:<código>:<mensaje en español>` y PostgREST los devuelve con HTTP 400.
  `bt_entrar` es la excepción: devuelve `{error, mensaje}` con HTTP 200 para poder
  **persistir el intento fallido** antes de responder.
- El cliente (`src/lib/nube.ts`) reconoce los códigos y los convierte en
  `ErrorBlink`.

### Códigos de error

| Código | Significado |
| --- | --- |
| `credenciales` | PIN incorrecto o cuenta bloqueada temporalmente. |
| `sesion` | Token ausente, inválido o vencido. |
| `sin-tarjeta` | Serial inexistente, vencido o fuera de la billetera. |
| `bloqueada` | Tarjeta o cuenta bloqueada. |
| `ya-activada` | Cédula/correo ya registrado o tarjeta de otra cuenta. |
| `duplicada` | Referencia repetida o tarjeta ya vinculada. |
| `pin-invalido` | PIN trivial o dato de recarga fuera de rango. |
| `datos` | Validación de formato (cédula, teléfono, correo, banco). |
| `red` | Error de transporte (lo genera el cliente). |

### Ejemplo de invocación

```bash
curl -sS -X POST "$VITE_SUPABASE_URL/rest/v1/rpc/bt_entrar" \
  -H "apikey: $VITE_SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $VITE_SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"p_cedula":"V-12345678","p_pin":"194628"}'
```

## 2. Portal del pasajero (ejecutable por `anon`)

| Función | Parámetros | Devuelve |
| --- | --- | --- |
| `bt_registrar` | `p_nombres, p_apellidos, p_cedula, p_telefono, p_correo, p_pin, p_pago_propio=true, p_pago_banco='', p_pago_telefono='', p_pago_cedula=''` | `{token, cuenta, tarjetas[]}` |
| `bt_entrar` | `p_cedula, p_pin` | `{token, cuenta, tarjetas[]}` o `{error, mensaje}` |
| `bt_sesion` | `p_token` | `{cuenta, tarjetas[]}` |
| `bt_vincular` | `p_token, p_serial` | Billetera actualizada |
| `bt_movimientos` | `p_token, p_serial, p_limite=100` | `{movimientos[]}` |
| `bt_recargar` | `p_token, p_serial, p_monto, p_telefono, p_banco, p_referencia` | `{movimiento}` |
| `bt_cambiar_pin` | `p_token, p_actual, p_nuevo` | `{ok:true}` |
| `bt_actualizar_pago` | `p_token, p_propio, p_banco='', p_telefono='', p_cedula=''` | `{cuenta}` |
| `bt_salir` | `p_token` | `{ok:true}` |
| `bt_ajustes` | — | Configuración pública (`settings.publico`) |

### Comportamiento por función

**`bt_registrar`**

1. Normaliza y valida nombres, cédula (`V`/`E` + 6–8 dígitos), teléfono (11 dígitos
   desde 0), correo y PIN (`bt_pin6_valido`).
2. Rechaza cédula o correo duplicados (`ya-activada`).
3. Si `p_pago_propio`, fuerza banco vacío y teléfono/cédula del registro; si no,
   exige banco, teléfono y cédula del titular de la cuenta de pago.
4. Inserta en `accounts` con bcrypt, purga sesiones vencidas y crea una nueva.
5. Devuelve token + billetera vacía.

**`bt_entrar`** — bloquea 5 minutos al quinto fallo consecutivo. Con la cuenta
bloqueada responde `credenciales` indicando los minutos restantes. Un PIN correcto
reinicia `intentos`.

**`bt_vincular`** — valida formato y Luhn del serial, existencia, vigencia, estado
`ACTIVE`, pertenencia a otra cuenta (`ya-activada`) y duplicado en la propia
billetera (`duplicada`). Al vincular, el titular visible pasa a ser el de la cuenta.

**`bt_recargar`** — valida monto (1 ≤ monto ≤ tope, dos decimales), teléfono,
banco y últimos 4 dígitos de la referencia. Limita a 6 reportes por tarjeta cada
10 minutos y rechaza referencias repetidas (`duplicada`). Crea el movimiento en
estado `pendiente` y el registro en `recharges`.

**`bt_movimientos`** — máximo 300 filas, orden descendente por fecha. Si la tarjeta
no pertenece a la cuenta responde `sin-tarjeta`.

**`bt_salir`** — elimina la sesión de cuenta y, por compatibilidad, cualquier
sesión legada de tarjeta con el mismo token.

## 3. Operación (solo `service_role`)

Estas funciones **no** están disponibles con la clave pública. Se invocan desde un
entorno de confianza (script de administración, validador con token o consola SQL).

| Función | Uso |
| --- | --- |
| `bt_emitir_tarjeta(serial, nombre, cedula, telefono, tarifa)` | Emite un plástico. |
| `bt_enrolar_tarjeta(visible_id, chip_uid)` | Asocia el UID del chip al serial. |
| `bt_generar_lote(cantidad, patrocinante, estado, tarifa)` | Genera un lote con seriales Luhn. |
| `bt_cobrar_viaje(serial, unidad, monto)` | Cobro puntual desde el validador. |
| `bt_aprobar_recarga(recarga, admin)` | Acredita saldo y marca la recarga. |
| `bt_rechazar_recarga(recarga, admin, motivo)` | Rechaza el reporte. |
| `bt_recargas_pendientes(limite)` | Lista recargas por revisar. |
| `bt_bloquear_tarjeta(serial, motivo)` / `bt_desbloquear_tarjeta(serial)` | Cambia el estado del plástico. |
| `bt_reportar_perdida(visible_id, motivo)` | Marca `LOST` y la excluye de la billetera. |
| `bt_acreditar_recarga(visible_id, monto, referencia, banco, telefono)` | Acreditación manual con traza. |
| `bt_validador_sincronizar(mac, taps, recargas)` | Sincronización legada por MAC. |
| `bt_validador_emitir_token(mac)` / `bt_validador_revocar_token(mac)` | Provisiona/revoca el token del validador. |
| `bt_validador_sincronizar_token(token, taps, recargas)` | Sincronización autenticada por token. |
| `bt_liquidar(vehicle, desde, hasta)` | Cierra el periodo de una unidad. |
| `bt_resumen_operativo()` | Totales para el panel. |

### Funciones legadas

`bt_activar`, `bt_tarjeta(token)` y `card_sessions` pertenecen al modelo anterior
(PIN por plástico). Se conservan para no romper instalaciones antiguas, pero el
portal v2 no las usa. No ampliar su alcance; retirarlas en una migración futura
cuando BLINK PASAJES migre a la cuenta.

## 4. Funciones internas (sin permisos para clientes)

`bt_pin_valido`, `bt_pin6_valido`, `bt_luhn_valido`, `bt_luhn_digito`,
`bt_solo_digitos`, `bt_normalizar_mac`, `bt_tope_recarga`, `bt_tocar_actualizada`,
`bt_estado_portal`, `bt_tarjeta_vigente`, `bt_tarjeta_json`, `bt_movimiento_json`,
`bt_cuenta_json`, `bt_tarjeta_cuenta_json`, `bt_billetera_json`,
`bt_tarjeta_de_cuenta`, `bt_sesion_cuenta`.

`revoke all` aplica a `public`, `anon` y `authenticated`. Solo se invocan desde
otras funciones `security definer`.

## 5. Forma de los objetos devueltos

```jsonc
// Billetera
{
  "cuenta": {
    "nombres": "María Fernanda", "apellidos": "Fernández",
    "cedula": "V-12345678", "telefono": "04141234567",
    "correo": "maria@correo.com",
    "datosPago": { "propio": true, "banco": "", "telefono": "04141234567", "cedula": "V-12345678" }
  },
  "tarjetas": [{
    "serial": "23-1-000001-9", "estado": "Activa", "saldo": 485,
    "tarifa": 15, "titular": { "nombre": "…", "cedula": "…", "telefono": "…" },
    "emitida": "2025-06-02T…", "vence": "2026-06-30"
  }]
}

// Movimiento
{ "tipo": "recarga", "monto": 100, "saldo": 0, "detalle": "Pago Móvil en revisión",
  "estado": "pendiente", "banco": "Banco de Venezuela", "referencia": "1177",
  "fecha": "2026-10-29T22:17:00Z" }
```

## 6. Versionado del contrato

- Añadir parámetros **con valor por defecto** al final es compatible.
- Cambiar el nombre o el tipo de un parámetro requiere:
  1. nueva función con sufijo (`_v2`) o sobrecarga,
  2. adaptar `src/lib/nube.ts` y `src/lib/local.ts`,
  3. actualizar este documento y el CHANGELOG.
- Antes de retirar una firma antigua, ejecutar
  `drop function if exists public.<nombre>(<tipos>)` en la migración nueva, como
  hizo 0005 con `bt_movimientos(text,int)` y `bt_recargar(text,numeric,text,text,text)`.
