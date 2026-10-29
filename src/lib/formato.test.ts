import { describe, expect, it } from "vitest";
import {
  etiquetaDia,
  formatearBs,
  formatearCedula,
  formatearSerial,
  formatearTelefono,
  formatearVence,
  iniciales,
  nombreTarjeta,
  partesBs,
} from "./formato";

describe("formato de bolívares", () => {
  it("usa coma decimal y dos decimales", () => {
    expect(formatearBs(1234.5)).toMatch(/^Bs 1\.234,50$/);
    expect(formatearBs(0)).toMatch(/^Bs 0,00$/);
  });

  it("parte el monto para animarlo", () => {
    expect(partesBs(1234.56)).toEqual({ entero: "1.234", decimal: "56" });
    expect(partesBs(0.5)).toEqual({ entero: "0", decimal: "50" });
  });

  it("no propaga valores inválidos", () => {
    expect(formatearBs(Number.NaN)).toMatch(/^Bs 0,00$/);
  });
});

describe("máscaras", () => {
  it("da formato al serial BLINK", () => {
    expect(formatearSerial("23100000010")).toBe("23-1-0000001-0");
    expect(formatearSerial("231")).toBe("23-1");
  });

  it("da formato a la cédula y respeta la letra", () => {
    expect(formatearCedula("v12345678")).toBe("V-12345678");
    expect(formatearCedula("e123")).toBe("E-123");
    expect(formatearCedula("")).toBe("");
  });

  it("da formato al teléfono venezolano", () => {
    expect(formatearTelefono("04141234567")).toBe("0414-1234567");
    expect(formatearTelefono("0414")).toBe("0414");
    expect(formatearTelefono("041412345678999")).toBe("0414-1234567");
  });
});

describe("presentación", () => {
  it("imprime el nombre como en el plástico", () => {
    expect(nombreTarjeta("María Fernanda Fernández")).toBe("MARÍA FERNÁNDEZ");
    expect(nombreTarjeta("Carlos Rondón")).toBe("CARLOS RONDÓN");
    expect(nombreTarjeta("María")).toBe("MARÍA");
  });

  it("calcula iniciales del titular", () => {
    expect(iniciales("María Fernanda Fernández")).toBe("MF");
    expect(iniciales("Carlos Rondón")).toBe("CR");
    expect(iniciales("")).toBe("BL");
  });

  it("muestra el vencimiento como la tarjeta", () => {
    expect(formatearVence("2030-03-14T12:00:00.000Z")).toMatch(/^\d{2}\/30$/);
  });

  it("agrupa el extracto por día", () => {
    const hoy = new Date();
    expect(etiquetaDia(hoy.toISOString())).toBe("Hoy");
    const ayer = new Date();
    ayer.setDate(hoy.getDate() - 1);
    expect(etiquetaDia(ayer.toISOString())).toBe("Ayer");
  });
});
