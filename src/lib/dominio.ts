import type { Ajustes, Movimiento } from "./tipos";
import { soloDigitos } from "./formato";

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
 * Cédula venezolana: una letra (V, E, J, G) y entre 6 y 8 dígitos.
 * Se acepta sin letra al escribir porque la máscara la agrega sola.
 */
export function validarCedula(texto: string): string | null {
  const digitos = soloDigitos(texto);
  if (digitos.length < 6) return "La cédula debe tener al menos 6 dígitos.";
  if (digitos.length > 8) return "La cédula no puede tener más de 8 dígitos.";
  if (!/^[VEJG]-\d{6,8}$/.test(texto.toUpperCase()) && texto.trim() !== "") {
    // La máscara normaliza; si llega raro (letra en medio) se avisa.
    if (/[^0-9VEJGvejg-]/.test(texto)) return "Escribe la cédula como V-12345678.";
  }
  return null;
}

/** PIN de 4 dígitos, sin secuencias ni repeticiones obvias. */
export function validarPin(pin: string): string | null {
  if (!/^\d{4}$/.test(pin)) return "El PIN debe tener 4 dígitos.";
  if (/^(\d)\1{3}$/.test(pin)) return "No uses el mismo dígito cuatro veces.";
  const ascendente = "0123456789".includes(pin) || "9876543210".includes(pin);
  if (ascendente) return "Evita secuencias como 1234 o 9876.";
  return null;
}

/** Cuántos pasajes caben en un saldo, a la tarifa vigente. */
export function pasajesEquivalentes(saldo: number, tarifa: number): number {
  if (!Number.isFinite(tarifa) || tarifa <= 0) return 0;
  return Math.max(0, Math.floor(saldo / tarifa));
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
