# Arquitectura de Seguridad Bancaria y Operación Offline (Sin Decimales) - Blink Pasajes

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-SEC-01 |
| Versión | 1.0.0 |
| Fecha | 2026-10-31 |
| Estado | Vigente |
| Normas | ISO/IEC 7812-1 · ISO/IEC 7064 · ISO/IEC 14443 · GlobalPlatform Secure Channel |
| Alcance | Firmware ESP32 (Validadores y Estación), Tarjetas MIFARE Classic 1K, Backend Central |

---

## 1. Objeto y Premisa Financiera

Este documento especifica el modelo de seguridad de grado bancario y el protocolo de lectura/escritura de saldo embarcado en el plástico (`Stored-Value Offline`). 

* **Regla Monetaria Crítica:** El sistema **no utiliza decimales** en su primera etapa operativa. Todas las tarifas, recargas y saldos se procesan y almacenan como **números enteros puros** (ejemplo: Un pasaje estándar equivale exactamente a **`500`** bolívares, reflejando el valor real pagado en efectivo). Los montos monetarios se manejan como enteros de 32 bits sin signo (`uint32_t`), eliminando errores de redondeo de punto flotante.

---

## 2. Modelo de Seguridad Bancaria (Blink Secure Core)

Para garantizar que el saldo guardado en la tarjeta y las transacciones offline no puedan ser alterados, clonados o manipulados, se implementa una arquitectura de seguridad de tres capas:

### 2.1 Llaves Criptográficas Diversificadas por UID
* Ninguna tarjeta utiliza llaves estáticas de fábrica (`FFFFFFFFFFFF`).
* Durante el proceso de enrolamiento en la estación del propietario, el sistema lee el `chip_uid` único del microchip MIFARE y aplica una función de derivación de claves (KDF) utilizando una llave maestra secreta del servidor.
* El resultado es una **llave de autenticación única (Key A / Key B)** específica para cada tarjeta. Si un atacante intenta leer o escribir el sector de saldo con un lector genérico, la autenticación del chip rechazará el acceso de inmediato.

### 2.2 Bloques de Valor Nativo (Protección de Integridad)
* El saldo no se almacena como un texto plano vulnerable. Se utilizan los **bloques de valor nativos** del chip MIFARE Classic 1K.
* Un bloque de valor almacena el entero del saldo (ej. `500`) duplicado en formato normal y negado (`~valor`), junto con un byte de dirección de control. Si el chip detecta que un bit fue alterado físicamente por un campo magnético o manipulación externa, bloquea el bloque automáticamente por corrupción de datos.

### 2.3 Contador de Transacciones y Firma Anti-Replay
* Cada tarjeta almacena un **contador secuencial de operaciones offline** (`Tx_Counter`) que se incrementa en `+1` con cada validación exitosa.
* Esto impide ataques de reutilización de paquetes (*replay attacks*), donde un dispositivo malicioso intente imitar una lectura anterior para duplicar saldo.

---

## 3. Estructura de Memoria en la Tarjeta MIFARE Classic 1K

La memoria del chip se divide en sectores protegidos por llaves diversificadas:

| Sector | Bloques | Contenido y Función Criptográfica |
| --- | --- | --- |
| **Sector 0** | Bloques 0, 1, 2 | **UID de Fábrica y Metadatos:** Solo lectura por hardware. |
| **Sector 1** | Bloques 4, 5, 6 | **Bloque de Identidad (Bloque 4):** Almacena la cadena compacta de 10 caracteres del serial (ej. `G00001001N`), protegido con llave diversificada. |
| **Sector 2** | Bloques 8, 9, 10 | **Bloque de Saldo y Contador (Bloques 8 y 9):** Formateados como bloques de valor nativo. Almacenan el saldo entero actual (`uint32_t`, ej. `5000`) y el contador de transacciones offline. |
| **Sectores 3–15** | Restantes | **Control y Expansión:** Llaves sectoriales y registros de respaldo para auditoría local. |

---

## 4. Protocolo de Lectura y Escritura Offline en el Validador ESP32

Cuando el pasajero apoya su tarjeta en el validador del autobús (sin requerir conexión a internet en ese momento), el microcontrolador ESP32 ejecuta una transacción atómica en menos de 250 milisegundos:

```text
  [ Pasajero presenta tarjeta ]
                │
                ▼
  [ Autenticación Sector 2 con Llave Diversificada ]
                │
                ▼
  [ Lectura del Bloque de Valor (Saldo Actual) ]
                │
                ├─────────────────────────────────────────┐
                ▼                                         ▼
    { Saldo < Costo Pasaje (500) }            { Saldo >= Costo Pasaje (500) }
                │                                         │
                ▼                                         ▼
    [ Rechazo Local (LED Rojo) ]              [ Ejecución Comando DECREMENT ]
                                              [ Resta exacta: -500 (Entero) ]
                                              [ Incremento Tx_Counter: +1 ]
                                                          │
                                                          ▼
                                              [ Aprobación (LED Verde) ]
```

### 4.1 Secuencia de Código en el Firmware ESP32 (Lógica de Descuento)

El proceso de escritura directa en el chip se realiza mediante las funciones seguras de la librería `MFRC522`:

```cpp
// Ejemplo conceptual de la transacción offline en el ESP32
uint32_t tarifa_pasaje = 500; // 500 bolívares exactos (sin decimales)
uint32_t saldo_actual = 0;

// 1. Autenticar sector de saldo con la llave derivada de la tarjeta
byte sector = 2;
if (autenticar_sector(sector, uid_tarjeta)) {
    
    // 2. Leer el saldo actual desde el bloque de valor (Bloque 8)
    if (mfrc522.MIFARE_ReadValue(8, &saldo_actual) == STATUS_OK) {
        
        // 3. Verificar si el saldo entero cubre la tarifa
        if (saldo_actual >= tarifa_pasaje) {
            
            // 4. Ejecutar operación atómica de decremento en el chip (-500)
            if (mfrc522.MIFARE_DecrementValue(8, tarifa_pasaje) == STATUS_OK) {
                
                // 5. Transferir el resultado al bloque de trabajo del chip
                if (mfrc522.MIFARE_TransferValue(8) == STATUS_OK) {
                    
                    // Transacción exitosa: Abrir paso y encender LED verde
                    registrar_transaccion_local_flash(uid_tarjeta, tarifa_pasaje);
                    activar_buzzer_exito();
                }
            }
        } else {
            // Fondos insuficientes: Encender LED rojo
            activar_alerta_saldo_insuficiente();
        }
    }
}
```

---

## 5. Sincronización Asíncrona Post-Ruta (*Settlement*)

* **Acumulación Local:** Todas las transacciones offline realizadas en el día se guardan de forma cifrada en la memoria Flash no volátil del ESP32 del autobús.
* **Envío al Servidor:** Tan pronto el vehículo entra en zona de cobertura 4G o se conecta a una red Wi-Fi en el terminal, el validador transmite un paquete por HTTPS (TLS 1.3 con HMAC-SHA256) hacia Supabase.
* **Consolidación Financiera:** El backend central procesa el lote de cobros enteros, actualiza los balances corporativos y compensa los pagos a los operadores de transporte sin alterar la disponibilidad inmediata del servicio para los pasajeros.