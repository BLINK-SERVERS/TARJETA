// Dominio de BLINK TARJETA: la tarjeta recargable vista por su titular.

export type EstadoTarjeta = "activa" | "bloqueada";

export interface Titular {
  nombre: string;
  cedula: string;
  telefono: string;
}

export interface Tarjeta {
  /** Serial público impreso en el plástico: 23-1-0000001-0. */
  serial: string;
  /** UID de fábrica del chip MIFARE. Viaja en cada lectura del lector. */
  uid: string;
  titular: Titular;
  saldo: number;
  estado: EstadoTarjeta;
  /** ISO de emisión y de vencimiento del plástico. */
  emitida: string;
  vence: string;
  /** Tarifa vigente del pasaje, en Bs. */
  tarifa: number;
}

export type TipoMovimiento = "recarga" | "viaje" | "devolucion" | "ajuste";

export type EstadoMovimiento = "aprobado" | "pendiente" | "rechazado";

export interface Movimiento {
  id: string;
  serial: string;
  tipo: TipoMovimiento;
  /** Bs con signo: positivo entra a la tarjeta, negativo sale. */
  monto: number;
  /** Saldo después del movimiento. En pendientes, el saldo no cambia. */
  saldoDespues: number;
  at: string;
  detalle: string;
  estado: EstadoMovimiento;
  /** Unidad de la línea que hizo el cobro, en viajes. */
  unidad?: string;
  banco?: string;
  referencia?: string;
}

export interface RecargaNueva {
  monto: number;
  telefono: string;
  banco: string;
  referencia: string;
}

/** Respuesta de entrar/activar: la tarjeta y un token de sesión. */
export interface Sesion {
  token: string;
  tarjeta: Tarjeta;
}

/** Datos de Pago Móvil que el Admin configura para recibir recargas. */
export interface DatosPagoMovil {
  banco: string;
  rif: string;
  telefono: string;
  titular: string;
}

export interface Ajustes {
  pagoMovil: DatosPagoMovil;
  /** Tope de recarga por operación, en Bs. */
  topeRecarga: number;
  /** Teléfono de atención al cliente. */
  atencion: string;
}

export const BANCOS_EMISORES = [
  "Banesco",
  "Banco de Venezuela",
  "Mercantil",
  "Provincial",
  "BNC",
  "Banplus",
  "Bancamiga",
  "Bicentenario",
  "Otro",
];

export const AJUSTES_POR_DEFECTO: Ajustes = {
  pagoMovil: {
    banco: "Banesco",
    rif: "J-00000000-0",
    telefono: "0414-0000000",
    titular: "BLINK PASAJES, C.A.",
  },
  topeRecarga: 5000,
  atencion: "0800-BLINK-00",
};
