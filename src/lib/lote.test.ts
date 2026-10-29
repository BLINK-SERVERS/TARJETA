import { describe, expect, it } from "vitest";
import { csvLote, generarLote, serialDesdeBase } from "./lote";
import { validarSerial } from "./dominio";

describe("serial de lote", () => {
  it("compone el ID BLINK con estado, tarifa, secuencial y Luhn", () => {
    expect(serialDesdeBase("231000001")).toBe("23-1-000001-9");
    expect(serialDesdeBase("232000001")).toBe("23-2-000001-7");
    expect(serialDesdeBase("241000001")).toBe("24-1-000001-8");
  });

  it("rechaza bases que no tienen 9 dígitos", () => {
    expect(() => serialDesdeBase("231")).toThrow();
  });
});

describe("generación de lotes", () => {
  it("produce seriales consecutivos y válidos", () => {
    const lote = generarLote({ cantidad: 5, lote: 7, patrocinante: "Lotería del Zulia" });

    expect(lote.numero).toBe(7);
    expect(lote.tarjetas).toHaveLength(5);
    expect(lote.tarjetas.map((t) => t.serial)).toEqual([
      "23-1-000001-9",
      "23-1-000002-7",
      "23-1-000003-5",
      "23-1-000004-3",
      "23-1-000005-0",
    ]);
    for (const tarjeta of lote.tarjetas) {
      expect(validarSerial(tarjeta.serial)).toBeNull();
      expect(tarjeta.barcode).toMatch(/^\d{10}$/);
      expect(tarjeta.barcode).toBe(tarjeta.serial.replace(/\D/g, ""));
    }
  });

  it("respeta el secuencial inicial y el estado", () => {
    const lote = generarLote({ cantidad: 2, desde: 999998, estado: 24, tarifa: 2 });
    expect(lote.tarjetas.map((t) => t.serial.slice(0, 4))).toEqual(["24-2", "24-2"]);
    expect(lote.tarjetas[0].serial.slice(5, 11)).toBe("999998");
    expect(lote.tarjetas[1].serial.slice(5, 11)).toBe("999999");
  });

  it("no permite desbordar el secuencial ni cantidades absurdas", () => {
    expect(() => generarLote({ cantidad: 3, desde: 999998 })).toThrow(/rango/);
    expect(() => generarLote({ cantidad: 0 })).toThrow(/cantidad/);
    expect(() => generarLote({ cantidad: 20001 })).toThrow(/cantidad/);
    expect(() => generarLote({ cantidad: 1, tarifa: 3 as 1 })).toThrow(/tarifa/);
  });

  it("exporta la hoja de datos variables", () => {
    const csv = csvLote(generarLote({ cantidad: 2, patrocinante: "Comercial, C.A." }));
    const lineas = csv.trim().split("\n");
    expect(lineas[0]).toBe("lote,patrocinante,serial,codigo_barras,uid,saldo_inicial,tarifa");
    expect(lineas[1]).toBe('1,"Comercial, C.A.",23-1-000001-9,2310000019,,0,1');
    expect(lineas[2]).toBe('1,"Comercial, C.A.",23-1-000002-7,2310000027,,0,1');
  });
});
