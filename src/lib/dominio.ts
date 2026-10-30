import type { Ajustes, DatosPago, Movimiento } from "./tipos";
import { bancoPorNombre } from "./tipos.ts";
import { soloDigitos } from "./formato.ts";

export interface BorradorRecarga {
  monto: string;
  telefono: string;
  banco: string;
  referencia: string;
}

export type CampoRecarga = keyof BorradorRecarga;

export const CAMPOS_RECARGA: CampoRecarga[] = ["monto", "telefono", "banco", "referencia"];

export type ErroresRecarga = Partial<Record<CampoRecarga, string>>;

/**
 * Cédula del pasajero: documento V (venezolano) o E (extranjero) con 6 a 8
 * dígitos. Se acepta sin letra al escribir porque la máscara la agrega sola.
 */
export function validarCedula(texto: string): string | null {
  const digitos = soloDigitos(texto);
  if (digitos.length < 6) return "La cédula debe tener al menos 6 dígitos.";
  if (digitos.length > 8) return "La cédula no puede tener más de 8 dígitos.";
  const letra = texto.trim().charAt(0).toUpperCase();
  if (letra && letra !== "V" && letra !== "E") {
    return "Usa V para venezolano o E para extranjero.";
  }
  if (/[^0-9VE-]/.test(texto.toUpperCase())) return "Escribe la cédula como V-12345678.";
  return null;
}

/** PIN de 6 dígitos, sin secuencias ni repeticiones obvias. */
export function validarPin(pin: string): string | null {
  if (!/^\d{6}$/.test(pin)) return "El PIN debe tener 6 dígitos.";
  if (/^(\d)\1{5}$/.test(pin)) return "No uses el mismo dígito seis veces.";
  const ascendente = "0123456789";
  const descendente = "9876543210";
  for (let i = 0; i + 6 <= 10; i += 1) {
    if (ascendente.slice(i, i + 6) === pin || descendente.slice(i, i + 6) === pin) {
      return "Evita secuencias como 123456 o 987654.";
    }
  }
  return null;
}

const NOMBRE = /^\p{L}[\p{L}\s'.-]{1,59}$/u;

/** Nombres y apellidos como aparecen en la cédula. */
export function validarNombre(texto: string, campo: "nombre" | "apellido"): string | null {
  const limpio = texto.trim();
  if (!limpio) {
    return campo === "nombre" ? "Escribe tus nombres." : "Escribe tus apellidos.";
  }
  if (!NOMBRE.test(limpio)) {
    return "Solo letras, espacios, guiones y apóstrofos (2 a 60 caracteres).";
  }
  return null;
}

/** Correo para notificaciones y recuperación de acceso. */
export function validarCorreo(texto: string): string | null {
  const limpio = texto.trim();
  if (!limpio) return "Escribe un correo electrónico.";
  if (limpio.length > 120) return "El correo es demasiado largo.";
  if (!/^[^\s@]+@[^\s@]+\.[a-zA-Z]{2,}$/.test(limpio)) {
    return "Revisa el correo: falta la arroba o el dominio.";
  }
  return null;
}

/** Teléfono móvil venezolano de 11 dígitos que empieza por 0. */
export function validarTelefono(texto: string): string | null {
  if (!/^0\d{10}$/.test(soloDigitos(texto))) {
    return "Escribe el teléfono con 11 dígitos (0414-1234567).";
  }
  return null;
}

export type CampoPago = "banco" | "telefono" | "cedula";
export type ErroresPago = Partial<Record<CampoPago, string>>;

/**
 * Datos de la cuenta bancaria desde la que se fondea la billetera. El banco
 * puede quedar vacío mientras el pasajero usa los datos del registro; en la
 * recarga se le pide elegirlo.
 */
export function erroresDatosPago(datos: DatosPago): ErroresPago {
  const errores: ErroresPago = {};
  if (datos.banco && !bancoPorNombre(datos.banco)) {
    errores.banco = "Selecciona un banco del directorio oficial.";
  }
  const telefono = validarTelefono(datos.telefono);
  if (telefono) errores.telefono = telefono;
  const cedula = validarCedula(datos.cedula);
  if (cedula) errores.cedula = cedula;
  return errores;
}

/**
 * Dígito verificador del ID BLINK (ISO/IEC 7812-1). Se duplican las
 * posiciones impares contando desde la derecha del número completo, así
 * que sirve para bases de 9 dígitos (23-1-000001-9) y de 10 dígitos
 * (23-1-0000001-9).
 */
export function digitoLuhn(base: string): string {
  const digitos = soloDigitos(base);
  let suma = 0;
  for (let i = 0; i < digitos.length; i++) {
    let valor = Number(digitos[i]);
    if ((digitos.length - i) % 2 === 1) {
      valor *= 2;
      if (valor > 9) valor -= 9;
    }
    suma += valor;
  }
  return String((10 - (suma % 10)) % 10);
}

/** Serial impreso en el plástico: 10 u 11 dígitos con Luhn válido. */
export function validarSerial(texto: string): string | null {
  const digitos = soloDigitos(texto);
  if (digitos.length !== 10 && digitos.length !== 11) {
    return "El serial tiene 10 u 11 dígitos: 23-1-000001-9 o 23-1-0000001-9.";
  }
  if (digitoLuhn(digitos.slice(0, -1)) !== digitos.at(-1)) {
    return "El último dígito del serial no coincide. Revísalo en el reverso de la tarjeta.";
  }
  return null;
}

/** Cuántos pasajes caben en un saldo, a la tarifa vigente. */
export function pasajesEquivalentes(saldo: number, tarifa: number): number {
  if (!Number.isFinite(tarifa) || tarifa <= 0) return 0;
  return Math.max(0, Math.floor(saldo / tarifa));
}

export type PerfilTarifa = "GENERAL" | "ESTUDIANTE";

/**
 * El segundo grupo del serial identifica el perfil tarifario: 1 general,
 * 2 estudiante. 23-2-000001-8 sería la misma tarjeta con tarifa estudiantil.
 */
export function perfilTarifa(serial: string): PerfilTarifa {
  const grupo = soloDigitos(serial.split("-")[1] ?? "");
  return grupo === "2" ? "ESTUDIANTE" : "GENERAL";
}

/** Bs que aún alcanzan para N pasajes (para el bloque "te alcanza para"). */
export function saldoParaPasajes(saldo: number, tarifa: number, pasajes: number): boolean {
  return saldo >= tarifa * pasajes;
}

/** Errores por campo del reporte de recarga, listos para pintar bajo cada input. */
export function erroresRecarga(
  borrador: BorradorRecarga,
  ajustes: Pick<Ajustes, "topeRecarga">
): ErroresRecarga {
  const errores: ErroresRecarga = {};

  const monto = Number(borrador.monto);
  if (borrador.monto.trim() === "" || !Number.isFinite(monto) || monto <= 0) {
    errores.monto = "Escribe el monto que transferiste (mayor que 0).";
  } else if (monto < 1) {
    errores.monto = "El monto mínimo por recarga es Bs 1,00.";
  } else if (monto > ajustes.topeRecarga) {
    errores.monto = `El tope por recarga es ${new Intl.NumberFormat("es-VE").format(
      ajustes.topeRecarga
    )} Bs. Divide el pago en varias operaciones.`;
  } else if (Math.abs(monto * 100 - Math.round(monto * 100)) > 1e-6) {
    errores.monto = "Usa como máximo dos decimales.";
  }

  if (!/^0\d{10}$/.test(soloDigitos(borrador.telefono))) {
    errores.telefono = "El teléfono debe tener 11 dígitos y empezar por 0 (ej. 0414-1234567).";
  }

  if (!borrador.banco) {
    errores.banco = "Selecciona el banco emisor.";
  }

  if (!/^\d{4}$/.test(soloDigitos(borrador.referencia))) {
    errores.referencia = "Escribe los últimos 4 dígitos de la referencia.";
  }

  return errores;
}

/**
 * Un pago vigente no se puede reportar dos veces: misma referencia en el
 * mismo banco sigue pendiente o ya fue aprobado. Si fue rechazado, se
 * permite corregirlo y volver a reportar.
 */
export function buscarRecargaDuplicada(
  movimientos: Movimiento[],
  consulta: { banco: string; referencia: string }
): Movimiento | null {
  const referencia = soloDigitos(consulta.referencia).slice(-4);
  return (
    movimientos.find(
      (movimiento) =>
        movimiento.tipo === "recarga" &&
        movimiento.banco === consulta.banco &&
        movimiento.referencia === referencia &&
        movimiento.estado !== "rechazado"
    ) ?? null
  );
}
