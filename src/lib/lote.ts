import { digitoLuhn } from "./dominio.ts";

export interface OpcionesLote {
  /** Cuántas tarjetas produce el lote (1–20000). */
  cantidad: number;
  /** Secuencial inicial dentro de la serie; si se omite, empieza en 1. */
  desde?: number;
  /** Código de entidad federal (23 = Zulia). */
  estado?: number;
  /** 1 = pasajero general, 2 = estudiante / tercera edad. */
  tarifa?: 1 | 2;
  /** Número de lote impreso en la hoja de producción. */
  lote?: number;
  patrocinante?: string;
}

export interface TarjetaLote {
  serial: string;
  /** Cadena numérica de 10 u 11 dígitos que va en el Code 128. */
  barcode: string;
}

export interface LoteGenerado {
  numero: number;
  estado: number;
  tarifa: number;
  patrocinante: string;
  cantidad: number;
  tarjetas: TarjetaLote[];
}

const ESTADO_POR_DEFECTO = 23;
const TARIFA_POR_DEFECTO = 1;
const MAXIMO_POR_LOTE = 20000;

function entero(valor: unknown, nombre: string): number {
  if (typeof valor !== "number" || !Number.isInteger(valor)) {
    throw new Error(`${nombre} debe ser un número entero.`);
  }
  return valor;
}

/**
 * 23-1-0000001-9 a partir de los 10 dígitos base (estado, tarifa y 7
 * secuenciales). También acepta bases de 9 dígitos de la serie heredada.
 */
export function serialDesdeBase(base: string): string {
  const digitos = base.replace(/\D/g, "");
  if (digitos.length !== 9 && digitos.length !== 10) {
    throw new Error("La base del ID BLINK debe tener 9 o 10 dígitos.");
  }
  const secuencial = digitos.slice(3);
  return `${digitos.slice(0, 2)}-${digitos.slice(2, 3)}-${secuencial}-${digitoLuhn(digitos)}`;
}

export function generarLote(opciones: OpcionesLote): LoteGenerado {
  const cantidad = entero(opciones.cantidad, "La cantidad");
  const estado = entero(opciones.estado ?? ESTADO_POR_DEFECTO, "El código de entidad");
  const tarifa = entero(opciones.tarifa ?? TARIFA_POR_DEFECTO, "El tipo de tarifa");
  const lote = entero(opciones.lote ?? 1, "El número de lote");
  const desde = entero(opciones.desde ?? 1, "El secuencial inicial");

  if (cantidad < 1 || cantidad > MAXIMO_POR_LOTE) {
    throw new Error(`La cantidad debe estar entre 1 y ${MAXIMO_POR_LOTE} tarjetas.`);
  }
  if (estado < 1 || estado > 99) {
    throw new Error("El código de entidad federal debe estar entre 01 y 99 (23 = Zulia).");
  }
  if (tarifa !== 1 && tarifa !== 2) {
    throw new Error("El tipo de tarifa debe ser 1 (general) o 2 (estudiante).");
  }
  if (lote < 1) {
    throw new Error("El número de lote debe ser mayor que 0.");
  }
  if (desde < 1 || desde + cantidad - 1 > 9999999) {
    throw new Error("El secuencial del lote se sale del rango 0000001–9999999.");
  }

  const prefijo = String(estado).padStart(2, "0") + String(tarifa);
  const tarjetas: TarjetaLote[] = [];

  for (let i = 0; i < cantidad; i++) {
    const secuencial = String(desde + i).padStart(7, "0");
    const serial = serialDesdeBase(prefijo + secuencial);
    tarjetas.push({ serial, barcode: serial.replace(/\D/g, "") });
  }

  return {
    numero: lote,
    estado,
    tarifa,
    patrocinante: opciones.patrocinante?.trim() ?? "",
    cantidad,
    tarjetas,
  };
}

function celdaCsv(valor: string | number): string {
  const texto = String(valor);
  return /[",\n;]/.test(texto) ? `"${texto.replace(/"/g, '""')}"` : texto;
}

/** Hoja de datos variables para el impresor y la estación de enrolado. */
export function csvLote(lote: LoteGenerado): string {
  const filas = [
    ["lote", "patrocinante", "serial", "codigo_barras", "uid", "saldo_inicial", "tarifa"],
    ...lote.tarjetas.map((t) => [
      lote.numero,
      lote.patrocinante,
      t.serial,
      t.barcode,
      "",
      0,
      lote.tarifa,
    ]),
  ];

  return filas.map((fila) => fila.map(celdaCsv).join(",")).join("\n") + "\n";
}
