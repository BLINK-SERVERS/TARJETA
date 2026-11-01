import { describe, expect, it } from "vitest";
import {
  TARIFARIO_POR_DEFECTO,
  cotizarRecarga,
  maximoPasajes,
  parametrosValidos,
  type ParametrosTarifarios,
} from "./tarifa";

const CASOS = [
  { pasajes: 1, acreditado: 500, bruto: 529.44, total: 530, entrada: 7.95, salida: 1.5, utilidad: 20.55 },
  { pasajes: 2, acreditado: 1000, bruto: 1058.88, total: 1060, entrada: 15.9, salida: 3, utilidad: 41.1 },
  { pasajes: 3, acreditado: 1500, bruto: 1588.32, total: 1590, entrada: 23.85, salida: 4.5, utilidad: 61.65 },
  { pasajes: 5, acreditado: 2500, bruto: 2647.21, total: 2650, entrada: 39.75, salida: 7.5, utilidad: 102.75 },
  { pasajes: 10, acreditado: 5000, bruto: 5294.42, total: 5300, entrada: 79.5, salida: 15, utilidad: 205.5 },
  { pasajes: 20, acreditado: 10000, bruto: 10588.83, total: 10590, entrada: 158.85, salida: 30, utilidad: 401.15 },
];

describe("cotizarRecarga", () => {
  it.each(CASOS)("reproduce la tabla de validación para $pasajes pasajes", (caso) => {
    const cotizacion = cotizarRecarga(caso.pasajes);
    expect(cotizacion.acreditado).toBe(caso.acreditado);
    expect(cotizacion.bruto).toBe(caso.bruto);
    expect(cotizacion.total).toBe(caso.total);
    expect(cotizacion.comisionEntrada).toBe(caso.entrada);
    expect(cotizacion.provisionSalida).toBe(caso.salida);
    expect(cotizacion.utilidad).toBe(caso.utilidad);
  });

  it("siempre transporta un múltiplo de la decena", () => {
    for (let pasajes = 1; pasajes <= 40; pasajes += 1) {
      const { total } = cotizarRecarga(pasajes);
      expect(total % 10).toBe(0);
      expect(Number.isInteger(total)).toBe(true);
    }
  });

  it("cubre exactamente el neto, las comisiones y el margen", () => {
    for (let pasajes = 1; pasajes <= 20; pasajes += 1) {
      const c = cotizarRecarga(pasajes);
      const suma = c.acreditado + c.comisionEntrada + c.provisionSalida + c.utilidad;
      expect(Math.round(suma * 100) / 100).toBe(c.total);
      expect(c.utilidad).toBeGreaterThanOrEqual(c.margen);
    }
  });

  it("escala al alza de forma monótona", () => {
    let anterior = 0;
    for (let pasajes = 1; pasajes <= 30; pasajes += 1) {
      const { total } = cotizarRecarga(pasajes);
      expect(total).toBeGreaterThan(anterior);
      anterior = total;
    }
  });

  it("rechaza cantidades que no son enteros positivos", () => {
    expect(() => cotizarRecarga(0)).toThrow(RangeError);
    expect(() => cotizarRecarga(-1)).toThrow(RangeError);
    expect(() => cotizarRecarga(1.5)).toThrow(RangeError);
  });

  it("acepta una tarifa distinta para tarjetas de estudiante", () => {
    const estudiante: ParametrosTarifarios = { ...TARIFARIO_POR_DEFECTO, base: 250 };
    const c = cotizarRecarga(2, estudiante);
    expect(c.acreditado).toBe(500);
    expect(c.total).toBe(530);
  });

  it("valida los parámetros antes de calcular", () => {
    expect(parametrosValidos(TARIFARIO_POR_DEFECTO)).toBe(true);
    expect(parametrosValidos({ ...TARIFARIO_POR_DEFECTO, base: 0 })).toBe(false);
    expect(parametrosValidos({ ...TARIFARIO_POR_DEFECTO, comisionEntrada: 1 })).toBe(false);
    expect(parametrosValidos({ ...TARIFARIO_POR_DEFECTO, redondeo: 0 })).toBe(false);
    expect(() =>
      cotizarRecarga(1, { ...TARIFARIO_POR_DEFECTO, base: -5 })
    ).toThrow(RangeError);
  });
});

describe("maximoPasajes", () => {
  it("respeta el tope por operación", () => {
    expect(maximoPasajes(5000)).toBe(9);
    expect(maximoPasajes(20000)).toBe(37);
    expect(maximoPasajes(0)).toBe(0);
    expect(maximoPasajes(100)).toBe(0);
  });
});
