import type { Ajustes, EstadoMovimiento, Movimiento, RecargaNueva, Sesion, Tarjeta } from "./tipos";
import { AJUSTES_POR_DEFECTO } from "./tipos";
import { hashPin, verificarPin } from "./pin";
import { soloDigitos } from "./formato";

export type CodigoError =
  | "credenciales"
  | "bloqueada"
  | "sin-tarjeta"
  | "ya-activada"
  | "pin-invalido"
  | "duplicada"
  | "red"
  | "sesion";

export class ErrorBlink extends Error {
  constructor(
    public codigo: CodigoError,
    mensaje: string
  ) {
    super(mensaje);
    this.name = "ErrorBlink";
  }
}

export interface Repositorio {
  modo: "local" | "nube";
  entrar(cedula: string, pin: string): Promise<Sesion>;
  activar(datos: {
    cedula: string;
    serial: string;
    telefono: string;
    pin: string;
  }): Promise<Sesion>;
  tarjeta(token: string): Promise<Tarjeta>;
  movimientos(token: string): Promise<Movimiento[]>;
  reportarRecarga(token: string, recarga: RecargaNueva): Promise<Movimiento>;
  cambiarPin(token: string, actual: string, nuevo: string): Promise<void>;
  salir(token: string): Promise<void>;
  ajustes(): Promise<Ajustes>;
}

// ------------------------------------------------------------------
// Modo local: la app funciona sin backend con las tarjetas de prueba.
// El PIN se guarda con PBKDF2, nunca en claro, igual que haría la nube.
// ------------------------------------------------------------------

const CLAVE = "blink.tarjeta.v1";
const VIDA_SESION = 1000 * 60 * 60 * 12;
const MAX_INTENTOS = 5;
const BLOQUEO_INTENTOS = 1000 * 60 * 5;

interface TarjetaLocal extends Tarjeta {
  pinHash: string;
}

interface BaseLocal {
  version: 1;
  tarjetas: TarjetaLocal[];
  movimientos: Movimiento[];
  sesiones: Record<string, { cedula: string; expira: number }>;
  intentos: Record<string, { fallos: number; hasta: number }>;
}

const TARIFA = 15;

function isoDiasAtras(dias: number, hora: number, minuto: number): string {
  const fecha = new Date();
  fecha.setDate(fecha.getDate() - dias);
  fecha.setHours(hora, minuto, 0, 0);
  return fecha.toISOString();
}

function semilla(pin1: string, pin2: string, pin3: string): BaseLocal {
  const tarjetas: TarjetaLocal[] = [
    {
      serial: "23-1-0000001-0",
      uid: "3981BF06",
      titular: { nombre: "María Fernanda Fernández", cedula: "V-12345678", telefono: "0414-1234567" },
      saldo: 485,
      estado: "activa",
      emitida: "2025-03-14T12:00:00.000Z",
      vence: "2030-03-14T12:00:00.000Z",
      tarifa: TARIFA,
      pinHash: pin1,
    },
    {
      serial: "23-1-0000002-0",
      uid: "058151954F3400",
      titular: { nombre: "Carlos Andrés Rondón", cedula: "V-87654321", telefono: "0424-8765432" },
      saldo: 0,
      estado: "activa",
      emitida: "2025-06-02T12:00:00.000Z",
      vence: "2030-06-02T12:00:00.000Z",
      tarifa: TARIFA,
      pinHash: pin2,
    },
    {
      serial: "23-1-0000003-0",
      uid: "A1B2C3D4",
      titular: { nombre: "Luis Enrique Pérez", cedula: "V-11223344", telefono: "0412-5556677" },
      saldo: 30,
      estado: "bloqueada",
      emitida: "2024-11-20T12:00:00.000Z",
      vence: "2029-11-20T12:00:00.000Z",
      tarifa: TARIFA,
      pinHash: pin3,
    },
  ];

  const serie1: Movimiento[] = [
    {
      id: "mv-0001",
      serial: "23-1-0000001-0",
      tipo: "viaje",
      monto: -TARIFA,
      saldoDespues: 485,
      at: isoDiasAtras(0, 7, 42),
      detalle: "Pasaje en la línea",
      estado: "aprobado",
      unidad: "Demo-01",
    },
    {
      id: "mv-0002",
      serial: "23-1-0000001-0",
      tipo: "viaje",
      monto: -TARIFA,
      saldoDespues: 500,
      at: isoDiasAtras(0, 6, 58),
      detalle: "Pasaje en la línea",
      estado: "aprobado",
      unidad: "Demo-01",
    },
    {
      id: "mv-0003",
      serial: "23-1-0000001-0",
      tipo: "recarga",
      monto: 500,
      saldoDespues: 515,
      at: isoDiasAtras(1, 18, 20),
      detalle: "Pago Móvil aprobado",
      estado: "aprobado",
      banco: "Banesco",
      referencia: "4821",
    },
    {
      id: "mv-0004",
      serial: "23-1-0000001-0",
      tipo: "viaje",
      monto: -TARIFA,
      saldoDespues: 15,
      at: isoDiasAtras(2, 17, 5),
      detalle: "Pasaje en la línea",
      estado: "aprobado",
      unidad: "Demo-02",
    },
    {
      id: "mv-0005",
      serial: "23-1-0000001-0",
      tipo: "viaje",
      monto: -TARIFA,
      saldoDespues: 30,
      at: isoDiasAtras(2, 16, 48),
      detalle: "Pasaje en la línea",
      estado: "aprobado",
      unidad: "Demo-02",
    },
    {
      id: "mv-0006",
      serial: "23-1-0000001-0",
      tipo: "recarga",
      monto: 200,
      saldoDespues: 45,
      at: isoDiasAtras(6, 9, 12),
      detalle: "Pago Móvil aprobado",
      estado: "aprobado",
      banco: "Mercantil",
      referencia: "9034",
    },
  ];

  const pendiente: Movimiento = {
    id: "mv-0007",
    serial: "23-1-0000002-0",
    tipo: "recarga",
    monto: 100,
    saldoDespues: 0,
    at: isoDiasAtras(0, 8, 3),
    detalle: "Pago Móvil en revisión",
    estado: "pendiente",
    banco: "Banco de Venezuela",
    referencia: "1177",
  };

  const viaje2: Movimiento = {
    id: "mv-0008",
    serial: "23-1-0000003-0",
    tipo: "viaje",
    monto: -TARIFA,
    saldoDespues: 30,
    at: isoDiasAtras(3, 12, 30),
    detalle: "Pasaje en la línea",
    estado: "aprobado",
    unidad: "Demo-03",
  };

  return {
    version: 1,
    tarjetas,
    movimientos: [pendiente, ...serie1, viaje2].sort(
      (a, b) => new Date(b.at).getTime() - new Date(a.at).getTime()
    ),
    sesiones: {},
    intentos: {},
  };
}

function leer(): BaseLocal | null {
  try {
    const crudo = localStorage.getItem(CLAVE);
    if (!crudo) return null;
    const datos = JSON.parse(crudo) as BaseLocal;
    if (datos.version !== 1) return null;
    return datos;
  } catch {
    return null;
  }
}

function guardar(datos: BaseLocal) {
  localStorage.setItem(CLAVE, JSON.stringify(datos));
}

let inicializando: Promise<BaseLocal> | null = null;

async function base(): Promise<BaseLocal> {
  const existente = leer();
  if (existente) return existente;
  if (!inicializando) {
    inicializando = (async () => {
      const [p1, p2, p3] = await Promise.all([
        hashPin("1234"),
        hashPin("1234"),
        hashPin("1234"),
      ]);
      const datos = semilla(p1, p2, p3);
      guardar(datos);
      return datos;
    })();
  }
  return inicializando;
}

function aTarjeta({ pinHash: _pinHash, ...tarjeta }: TarjetaLocal): Tarjeta {
  return tarjeta;
}

function buscar(datos: BaseLocal, cedula: string): TarjetaLocal | undefined {
  const digitos = soloDigitos(cedula);
  return datos.tarjetas.find((t) => soloDigitos(t.titular.cedula) === digitos);
}

function abrirSesion(datos: BaseLocal, tarjeta: TarjetaLocal): Sesion {
  const token = crypto.randomUUID();
  datos.sesiones[token] = { cedula: tarjeta.titular.cedula, expira: Date.now() + VIDA_SESION };
  return { token, tarjeta: aTarjeta(tarjeta) };
}

function porToken(datos: BaseLocal, token: string): TarjetaLocal {
  const sesion = datos.sesiones[token];
  if (!sesion || sesion.expira < Date.now()) {
    throw new ErrorBlink("sesion", "La sesión expiró. Vuelve a entrar con tu PIN.");
  }
  const tarjeta = buscar(datos, sesion.cedula);
  if (!tarjeta) throw new ErrorBlink("sesion", "No encontramos tu tarjeta.");
  return tarjeta;
}

export const repositorioLocal: Repositorio = {
  modo: "local",

  async entrar(cedula, pin) {
    const datos = await base();
    const llave = soloDigitos(cedula);
    const intento = datos.intentos[llave];
    if (intento && intento.hasta > Date.now()) {
      const minutos = Math.ceil((intento.hasta - Date.now()) / 60000);
      throw new ErrorBlink(
        "credenciales",
        `Demasiados intentos fallidos. Espera ${minutos} min o recupera tu PIN en atención al cliente.`
      );
    }

    const tarjeta = buscar(datos, cedula);
    if (!tarjeta) {
      throw new ErrorBlink("sin-tarjeta", "No encontramos una tarjeta con esa cédula.");
    }

    const correcto = await verificarPin(pin, tarjeta.pinHash);
    if (!correcto) {
      const fallos = (intento?.fallos ?? 0) + 1;
      datos.intentos[llave] = {
        fallos,
        hasta: fallos >= MAX_INTENTOS ? Date.now() + BLOQUEO_INTENTOS : 0,
      };
      guardar(datos);
      if (fallos >= MAX_INTENTOS) {
        throw new ErrorBlink(
          "credenciales",
          "Demasiados intentos fallidos. Espera 5 min o recupera tu PIN en atención al cliente."
        );
      }
      throw new ErrorBlink("credenciales", "El PIN no coincide. Inténtalo de nuevo.");
    }

    delete datos.intentos[llave];
    const sesion = abrirSesion(datos, tarjeta);
    guardar(datos);
    return sesion;
  },

  async activar({ cedula, serial, telefono, pin }) {
    const datos = await base();
    const existente = buscar(datos, cedula);
    if (existente) {
      throw new ErrorBlink(
        "ya-activada",
        "Esa cédula ya tiene una tarjeta activa. Entra con tu PIN."
      );
    }
    const serialNormalizado = serial.trim();
    if (!/^\d{2}-\d-\d{7}-\d$/.test(serialNormalizado)) {
      throw new ErrorBlink("sin-tarjeta", "El serial no tiene el formato 23-1-0000001-0.");
    }
    const hoy = new Date();
    const vence = new Date(hoy);
    vence.setFullYear(hoy.getFullYear() + 5);
    const tarjeta: TarjetaLocal = {
      serial: serialNormalizado,
      uid: "",
      titular: {
        nombre: "Titular nuevo",
        cedula,
        telefono: telefono.replace(/\D/g, ""),
      },
      saldo: 0,
      estado: "activa",
      emitida: hoy.toISOString(),
      vence: vence.toISOString(),
      tarifa: TARIFA,
      pinHash: await hashPin(pin),
    };
    datos.tarjetas.push(tarjeta);
    const sesion = abrirSesion(datos, tarjeta);
    guardar(datos);
    return sesion;
  },

  async tarjeta(token) {
    const datos = await base();
    return aTarjeta(porToken(datos, token));
  },

  async movimientos(token) {
    const datos = await base();
    const tarjeta = porToken(datos, token);
    return datos.movimientos
      .filter((m) => m.serial === tarjeta.serial)
      .sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());
  },

  async reportarRecarga(token, recarga) {
    const datos = await base();
    const tarjeta = porToken(datos, token);
    const referencia = soloDigitos(recarga.referencia).slice(-4);
    const duplicada = datos.movimientos.some(
      (m) =>
        m.serial === tarjeta.serial &&
        m.tipo === "recarga" &&
        m.banco === recarga.banco &&
        m.referencia === referencia &&
        m.estado !== "rechazado"
    );
    if (duplicada) {
      throw new ErrorBlink("duplicada", "Ya reportaste esa referencia. Revisa Movimientos.");
    }
    const movimiento: Movimiento = {
      id: `rc-${crypto.randomUUID()}`,
      serial: tarjeta.serial,
      tipo: "recarga",
      monto: Math.round(recarga.monto * 100) / 100,
      saldoDespues: tarjeta.saldo,
      at: new Date().toISOString(),
      detalle: "Pago Móvil en revisión",
      estado: "pendiente" satisfies EstadoMovimiento,
      banco: recarga.banco,
      referencia,
    };
    datos.movimientos = [movimiento, ...datos.movimientos].slice(0, 300);
    guardar(datos);
    return movimiento;
  },

  async cambiarPin(token, actual, nuevo) {
    const datos = await base();
    const tarjeta = porToken(datos, token);
    if (!(await verificarPin(actual, tarjeta.pinHash))) {
      throw new ErrorBlink("credenciales", "El PIN actual no coincide.");
    }
    tarjeta.pinHash = await hashPin(nuevo);
    guardar(datos);
  },

  async salir(token) {
    const datos = await base();
    delete datos.sesiones[token];
    guardar(datos);
  },

  async ajustes() {
    return AJUSTES_POR_DEFECTO;
  },
};
