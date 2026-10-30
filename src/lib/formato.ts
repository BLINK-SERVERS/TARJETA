// Formato venezolano: Bs con coma decimal, fechas cortas y máscaras.

const bs = new Intl.NumberFormat("es-VE", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const bsSinDecimales = new Intl.NumberFormat("es-VE", {
  minimumFractionDigits: 0,
  maximumFractionDigits: 0,
});

/** 12.5 → "Bs 12,50" */
export function formatearBs(monto: number): string {
  return `Bs ${bs.format(Number.isFinite(monto) ? monto : 0)}`;
}

/** 1250 → "1.250" (montos enteros para chips y resúmenes) */
export function formatearEntero(monto: number): string {
  return bsSinDecimales.format(Number.isFinite(monto) ? monto : 0);
}

/** Separa el monto para animarlo por partes: "1.234" y ",50". */
export function partesBs(monto: number): { entero: string; decimal: string } {
  const valor = Number.isFinite(monto) ? Math.abs(monto) : 0;
  const entero = Math.floor(valor);
  const decimal = Math.round((valor - entero) * 100);
  return {
    entero: bsSinDecimales.format(entero),
    decimal: String(decimal).padStart(2, "0"),
  };
}

const fechaCorta = new Intl.DateTimeFormat("es-VE", {
  day: "2-digit",
  month: "short",
});

const fechaLarga = new Intl.DateTimeFormat("es-VE", {
  day: "numeric",
  month: "long",
  year: "numeric",
});

const hora = new Intl.DateTimeFormat("es-VE", {
  hour: "2-digit",
  minute: "2-digit",
});

/** "Hoy · 08:12", "Ayer · 19:40" o "12 oct · 07:05". */
export function formatearMovimiento(at: string): string {
  const fecha = new Date(at);
  if (Number.isNaN(fecha.getTime())) return "—";
  const hoy = new Date();
  const ayer = new Date();
  ayer.setDate(hoy.getDate() - 1);
  const mismoDia = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate();

  const dia = mismoDia(fecha, hoy)
    ? "Hoy"
    : mismoDia(fecha, ayer)
      ? "Ayer"
      : fechaCorta.format(fecha).replace(".", "");
  return `${dia} · ${hora.format(fecha)}`;
}

/** "08:12", sin el día: para filas ya agrupadas por fecha. */
export function formatearHora(at: string): string {
  const fecha = new Date(at);
  if (Number.isNaN(fecha.getTime())) return "—";
  return hora.format(fecha);
}

const diaSemana = new Intl.DateTimeFormat("es-VE", {
  weekday: "long",
  day: "numeric",
  month: "long",
});

/** Encabezado de grupo del extracto: "Hoy", "Ayer", "lunes, 12 de octubre". */
export function etiquetaDia(at: string): string {
  const fecha = new Date(at);
  if (Number.isNaN(fecha.getTime())) return "Sin fecha";
  const hoy = new Date();
  const ayer = new Date();
  ayer.setDate(hoy.getDate() - 1);
  const mismoDia = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate();
  if (mismoDia(fecha, hoy)) return "Hoy";
  if (mismoDia(fecha, ayer)) return "Ayer";
  const texto = diaSemana.format(fecha);
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

export function formatearFecha(iso: string): string {
  const fecha = new Date(iso);
  return Number.isNaN(fecha.getTime()) ? "—" : fechaLarga.format(fecha);
}

/** Mes y año del vencimiento: "10/31" a la usanza de las tarjetas. */
export function formatearVence(iso: string): string {
  const fecha = new Date(iso);
  if (Number.isNaN(fecha.getTime())) return "—";
  const mes = String(fecha.getMonth() + 1).padStart(2, "0");
  const anio = String(fecha.getFullYear()).slice(-2);
  return `${mes}/${anio}`;
}

// --- Máscaras de entrada ---

export function soloDigitos(texto: string): string {
  return texto.replace(/\D/g, "");
}

/**
 * 2310000019 → 23-1-000001-9 y 23100000019 → 23-1-0000001-9
 * (estado, tarifa, secuencial y Luhn). El secuencial puede tener 6 o 7
 * dígitos, así que el grupo central se calcula por longitud.
 */
export function formatearSerial(digitos: string): string {
  const grupos = [2, 1, Math.max(1, digitos.length - 4), 1];
  let salida = "";
  let desde = 0;
  for (const tamano of grupos) {
    if (desde >= digitos.length) break;
    salida += (salida ? "-" : "") + digitos.slice(desde, desde + tamano);
    desde += tamano;
  }
  return salida;
}

/** Máscara de cédula mientras se escribe: V-12345678. */
export function formatearCedula(texto: string): string {
  const limpio = texto.replace(/[^0-9vVeEjJgG]/g, "");
  const letra = /[vVeEjJgG]/.test(limpio) ? limpio[0].toUpperCase() : "V";
  const numeros = soloDigitos(limpio).slice(0, 8);
  return numeros ? `${letra}-${numeros}` : "";
}

/** 04141234567 → 0414-1234567 */
export function formatearTelefono(texto: string): string {
  const digitos = soloDigitos(texto).slice(0, 11);
  if (digitos.length <= 4) return digitos;
  return `${digitos.slice(0, 4)}-${digitos.slice(4)}`;
}

/** Nombre del titular como se imprime en el plástico: nombre y apellido. */
export function nombreTarjeta(nombre: string): string {
  const partes = nombre.trim().split(/\s+/).filter(Boolean);
  if (partes.length <= 1) return (partes[0] ?? "").toUpperCase();
  return `${partes[0]} ${partes[partes.length - 1]}`.toUpperCase();
}

/** Iniciales para el avatar del perfil. */
export function iniciales(nombre: string): string {
  const partes = nombre.trim().split(/\s+/).filter(Boolean);
  if (partes.length === 0) return "BL";
  const primera = partes[0][0] ?? "";
  const segunda = partes.length > 1 ? partes[partes.length - 1][0] ?? "" : "";
  return (primera + segunda).toUpperCase();
}

/** "María Fernanda Fernández": nombres y apellidos de la cuenta. */
export function nombreCompleto(nombres: string, apellidos: string): string {
  return `${nombres.trim()} ${apellidos.trim()}`.trim();
}
