import type { Cuenta, Movimiento, Sesion, Tarjeta } from "./tipos";

// Copia local de la última billetera verificada por el servidor. Permite
// abrir la tarjeta y ver el saldo sin red; las operaciones que escriben
// siguen necesitando internet.
//
// Contiene datos personales y el token de sesión, así que caduca sola: una
// copia vieja se borra en vez de mostrarse. La vigencia es la misma que la
// de la sesión (12 h) y se renueva con cada respuesta buena de `bt_sesion`.
export const CLAVE_OFFLINE = "blink.tarjeta.offline.v1";
export const VIGENCIA_COPIA_MS = 12 * 60 * 60 * 1000;

// Tolerancia al desfase del reloj: una copia fechada en el futuro por más
// de esto se considera manipulada y se descarta.
const DESFASE_MAXIMO_MS = 5 * 60 * 1000;

export interface CopiaOffline {
  token: string;
  cuenta: Cuenta;
  tarjetas: Tarjeta[];
  movimientos: Record<string, Movimiento[]>;
  guardado: number;
}

function almacen(valor?: Storage): Storage | null {
  if (valor) return valor;
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

function vigente(guardado: unknown): guardado is number {
  if (typeof guardado !== "number" || !Number.isFinite(guardado)) return false;
  const edad = Date.now() - guardado;
  return edad <= VIGENCIA_COPIA_MS && edad >= -DESFASE_MAXIMO_MS;
}

export function leerCopia(deposito?: Storage): CopiaOffline | null {
  const guardado = almacen(deposito);
  if (!guardado) return null;
  let crudo: string | null;
  try {
    crudo = guardado.getItem(CLAVE_OFFLINE);
  } catch {
    return null;
  }
  if (!crudo) return null;

  try {
    const datos = JSON.parse(crudo) as Partial<CopiaOffline>;
    if (
      typeof datos.token !== "string" ||
      !datos.cuenta ||
      !Array.isArray(datos.tarjetas) ||
      !vigente(datos.guardado)
    ) {
      guardado.removeItem(CLAVE_OFFLINE);
      return null;
    }
    return {
      token: datos.token,
      cuenta: datos.cuenta as Cuenta,
      tarjetas: datos.tarjetas,
      movimientos: datos.movimientos ?? {},
      guardado: datos.guardado,
    };
  } catch {
    guardado.removeItem(CLAVE_OFFLINE);
    return null;
  }
}

export function guardarCopia(sesion: Sesion, deposito?: Storage): void {
  const guardado = almacen(deposito);
  if (!guardado) return;
  try {
    const previa = leerCopia(guardado);
    const movimientos = previa && previa.token === sesion.token ? previa.movimientos : {};
    guardado.setItem(
      CLAVE_OFFLINE,
      JSON.stringify({
        token: sesion.token,
        cuenta: sesion.cuenta,
        tarjetas: sesion.tarjetas,
        movimientos,
        guardado: Date.now(),
      })
    );
  } catch {
    // Sin espacio o almacenamiento bloqueado: la app sigue en línea.
  }
}

export function copiaDe(token: string, deposito?: Storage): Sesion | null {
  const copia = leerCopia(deposito);
  if (!copia || copia.token !== token) return null;
  return { token, cuenta: copia.cuenta, tarjetas: copia.tarjetas };
}

export function guardarMovimientos(
  token: string,
  serial: string,
  lista: Movimiento[],
  deposito?: Storage
): void {
  const copia = leerCopia(deposito);
  if (!copia || copia.token !== token) return;
  const guardado = almacen(deposito);
  if (!guardado) return;
  copia.movimientos[serial] = lista;
  copia.guardado = Date.now();
  try {
    guardado.setItem(CLAVE_OFFLINE, JSON.stringify(copia));
  } catch {
    // La copia anterior sigue sirviendo para el saldo.
  }
}

export function movimientosDe(
  token: string,
  serial: string,
  deposito?: Storage
): Movimiento[] | null {
  const copia = leerCopia(deposito);
  if (!copia || copia.token !== token) return null;
  return copia.movimientos[serial] ?? null;
}

// Borra la copia. Con token solo si pertenece a esa sesión, para no
// desalojar la billetera de otra cuenta abierta en el mismo equipo.
export function olvidarCopia(token?: string, deposito?: Storage): void {
  const copia = leerCopia(deposito);
  if (!copia) return;
  if (token && copia.token !== token) return;
  const guardado = almacen(deposito);
  try {
    guardado?.removeItem(CLAVE_OFFLINE);
  } catch {
    // Nada que hacer: el almacenamiento ya no está disponible.
  }
}
