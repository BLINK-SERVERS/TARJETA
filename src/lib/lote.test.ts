import { describe, expect, it } from "vitest";
import { csvLote, generarLote, serialDesdeBase } from "./lote";
import { validarSerial } from "./dominio";

describe("serial de lote", () => {
  it("compone el ID BLINK con la letra de tarifa, lote, unidad y Luhn", () => {
    expect(serialDesdeBase("G00001001")).toBe("G-00001-001-N");
    expect(serialDesdeBase("E00001001")).toBe("E-00001-001-V");
    expect(serialDesdeBase("A00000000")).toBe("A-00000-000-H");
    expect(serialDesdeBase("G00007001")).toBe("G-00007-001-V");
  });

  it("rechaza bases con otra forma o longitud", () => {
    expect(() => serialDesdeBase("2310000001")).toThrow();
    expect(() => serialDesdeBase("G1")).toThrow();
  });
});

describe("generación de lotes", () => {
  it("produce seriales consecutivos y válidos", () => {
    const lote = generarLote({ cantidad: 5, lote: 7, patrocinante: "Lotería del Zulia" });

    expect(lote.numero).toBe(7);
    expect(lote.tarjetas).toHaveLength(5);
    expect(lote.tarjetas.map((t) => t.serial)).toEqual([
      "G-00007-001-V",
      "G-00007-002-X",
      "G-00007-003-Z",
      "G-00007-004-B",
      "G-00007-005-U",
    ]);
    for (const tarjeta of lote.tarjetas) {
      expect(validarSerial(tarjeta.serial)).toBeNull();
      expect(tarjeta.barcode).toMatch(/^G[0-9]{8}[A-Z]$/);
      expect(tarjeta.barcode).toBe(tarjeta.serial.replace(/-/g, ""));
    }
  });

  it("respeta la unidad inicial y la letra de tarifa", () => {
    const lote = generarLote({ cantidad: 2, desde: 998, tarifa: 2 });
    expect(lote.tarjetas.map((t) => t.serial.slice(0, 1))).toEqual(["E", "E"]);
    expect(lote.tarjetas.map((t) => t.serial.split("-")[2])).toEqual(["998", "999"]);
  });

  it("no permite desbordar las unidades ni cantidades absurdas", () => {
    expect(() => generarLote({ cantidad: 3, desde: 998 })).toThrow(/001 a 999/);
    expect(() => generarLote({ cantidad: 0 })).toThrow(/cantidad/);
    expect(() => generarLote({ cantidad: 1000 })).toThrow(/cantidad/);
    expect(() => generarLote({ cantidad: 1, tarifa: 3 as 1 })).toThrow(/tarifa/);
    expect(() => generarLote({ cantidad: 1, lote: 100000 })).toThrow(/lote/);
  });

  it("exporta la hoja de datos variables", () => {
    const csv = csvLote(generarLote({ cantidad: 2, patrocinante: "Comercial, C.A." }));
    const lineas = csv.trim().split("\n");
    expect(lineas[0]).toBe("lote,patrocinante,serial,codigo_barras,uid,saldo_inicial,tarifa");
    expect(lineas[1]).toBe('00001,"Comercial, C.A.",G-00001-001-N,G00001001N,,0,1');
    expect(lineas[2]).toBe('00001,"Comercial, C.A.",G-00001-002-R,G00001002R,,0,1');
  });
});
