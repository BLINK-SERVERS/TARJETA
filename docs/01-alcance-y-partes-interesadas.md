# Alcance, contexto y partes interesadas

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-01 |
| Versión | 1.0.0 |
| Fecha | 2026-10-29 |
| Estado | Vigente |
| Norma | ISO/IEC/IEEE 12207:2017 · ISO/IEC/IEEE 29148 |

## 1. Problema de negocio

Una línea de transporte urbano cobra el pasaje con tarjeta sin contacto (MIFARE
Classic 1K) y necesita:

1. **Emitir y enrolar** tarjetas con un identificador legible y verificable (ID BLINK).
2. **Cobrar** el pasaje a bordo, con o sin conexión.
3. **Recargar** el saldo sin que el pasajero tenga que ir a taquilla.
4. **Liquidar** la recaudación por unidad y por línea.
5. **Rendir** información fiscal y de operación a la autoridad.

## 2. Productos y alcance

### 2.1 BLINK POS — `www.blink.com.ve`

Punto de venta y sitio público de la línea. Incluye autenticación real contra
Supabase Auth, catálogo, ventas, caja, inventario y reportes del comercio. Sus
datos viven en `businesses` y `catalogo_global`, aislados por RLS con `auth.uid()`.

**En alcance:** operación del comercio, cuentas de usuario, catálogo, reportes.
**Fuera de alcance:** cobro del pasaje y ciclo de la tarjeta (son de TARJETA/PASAJES).

### 2.2 BLINK PASAJES — `pasajes.blink.com.ve`

Panel de la línea con cuatro módulos:

| Módulo | Función |
| --- | --- |
| **Lector** | Lee el UID del chip con Web Serial (protocolo del firmware BLINK_Lector) y muestra el resultado del cobro. |
| **Fiscal** | Reporte fiscal de la línea (número de viajes, tarifa, totales). |
| **Admin** | Aprobación de recargas, liquidación del día y gestión de tarjetas en modo local. |
| **Pasajero** | Consulta de saldo y flujo guiado de recarga. |

Estado actual: **modo local/demostración** con datos persistidos en el navegador.
La integración con la nube `bt_*` está planificada (ver BLINK-DOC-09).

### 2.3 BLINK TARJETA — `blink-servers.github.io/TARJETA/`

Portal del pasajero: registro de cuenta con PIN de 6 dígitos, vinculación de una o
varias tarjetas por serial, consulta de saldo, movimientos, reporte de recargas por
Pago Móvil y administración de la fuente de pago.

**En alcance:** identidad de la cuenta, billetera multi-tarjeta, recargas reportadas,
extracto, cambio de PIN, datos de Pago Móvil.
**Fuera de alcance:** aprobación de recargas (admin, hoy por RPC de servicio), cobro
a bordo (validador) y emisión física de plásticos.

### 2.4 Backend compartido — Supabase `gakkfzqcrapxeierfdhk`

PostgreSQL 17.11 con PostgREST, pgcrypto en el esquema `extensions` y RLS activo en
todas las tablas. Aloja el esquema de transporte (`bt_*`) y el del comercio POS.

## 3. Partes interesadas

| Parte | Interés | Cómo lo cubre el sistema |
| --- | --- | --- |
| **Pasajero** | Recargar sin ir a taquilla, consultar saldo y movimientos. | BLINK TARJETA (registro, billetera, recargas, extracto). |
| **Chofer / operador** | Cobrar rápido, con o sin internet. | Firmware BLINK_Validador + BLINK PASAJES › Lector. |
| **Administrador de la línea** | Aprobar recargas, liquidar el día, detectar fraude. | RPC de servicio + BLINK PASAJES › Admin/Fiscal. |
| **Comercio (POS)** | Vender, facturar, controlar inventario. | BLINK POS. |
| **Desarrollo / mantenimiento** | Entender, desplegar y extender. | Esta suite documental y el CHANGELOG. |
| **Autoridad fiscal** | Reportes de operación. | Telemetría `trips_telemetry` + módulo Fiscal. |

## 4. Requisitos funcionales principales

| ID | Requisito | Producto | Estado |
| --- | --- | --- | --- |
| RF-01 | Registrar una cuenta con cédula, teléfono, correo y PIN de 6 dígitos. | TARJETA | Implementado |
| RF-02 | Impedir PIN triviales (repeticiones o secuencias). | TARJETA | Implementado |
| RF-03 | Vincular N tarjetas a una cuenta por serial con Luhn. | TARJETA | Implementado |
| RF-04 | Rechazar tarjetas bloqueadas, vencidas, ya vinculadas o fuera de cartera. | TARJETA | Implementado |
| RF-05 | Reportar recarga por Pago Móvil con banco, teléfono y referencia. | TARJETA | Implementado |
| RF-06 | Evitar referencias duplicadas y limitar reportes por ráfaga. | TARJETA | Implementado |
| RF-07 | Consultar movimientos por tarjeta. | TARJETA | Implementado |
| RF-08 | Cambiar el PIN validando el actual. | TARJETA | Implementado |
| RF-09 | Cambiar la fuente de Pago Móvil (propia o de un familiar). | TARJETA | Implementado |
| RF-10 | Bloquear la cuenta 5 minutos tras 5 PIN incorrectos. | TARJETA | Implementado |
| RF-11 | Aprobar o rechazar recargas y acreditar saldo. | Admin (RPC) | Implementado |
| RF-12 | Cobrar el pasaje y sincronizar validador con token. | Validador | Implementado, sin prueba física |
| RF-13 | Operar BLINK PASAJES contra la nube compartida. | PASAJES | Pendiente |

## 5. Supuestos y restricciones

- El navegador del pasajero es **Chromium de escritorio** para Web Serial; móviles
  no soportan Web Serial, por lo que el lector solo funciona en escritorio.
- La tarjeta física es MIFARE Classic 1K; el portal debe funcionar aunque el
  pasajero no tenga lector (solo con el serial impreso).
- El monto máximo por recarga es configurable (`settings.publico.topeRecarga`,
  hoy Bs 5.000,00).
- El acceso directo a `db.<ref>.supabase.co` es IPv6; desde redes IPv4 se usa el
  pooler (`aws-0-us-east-2.pooler.supabase.com:5432`).
- Las credenciales del repositorio solo contienen claves **públicas** (publishable).

## 6. Criterios de aceptación del hito actual

1. El portal registra, vincula, muestra movimientos y reporta recargas contra la
   base real. **Verificado el 2026-10-29** (ver BLINK-DOC-07 §4).
2. La tarjeta virtual mantiene proporción ID-1/CR80 (1,586:1) y radio 3,7 % del
   ancho en cualquier viewport. **Verificado a 371, 320 y 280 px.**
3. El despliegue automático publica cada push a `main`. **Verificado.**
