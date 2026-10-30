import { beforeEach, describe, expect, it } from "vitest";
import { hashPin, verificarPin } from "./pin";
import { ErrorBlink, repositorioLocal } from "./local";

// localStorage mínimo para probar el modo sin backend en Node.
const memoria = new Map<string, string>();

beforeEach(() => {
  memoria.clear();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (clave: string) => memoria.get(clave) ?? null,
      setItem: (clave: string, valor: string) => void memoria.set(clave, valor),
      removeItem: (clave: string) => void memoria.delete(clave),
    },
  });
});

const DEMO = { cedula: "V-12345678", pin: "194628" };

describe("PIN", () => {
  it("guarda un hash con sal y lo verifica", async () => {
    const guardado = await hashPin("149205");
    expect(guardado).toMatch(/^pbkdf2\$150000\$/);
    expect(guardado).not.toContain("149205");
    expect(await verificarPin("149205", guardado)).toBe(true);
    expect(await verificarPin("149206", guardado)).toBe(false);
  });

  it("usa una sal distinta cada vez", async () => {
    expect(await hashPin("149205")).not.toBe(await hashPin("149205"));
  });
});

describe("repositorio local", () => {
  it("entra con la cédula y el PIN de demostración", async () => {
    const sesion = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    expect(sesion.cuenta.nombres).toBe("María Fernanda");
    expect(sesion.cuenta.correo).toContain("@");
    expect(sesion.tarjetas).toHaveLength(2);
    expect(sesion.tarjetas[0].serial).toBe("23-1-000001-9");
    expect(sesion.tarjetas[0].saldo).toBe(485);
  });

  it("no entrega la cuenta con un PIN equivocado", async () => {
    await expect(repositorioLocal.entrar(DEMO.cedula, "999999")).rejects.toMatchObject({
      codigo: "credenciales",
    });
  });

  it("avisa cuando la cédula no tiene cuenta", async () => {
    await expect(repositorioLocal.entrar("V-99999999", DEMO.pin)).rejects.toMatchObject({
      codigo: "sin-tarjeta",
    });
  });

  it("lista los movimientos de una tarjeta, del más nuevo al más viejo", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    const movimientos = await repositorioLocal.movimientos(token, "23-1-000001-9");
    expect(movimientos.length).toBe(6);
    const fechas = movimientos.map((m) => new Date(m.at).getTime());
    expect([...fechas].sort((a, b) => b - a)).toEqual(fechas);
  });

  it("cada plástico conserva su propio saldo y extracto", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    const movimientos = await repositorioLocal.movimientos(token, "23-1-000004-3");
    expect(movimientos.length).toBe(3);
    expect(movimientos.every((m) => m.serial === "23-1-000004-3")).toBe(true);
    const sesion = await repositorioLocal.sesion(token);
    expect(sesion.tarjetas.find((t) => t.serial === "23-1-000004-3")?.saldo).toBe(60);
  });

  it("no deja ver una tarjeta de otra cuenta", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    await expect(repositorioLocal.movimientos(token, "23-1-000002-7")).rejects.toMatchObject({
      codigo: "sin-tarjeta",
    });
  });

  it("reporta una recarga pendiente sin tocar el saldo", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    const movimiento = await repositorioLocal.reportarRecarga(token, "23-1-000001-9", {
      monto: 150,
      telefono: "04141234567",
      banco: "Banco Mercantil",
      referencia: "7788",
    });
    expect(movimiento.estado).toBe("pendiente");
    const sesion = await repositorioLocal.sesion(token);
    expect(sesion.tarjetas.find((t) => t.serial === "23-1-000001-9")?.saldo).toBe(485);
  });

  it("no acepta dos veces la misma referencia vigente", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    await repositorioLocal.reportarRecarga(token, "23-1-000001-9", {
      monto: 100,
      telefono: "04141234567",
      banco: "Banco Mercantil",
      referencia: "7788",
    });
    await expect(
      repositorioLocal.reportarRecarga(token, "23-1-000001-9", {
        monto: 100,
        telefono: "04141234567",
        banco: "Banco Mercantil",
        referencia: "7788",
      })
    ).rejects.toBeInstanceOf(ErrorBlink);
  });

  it("cambia el PIN y obliga a usar el nuevo", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    await repositorioLocal.cambiarPin(token, DEMO.pin, "840517");
    await expect(repositorioLocal.entrar(DEMO.cedula, DEMO.pin)).rejects.toMatchObject({
      codigo: "credenciales",
    });
    const nueva = await repositorioLocal.entrar(DEMO.cedula, "840517");
    expect(nueva.tarjetas[0].serial).toBe("23-1-000001-9");
  });

  it("registra una cuenta nueva con la fuente de pago propia", async () => {
    const sesion = await repositorioLocal.registrar({
      nombres: "Ana Isabel",
      apellidos: "Gómez",
      cedula: "E-80123456",
      telefono: "04167778899",
      correo: "ana@example.com",
      pin: "615208",
      datosPago: { propio: true, banco: "", telefono: "", cedula: "" },
    });
    expect(sesion.cuenta.correo).toBe("ana@example.com");
    expect(sesion.cuenta.datosPago).toMatchObject({
      propio: true,
      telefono: "04167778899",
      cedula: "E-80123456",
    });
    expect(sesion.tarjetas).toHaveLength(0);
  });

  it("no permite dos cuentas con la misma cédula", async () => {
    const cuenta = {
      nombres: "Ana Isabel",
      apellidos: "Gómez",
      cedula: "V-80179999",
      telefono: "04167778899",
      correo: "ana@example.com",
      pin: "615208",
      datosPago: { propio: true, banco: "", telefono: "", cedula: "" },
    };
    await repositorioLocal.registrar(cuenta);
    await expect(repositorioLocal.registrar(cuenta)).rejects.toMatchObject({
      codigo: "ya-activada",
    });
  });

  it("vincula un plástico nuevo y lo deja en cero", async () => {
    const { token } = await repositorioLocal.entrar("V-87654321", DEMO.pin);
    const actualizada = await repositorioLocal.vincular(token, "23-1-000005-0");
    const nueva = actualizada.tarjetas.find((t) => t.serial === "23-1-000005-0");
    expect(nueva?.saldo).toBe(0);
    expect(nueva?.titular.nombre).toBe("Carlos Andrés Rondón");
    await expect(repositorioLocal.vincular(token, "23-1-000005-0")).rejects.toMatchObject({
      codigo: "duplicada",
    });
  });

  it("no deja apropiarse de la tarjeta de otra cuenta", async () => {
    const { token } = await repositorioLocal.entrar("V-87654321", DEMO.pin);
    await expect(repositorioLocal.vincular(token, "23-1-000001-9")).rejects.toMatchObject({
      codigo: "ya-activada",
    });
  });

  it("actualiza la fuente de pago alternativa", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    const cuenta = await repositorioLocal.actualizarPago(token, {
      propio: false,
      banco: "Banco Mercantil",
      telefono: "04129876543",
      cedula: "E-81234567",
    });
    expect(cuenta.datosPago.banco).toBe("Banco Mercantil");
    await expect(
      repositorioLocal.actualizarPago(token, {
        propio: false,
        banco: "Banco Inventado",
        telefono: "04129876543",
        cedula: "E-81234567",
      })
    ).rejects.toMatchObject({ codigo: "datos" });
  });

  it("cierra la sesión e invalida el token", async () => {
    const { token } = await repositorioLocal.entrar(DEMO.cedula, DEMO.pin);
    await repositorioLocal.salir(token);
    await expect(repositorioLocal.sesion(token)).rejects.toMatchObject({ codigo: "sesion" });
  });
});
