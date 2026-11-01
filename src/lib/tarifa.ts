// Motor de cálculo tarifario (BLINK-DOC-19).
//
// El pasajero compra pasajes, no bolívares. El monto que transfiere debe
// cubrir, además del valor neto que recibe el chofer por cada viaje:
//   - la comisión que retiene el banco al recibir el Pago Móvil (entrada),
//   - la provisión para pagarle al banco al liquidar al chofer (salida),
//   - el margen de la plataforma.
//
// Como la comisión de entrada se calcula sobre el monto bruto, no se suma:
// se despeja dividiendo entre (1 - comisión). Después el resultado se eleva
// al múltiplo comercial inmediato superior para no trabajar con céntimos.

export interface ParametrosTarifarios {
  /** Valor neto de un pasaje para el chofer, en Bs. */
  base: number;
  /** Comisión del banco al recibir el Pago Móvil (0.015 = 1,5 %). */
  comisionEntrada: number;
  /** Comisión del banco al liquidar al chofer (0.003 = 0,3 %). */
  comisionSalida: number;
  /** Margen de la plataforma sobre el valor base (0.04 = 4 %). */
  margen: number;
  /** Múltiplo al que se redondea el monto a transferir (10 Bs). */
  redondeo: number;
}

export const TARIFARIO_POR_DEFECTO: ParametrosTarifarios = {
  base: 500,
  comisionEntrada: 0.015,
  comisionSalida: 0.003,
  margen: 0.04,
  redondeo: 10,
};

export interface Cotizacion {
  pasajes: number;
  /** Valor de un pasaje con el que se cotizó. */
  tarifaBase: number;
  /** Bs que se acreditan al saldo utilizable de la tarjeta. */
  acreditado: number;
  /** Monto exacto antes del redondeo comercial (informativo). */
  bruto: number;
  /** Monto final que el pasajero transfiere, múltiplo de `redondeo`. */
  total: number;
  comisionEntrada: number;
  provisionSalida: number;
  /** Margen teórico sobre el valor base (sin el excedente del redondeo). */
  margen: number;
  /** Diferencia entre el monto redondeado y el bruto exacto. */
  excedente: number;
  /** Lo que queda para la plataforma: total - neto - comisiones. */
  utilidad: number;
}

/** Convierte un porcentaje a puntos base enteros (1,5 % → 150). */
function puntosBase(proporcion: number): number {
  return Math.round(proporcion * 10000);
}

export function parametrosValidos(parametros: ParametrosTarifarios): boolean {
  return (
    Number.isFinite(parametros.base) &&
    parametros.base > 0 &&
    Number.isFinite(parametros.comisionEntrada) &&
    parametros.comisionEntrada >= 0 &&
    parametros.comisionEntrada < 1 &&
    Number.isFinite(parametros.comisionSalida) &&
    parametros.comisionSalida >= 0 &&
    Number.isFinite(parametros.margen) &&
    parametros.margen >= 0 &&
    Number.isFinite(parametros.redondeo) &&
    parametros.redondeo > 0
  );
}

/**
 * Cotiza N pasajes con la fórmula del gross-up:
 *
 *   total = ceil( N × base × (1 + salida + margen) / (1 - entrada) / redondeo ) × redondeo
 *
 * Todo se calcula en céntimos enteros para que el redondeo no dependa de la
 * representación binaria de los porcentajes.
 */
export function cotizarRecarga(
  pasajes: number,
  parametros: ParametrosTarifarios = TARIFARIO_POR_DEFECTO
): Cotizacion {
  if (!Number.isInteger(pasajes) || pasajes < 1) {
    throw new RangeError("La cantidad de pasajes debe ser un entero mayor que cero.");
  }
  if (!parametrosValidos(parametros)) {
    throw new RangeError("Los parámetros tarifarios no son válidos.");
  }

  const baseCent = Math.round(parametros.base * 100);
  const factor = 10000 + puntosBase(parametros.comisionSalida) + puntosBase(parametros.margen);
  const retencion = 10000 - puntosBase(parametros.comisionEntrada);
  const redondeoCent = Math.round(parametros.redondeo * 100);

  const acreditadoCent = baseCent * pasajes;
  // División racional: numerador y denominador enteros, sin acumular error.
  const brutoCent = (acreditadoCent * factor) / retencion;
  const escalones = Math.ceil(brutoCent / redondeoCent - 1e-9);
  const totalCent = escalones * redondeoCent;

  const comisionCent = Math.round((totalCent * puntosBase(parametros.comisionEntrada)) / 10000);
  const provisionCent = Math.round(
    (acreditadoCent * puntosBase(parametros.comisionSalida)) / 10000
  );
  const margenCent = Math.round((acreditadoCent * puntosBase(parametros.margen)) / 10000);

  return {
    pasajes,
    tarifaBase: parametros.base,
    acreditado: acreditadoCent / 100,
    bruto: Math.round(brutoCent) / 100,
    total: totalCent / 100,
    comisionEntrada: comisionCent / 100,
    provisionSalida: provisionCent / 100,
    margen: margenCent / 100,
    excedente: Math.round(totalCent - brutoCent) / 100,
    utilidad: (totalCent - acreditadoCent - comisionCent - provisionCent) / 100,
  };
}

/**
 * Mayor cantidad de pasajes cuyo monto a transferir cabe en el tope por
 * operación. Devuelve 0 si ni un pasaje cabe.
 */
export function maximoPasajes(
  tope: number,
  parametros: ParametrosTarifarios = TARIFARIO_POR_DEFECTO
): number {
  if (!Number.isFinite(tope) || tope <= 0) return 0;
  let mayor = 0;
  for (let pasajes = 1; pasajes <= 999; pasajes += 1) {
    if (cotizarRecarga(pasajes, parametros).total > tope) break;
    mayor = pasajes;
  }
  return mayor;
}
