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

describe("PIN", () => {
  it("guarda un hash con sal y lo verifica", async () => {
    const guardado = await hashPin("1492");
    expect(guardado).toMatch(/^pbkdf2\$150000\$/);
    expect(guardado).not.toContain("1492");
    expect(await verificarPin("1492", guardado)).toBe(true);
    expect(await verificarPin("1493", guardado)).toBe(false);
  });

  it("usa una sal distinta cada vez", async () => {
    expect(await hashPin("1492")).not.toBe(await hashPin("1492"));
  });
});

describe("repositorio local", () => {
  it("entra con la cédula y el PIN de demostración", async () => {
    const sesion = await repositorioLocal.entrar("V-12345678", "1234");
    expect(sesion.tarjeta.serial).toBe("23-1-000001-9");
    expect(sesion.tarjeta.saldo).toBe(485);
    expect(sesion.tarjeta.titular.nombre).toContain("María");
  });

  it("no entrega la tarjeta con un PIN equivocado", async () => {
    await expect(repositorioLocal.entrar("V-12345678", "9999")).rejects.toMatchObject({
      codigo: "credenciales",
    });
  });

  it("avisa cuando la cédula no tiene tarjeta", async () => {
    await expect(repositorioLocal.entrar("V-99999999", "1234")).rejects.toMatchObject({
      codigo: "sin-tarjeta",
    });
  });

  it("lista los movimientos de la tarjeta, del más nuevo al más viejo", async () => {
    const { token } = await repositorioLocal.entrar("V-12345678", "1234");
    const movimientos = await repositorioLocal.movimientos(token);
    expect(movimientos.length).toBe(6);
    const fechas = movimientos.map((m) => new Date(m.at).getTime());
    expect([...fechas].sort((a, b) => b - a)).toEqual(fechas);
  });

  it("reporta una recarga pendiente sin tocar el saldo", async () => {
    const { token } = await repositorioLocal.entrar("V-12345678", "1234");
    const movimiento = await repositorioLocal.reportarRecarga(token, {
      monto: 150,
      telefono: "04141234567",
      banco: "Mercantil",
      referencia: "7788",
    });
    expect(movimiento.estado).toBe("pendiente");
    const tarjeta = await repositorioLocal.tarjeta(token);
    expect(tarjeta.saldo).toBe(485);
  });

  it("no acepta dos veces la misma referencia vigente", async () => {
    const { token } = await repositorioLocal.entrar("V-12345678", "1234");
    await repositorioLocal.reportarRecarga(token, {
      monto: 100,
      telefono: "04141234567",
      banco: "Mercantil",
      referencia: "7788",
    });
    await expect(
      repositorioLocal.reportarRecarga(token, {
        monto: 100,
        telefono: "04141234567",
        banco: "Mercantil",
        referencia: "7788",
      })
    ).rejects.toBeInstanceOf(ErrorBlink);
  });

  it("cambia el PIN y obliga a usar el nuevo", async () => {
    const { token } = await repositorioLocal.entrar("V-12345678", "1234");
    await repositorioLocal.cambiarPin(token, "1234", "1492");
    await expect(repositorioLocal.entrar("V-12345678", "1234")).rejects.toMatchObject({
      codigo: "credenciales",
    });
    const nueva = await repositorioLocal.entrar("V-12345678", "1492");
    expect(nueva.tarjeta.serial).toBe("23-1-000001-9");
  });

  it("cierra la sesión e invalida el token", async () => {
    const { token } = await repositorioLocal.entrar("V-12345678", "1234");
    await repositorioLocal.salir(token);
    await expect(repositorioLocal.tarjeta(token)).rejects.toMatchObject({ codigo: "sesion" });
  });
});
