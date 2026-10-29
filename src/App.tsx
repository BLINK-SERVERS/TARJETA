import { useCallback, useEffect, useRef, useState } from "react";
import { BarraTabs, type Pestana } from "./components/BarraTabs";
import { Hoja } from "./components/Hoja";
import { Icon } from "./components/Icon";
import { Acceso } from "./pages/Acceso";
import { Inicio } from "./pages/Inicio";
import { Movimientos } from "./pages/Movimientos";
import { Perfil } from "./pages/Perfil";
import { Recargar } from "./pages/Recargar";
import { ajustesPorDefecto } from "./lib/ajustes";
import { repositorio } from "./lib/repo";
import { aplicarTema, leerTema, useCopiar, type ModoTema } from "./lib/hooks";
import { formatearBs } from "./lib/formato";
import type { Ajustes, Movimiento, RecargaNueva, Sesion, Tarjeta } from "./lib/tipos";

const CLAVE_SESION = "blink.tarjeta.sesion";
const BLOQUEO_INACTIVO = 30 * 60 * 1000;

function leerSesionGuardada(): { token: string; expira: number } | null {
  try {
    const crudo = localStorage.getItem(CLAVE_SESION);
    if (!crudo) return null;
    const datos = JSON.parse(crudo) as { token?: string; expira?: number };
    if (!datos.token || !datos.expira || datos.expira < Date.now()) {
      localStorage.removeItem(CLAVE_SESION);
      return null;
    }
    return { token: datos.token, expira: datos.expira };
  } catch {
    return null;
  }
}

function guardarSesion(token: string) {
  localStorage.setItem(
    CLAVE_SESION,
    JSON.stringify({ token, expira: Date.now() + 12 * 60 * 60 * 1000 })
  );
}

export function App() {
  const [sesion, setSesion] = useState<Sesion | null>(null);
  const [tarjeta, setTarjeta] = useState<Tarjeta | null>(null);
  const [movimientos, setMovimientos] = useState<Movimiento[]>([]);
  const [ajustes, setAjustes] = useState<Ajustes>(ajustesPorDefecto());
  const [pestana, setPestana] = useState<Pestana>("inicio");
  const [tema, setTema] = useState<ModoTema>(leerTema);
  const [saldoOculto, setSaldoOculto] = useState(false);
  const [restaurando, setRestaurando] = useState(true);
  const [pagoMovilAbierto, setPagoMovilAbierto] = useState(false);
  const [copiado, copiar] = useCopiar();
  const ocultoDesde = useRef<number | null>(null);

  useEffect(() => {
    let vivo = true;
    (async () => {
      try {
        const config = await repositorio.ajustes();
        if (vivo) setAjustes(config);
        const guardada = leerSesionGuardada();
        if (!guardada) return;
        const [tarjetaActual, historial] = await Promise.all([
          repositorio.tarjeta(guardada.token),
          repositorio.movimientos(guardada.token),
        ]);
        if (!vivo) return;
        setSesion({ token: guardada.token, tarjeta: tarjetaActual });
        setTarjeta(tarjetaActual);
        setMovimientos(historial);
      } catch {
        localStorage.removeItem(CLAVE_SESION);
      } finally {
        if (vivo) setRestaurando(false);
      }
    })();
    return () => {
      vivo = false;
    };
  }, []);

  useEffect(() => {
    window.scrollTo({ top: 0, behavior: "instant" as ScrollBehavior });
  }, [pestana]);

  const refrescar = useCallback(async () => {
    if (!sesion) return;
    try {
      const [tarjetaActual, historial] = await Promise.all([
        repositorio.tarjeta(sesion.token),
        repositorio.movimientos(sesion.token),
      ]);
      setTarjeta(tarjetaActual);
      setMovimientos(historial);
    } catch {
      // La sesión pudo expirar; el siguiente intento de acción lo dirá.
    }
  }, [sesion]);

  const salir = useCallback(async () => {
    const token = sesion?.token;
    setSesion(null);
    setTarjeta(null);
    setMovimientos([]);
    setPestana("inicio");
    setSaldoOculto(false);
    localStorage.removeItem(CLAVE_SESION);
    if (token) {
      try {
        await repositorio.salir(token);
      } catch {
        // El token ya no existe en el servidor: nada que limpiar.
      }
    }
  }, [sesion]);

  useEffect(() => {
    function alCambiarVisibilidad() {
      if (document.hidden) {
        ocultoDesde.current = Date.now();
        return;
      }
      const oculto = ocultoDesde.current;
      ocultoDesde.current = null;
      if (oculto && Date.now() - oculto > BLOQUEO_INACTIVO) {
        void salir();
        return;
      }
      if (sesion) void refrescar();
    }
    document.addEventListener("visibilitychange", alCambiarVisibilidad);
    return () => document.removeEventListener("visibilitychange", alCambiarVisibilidad);
  }, [salir, refrescar, sesion]);

  async function alEntrar(nueva: Sesion) {
    guardarSesion(nueva.token);
    setSesion(nueva);
    setTarjeta(nueva.tarjeta);
    setPestana("inicio");
    try {
      setMovimientos(await repositorio.movimientos(nueva.token));
    } catch {
      setMovimientos([]);
    }
  }

  async function reportarRecarga(recarga: RecargaNueva) {
    if (!sesion) throw new Error("Sin sesión activa.");
    const movimiento = await repositorio.reportarRecarga(sesion.token, recarga);
    setMovimientos(await repositorio.movimientos(sesion.token));
    return movimiento;
  }

  async function cambiarPin(actual: string, nuevo: string) {
    if (!sesion) throw new Error("Sin sesión activa.");
    await repositorio.cambiarPin(sesion.token, actual, nuevo);
  }

  function cambiarPestana(nueva: Pestana) {
    setPestana(nueva);
    if (nueva === "inicio" || nueva === "movimientos") void refrescar();
  }

  function cambiarTema(nuevo: ModoTema) {
    setTema(nuevo);
    aplicarTema(nuevo);
  }

  if (restaurando) {
    return (
      <div className="arranque" role="status" aria-label="Abriendo tu tarjeta">
        <span className="marca marca--grande">
          BLINK<em>TARJETA</em>
        </span>
        <span className="girador girador--grande" />
      </div>
    );
  }

  if (!sesion || !tarjeta) {
    return <Acceso alEntrar={(nueva) => void alEntrar(nueva)} />;
  }

  return (
    <div className={`app app--${pestana}`}>
      <main className="app__main" id="contenido">
        {pestana === "inicio" && (
          <Inicio
            tarjeta={tarjeta}
            movimientos={movimientos}
            saldoOculto={saldoOculto}
            alAlternarSaldo={() => setSaldoOculto((valor) => !valor)}
            alRecargar={() => cambiarPestana("recargar")}
            alVerMovimientos={() => cambiarPestana("movimientos")}
            alVerPerfil={() => cambiarPestana("perfil")}
            alAbrirPagoMovil={() => setPagoMovilAbierto(true)}
          />
        )}
        {pestana === "movimientos" && <Movimientos tarjeta={tarjeta} movimientos={movimientos} />}
        {pestana === "recargar" && (
          <Recargar
            tarjeta={tarjeta}
            ajustes={ajustes}
            movimientos={movimientos}
            alReportar={reportarRecarga}
            alInicio={() => cambiarPestana("inicio")}
            alVerMovimientos={() => cambiarPestana("movimientos")}
          />
        )}
        {pestana === "perfil" && (
          <Perfil
            tarjeta={tarjeta}
            ajustes={ajustes}
            tema={tema}
            modoDatos={repositorio.modo}
            alCambiarTema={cambiarTema}
            alCambiarPin={cambiarPin}
            alSalir={() => void salir()}
          />
        )}
      </main>

      <BarraTabs activa={pestana} alCambiar={cambiarPestana} />

      <Hoja
        abierta={pagoMovilAbierto}
        alCerrar={() => setPagoMovilAbierto(false)}
        titulo="Pago Móvil de BLINK"
        descripcion="Transfiere desde tu banco y reporta la referencia en Recargar."
      >
        <dl className="datos datos--copiar">
          {[
            ["Banco", ajustes.pagoMovil.banco, "pm-banco"],
            ["RIF", ajustes.pagoMovil.rif, "pm-rif"],
            ["Teléfono", ajustes.pagoMovil.telefono, "pm-telefono"],
            ["Titular", ajustes.pagoMovil.titular, "pm-titular"],
          ].map(([etiqueta, valor, clave]) => (
            <div key={clave}>
              <dt>{etiqueta}</dt>
              <dd>
                <span className="mono">{valor}</span>
                <button
                  type="button"
                  className="boton-copiar"
                  onClick={() => void copiar(valor, clave)}
                  aria-label={`Copiar ${etiqueta.toLowerCase()}`}
                >
                  <Icon name={copiado === clave ? "check" : "copiar"} />
                </button>
              </dd>
            </div>
          ))}
        </dl>
        <ol className="pasos">
          <li>Abre tu banco y elige Pago Móvil.</li>
          <li>
            Paga {formatearBs(tarjeta.tarifa * 10)} o el monto que quieras a los datos de
            arriba.
          </li>
          <li>Vuelve aquí, toca Recargar y reporta la referencia.</li>
        </ol>
        <button
          type="button"
          className="boton boton--primario"
          onClick={() => {
            setPagoMovilAbierto(false);
            cambiarPestana("recargar");
          }}
        >
          <Icon name="recargar" />
          Reportar una recarga
        </button>
      </Hoja>
    </div>
  );
}
