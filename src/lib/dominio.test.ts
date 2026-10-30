import { describe, expect, it } from "vitest";
import {
  buscarRecargaDuplicada,
  erroresDatosPago,
  erroresRecarga,
  pasajesEquivalentes,
  perfilTarifa,
  saldoParaPasajes,
  digitoLuhn,
  validarCedula,
  validarCorreo,
  validarNombre,
  validarPin,
  validarSerial,
  validarTelefono,
  type BorradorRecarga,
} from "./dominio";
import type { Movimiento } from "./tipos";

const AJUSTES = { topeRecarga: 5000 };

const BUENO: BorradorRecarga = {
  monto: "200",
  telefono: "0414-1234567",
  banco: "Banesco",
  referencia: "4821",
};

function recarga(estado: Movimiento["estado"], referencia = "4821"): Movimiento {
  return {
    id: `r-${estado}`,
    serial: "23-1-000001-9",
    tipo: "recarga",
    monto: 200,
    saldoDespues: 100,
    at: new Date().toISOString(),
    detalle: "Pago Móvil",
    estado,
    banco: "Banesco",
    referencia,
  };
}

describe("validarCedula", () => {
  it("acepta cédulas V y E con 6 a 8 dígitos", () => {
    expect(validarCedula("V-12345678")).toBeNull();
    expect(validarCedula("E-123456")).toBeNull();
  });

  it("rechaza cédulas cortas o largas", () => {
    expect(validarCedula("V-12345")).toMatch(/al menos 6/);
    expect(validarCedula("V-123456789")).toMatch(/más de 8/);
  });

  it("solo admite venezolano o extranjero", () => {
    expect(validarCedula("J-1234567")).toMatch(/venezolano o E/);
  });

  it("rechaza caracteres que la máscara no admite", () => {
    expect(validarCedula("V-12a45678")).toMatch(/V-12345678/);
  });
});

describe("validarPin", () => {
  it("acepta seis dígitos sin patrón", () => {
    expect(validarPin("149205")).toBeNull();
  });

  it("rechaza repeticiones y secuencias", () => {
    expect(validarPin("111111")).toMatch(/mismo dígito/);
    expect(validarPin("123456")).toMatch(/secuencias/);
    expect(validarPin("987654")).toMatch(/secuencias/);
    expect(validarPin("12345")).toMatch(/6 dígitos/);
  });
});

describe("datos del registro", () => {
  it("valida nombres y apellidos", () => {
    expect(validarNombre("María Fernanda", "nombre")).toBeNull();
    expect(validarNombre("O'Brien", "apellido")).toBeNull();
    expect(validarNombre("", "nombre")).toMatch(/nombres/);
    expect(validarNombre("Ana3", "nombre")).toMatch(/letras/);
  });

  it("valida el correo", () => {
    expect(validarCorreo("maria@example.com")).toBeNull();
    expect(validarCorreo("maria.example.com")).toMatch(/arroba/);
    expect(validarCorreo("")).toMatch(/correo/);
  });

  it("valida el teléfono venezolano", () => {
    expect(validarTelefono("0414-1234567")).toBeNull();
    expect(validarTelefono("4141234567")).toMatch(/11 dígitos/);
  });

  it("valida la fuente de pago contra el directorio de bancos", () => {
    expect(
      erroresDatosPago({
        propio: false,
        banco: "Banesco Banco Universal",
        telefono: "04141234567",
        cedula: "V-12345678",
      })
    ).toEqual({});
    expect(
      erroresDatosPago({
        propio: false,
        banco: "Banco Inventado",
        telefono: "0414",
        cedula: "V-1",
      })
    ).toMatchObject({ banco: expect.any(String), telefono: expect.any(String), cedula: expect.any(String) });
  });
});

describe("erroresRecarga", () => {
  it("no marca nada con un reporte completo", () => {
    expect(erroresRecarga(BUENO, AJUSTES)).toEqual({});
  });

  it("valida monto, teléfono, banco y referencia por separado", () => {
    const errores = erroresRecarga(
      { monto: "", telefono: "0414", banco: "", referencia: "12" },
      AJUSTES
    );
    expect(errores.monto).toBeTruthy();
    expect(errores.telefono).toBeTruthy();
    expect(errores.banco).toBeTruthy();
    expect(errores.referencia).toBeTruthy();
  });

  it("respeta el tope por operación", () => {
    expect(erroresRecarga({ ...BUENO, monto: "6000" }, AJUSTES).monto).toMatch(/tope/);
  });

  it("no admite más de dos decimales", () => {
    expect(erroresRecarga({ ...BUENO, monto: "10.999" }, AJUSTES).monto).toMatch(/decimales/);
  });

  it("exige teléfono venezolano de 11 dígitos", () => {
    expect(erroresRecarga({ ...BUENO, telefono: "4141234567" }, AJUSTES).telefono).toBeTruthy();
  });
});

describe("buscarRecargaDuplicada", () => {
  it("encuentra una referencia vigente", () => {
    const lista = [recarga("pendiente")];
    expect(buscarRecargaDuplicada(lista, { banco: "Banesco", referencia: "4821" })).toBeTruthy();
  });

  it("deja reenviar una recarga rechazada", () => {
    const lista = [recarga("rechazado")];
    expect(buscarRecargaDuplicada(lista, { banco: "Banesco", referencia: "4821" })).toBeNull();
  });

  it("solo compara los últimos 4 dígitos", () => {
    const lista = [recarga("aprobado")];
    expect(
      buscarRecargaDuplicada(lista, { banco: "Banesco", referencia: "000004821" })
    ).toBeTruthy();
  });

  it("distingue el banco emisor", () => {
    const lista = [recarga("aprobado")];
    expect(buscarRecargaDuplicada(lista, { banco: "Mercantil", referencia: "4821" })).toBeNull();
  });
});

describe("pasajesEquivalentes", () => {
  it("calcula pasajes completos a la tarifa", () => {
    expect(pasajesEquivalentes(100, 15)).toBe(6);
    expect(pasajesEquivalentes(14.99, 15)).toBe(0);
  });

  it("no divide entre cero y no da negativos", () => {
    expect(pasajesEquivalentes(100, 0)).toBe(0);
    expect(pasajesEquivalentes(-10, 15)).toBe(0);
  });

  it("sabe si el saldo alcanza para N pasajes", () => {
    expect(saldoParaPasajes(45, 15, 3)).toBe(true);
    expect(saldoParaPasajes(44.99, 15, 3)).toBe(false);
  });
});

describe("perfilTarifa", () => {
  it("lee el perfil del segundo grupo del serial", () => {
    expect(perfilTarifa("23-1-000001-9")).toBe("GENERAL");
    expect(perfilTarifa("23-2-000001-8")).toBe("ESTUDIANTE");
  });

  it("cae en general con seriales incompletos", () => {
    expect(perfilTarifa("")).toBe("GENERAL");
    expect(perfilTarifa("23")).toBe("GENERAL");
  });
});

describe("serial BLINK", () => {
  it("calcula el dígito de Luhn de los 9 dígitos base", () => {
    expect(digitoLuhn("231000001")).toBe("9");
    expect(digitoLuhn("231000002")).toBe("7");
    expect(digitoLuhn("231000003")).toBe("5");
  });

  it("acepta seriales con verificador válido", () => {
    expect(validarSerial("23-1-000001-9")).toBeNull();
    expect(validarSerial("23-1-000002-7")).toBeNull();
    expect(validarSerial("2310000019")).toBeNull();
  });

  it("rechaza largo incorrecto o verificador que no cuadra", () => {
    expect(validarSerial("23-1-000001-0")).toMatch(/último dígito/);
    expect(validarSerial("23-1-0000001-0")).toMatch(/10 dígitos/);
    expect(validarSerial("")).toMatch(/10 dígitos/);
  });
});
