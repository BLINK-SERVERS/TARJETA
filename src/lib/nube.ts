import type { Ajustes, Movimiento, RecargaNueva, Sesion, Tarjeta } from "./tipos";
import { AJUSTES_POR_DEFECTO } from "./tipos";
import { ErrorBlink, type CodigoError, type Repositorio } from "./local";

// Cliente mínimo de Supabase por REST. No se usa `supabase-js` porque la app
// solo necesita seis llamadas RPC: así el bundle no carga la librería de auth
// ni la de realtime (más de 100 KB) para consultar una tarjeta.
//
// Las credenciales son la URL del proyecto y la llave pública (anon /
// publishable). La llave de servicio NUNCA viaja al navegador: las funciones
// `bt_*` son `security definer` y viven en Postgres.

const URL_BASE = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.replace(/\/$/, "");
const LLAVE = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const nubeConfigurada = Boolean(URL_BASE && LLAVE);

const CODIGOS: CodigoError[] = [
  "credenciales",
  "bloqueada",
  "sin-tarjeta",
  "ya-activada",
  "pin-invalido",
  "duplicada",
  "red",
  "sesion",
];

interface ErrorRpc {
  code?: string;
  message?: string;
  details?: string;
}

interface ErrorDeDominio {
  error: string;
  mensaje?: string;
}

function esErrorDeDominio(valor: unknown): valor is ErrorDeDominio {
  return (
    typeof valor === "object" &&
    valor !== null &&
    "error" in valor &&
    typeof (valor as ErrorDeDominio).error === "string"
  );
}

async function rpc<T>(funcion: string, argumentos: Record<string, unknown>): Promise<T> {
  let respuesta: Response;
  try {
    respuesta = await fetch(`${URL_BASE}/rest/v1/rpc/${funcion}`, {
      method: "POST",
      headers: {
        apikey: LLAVE ?? "",
        Authorization: `Bearer ${LLAVE ?? ""}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(argumentos),
    });
  } catch {
    throw new ErrorBlink("red", "Sin conexión con BLINK. Revisa tu internet e inténtalo otra vez.");
  }

  if (!respuesta.ok) {
    const detalle = (await respuesta.json().catch(() => ({}))) as ErrorRpc;
    const mensaje = detalle.message ?? "";
    const codigo = CODIGOS.find((c) => mensaje.includes(`bt:${c}`));
    if (codigo) {
      throw new ErrorBlink(codigo, mensaje.replace(`bt:${codigo}:`, "").trim());
    }
    throw new ErrorBlink("red", "BLINK no está disponible en este momento. Intenta más tarde.");
  }

  const datos = (await respuesta.json()) as unknown;

  // Los fallos que deben dejar rastro en la base (intentos de PIN) vuelven
  // como dato, no como error HTTP: así la función puede confirmar su escritura.
  if (esErrorDeDominio(datos)) {
    const codigo = CODIGOS.find((c) => c === datos.error);
    throw new ErrorBlink(
      codigo ?? "red",
      datos.mensaje ?? "BLINK no está disponible en este momento. Intenta más tarde."
    );
  }

  return datos as T;
}

interface TarjetaRpc {
  serial: string;
  uid: string;
  titular: { nombre: string; cedula: string; telefono: string };
  saldo: number;
  estado: Tarjeta["estado"];
  emitida: string;
  vence: string;
  tarifa: number;
}

function aSesion(datos: { token: string; tarjeta: TarjetaRpc }): Sesion {
  return { token: datos.token, tarjeta: datos.tarjeta };
}

export const repositorioNube: Repositorio = {
  modo: "nube",

  entrar(cedula, pin) {
    return rpc<Sesion>("bt_entrar", { p_cedula: cedula, p_pin: pin }).then(aSesion);
  },

  activar(datos) {
    return rpc<Sesion>("bt_activar", {
      p_cedula: datos.cedula,
      p_serial: datos.serial,
      p_telefono: datos.telefono,
      p_pin: datos.pin,
    }).then(aSesion);
  },

  tarjeta(token) {
    return rpc<{ tarjeta: Tarjeta }>("bt_tarjeta", { p_token: token }).then((r) => r.tarjeta);
  },

  movimientos(token) {
    return rpc<{ movimientos: Movimiento[] }>("bt_movimientos", { p_token: token }).then(
      (r) => r.movimientos
    );
  },

  reportarRecarga(token, recarga: RecargaNueva) {
    return rpc<{ movimiento: Movimiento }>("bt_recargar", {
      p_token: token,
      p_monto: recarga.monto,
      p_telefono: recarga.telefono,
      p_banco: recarga.banco,
      p_referencia: recarga.referencia,
    }).then((r) => r.movimiento);
  },

  async cambiarPin(token, actual, nuevo) {
    await rpc<null>("bt_cambiar_pin", { p_token: token, p_actual: actual, p_nuevo: nuevo });
  },

  async salir(token) {
    await rpc<null>("bt_salir", { p_token: token });
  },

  async ajustes() {
    try {
      return await rpc<Ajustes>("bt_ajustes", {});
    } catch {
      return AJUSTES_POR_DEFECTO;
    }
  },
};
