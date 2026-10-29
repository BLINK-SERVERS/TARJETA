import { useState } from "react";
import { Hoja } from "../components/Hoja";
import { Icon } from "../components/Icon";
import { PinEntrada } from "../components/PinEntrada";
import { ErrorBlink } from "../lib/repo";
import { validarPin } from "../lib/dominio";
import { formatearBs, formatearFecha, formatearVence, iniciales } from "../lib/formato";
import type { ModoTema } from "../lib/hooks";
import type { Ajustes, Tarjeta } from "../lib/tipos";

const PASAJES = "https://blink-servers.github.io/PASAJES/";
const SITIO = "https://www.blink.com.ve";

const APARIENCIAS: { id: ModoTema; etiqueta: string; icono: "auto" | "sol" | "luna" }[] = [
  { id: "auto", etiqueta: "Auto", icono: "auto" },
  { id: "claro", etiqueta: "Claro", icono: "sol" },
  { id: "oscuro", etiqueta: "Oscuro", icono: "luna" },
];

interface Props {
  tarjeta: Tarjeta;
  ajustes: Ajustes;
  tema: ModoTema;
  modoDatos: "local" | "nube";
  alCambiarTema: (tema: ModoTema) => void;
  alCambiarPin: (actual: string, nuevo: string) => Promise<void>;
  alSalir: () => void;
}

export function Perfil({
  tarjeta,
  ajustes,
  tema,
  modoDatos,
  alCambiarTema,
  alCambiarPin,
  alSalir,
}: Props) {
  const [pinAbierto, setPinAbierto] = useState(false);
  const [actual, setActual] = useState("");
  const [nuevo, setNuevo] = useState("");
  const [repetir, setRepetir] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [exito, setExito] = useState(false);
  const [guardando, setGuardando] = useState(false);

  function cerrarPin() {
    setPinAbierto(false);
    setActual("");
    setNuevo("");
    setRepetir("");
    setError(null);
    setExito(false);
  }

  async function guardarPin() {
    const problema = validarPin(nuevo);
    if (problema) return setError(problema);
    if (nuevo !== repetir) return setError("Los dos PIN nuevos no coinciden.");
    if (nuevo === actual) return setError("El PIN nuevo debe ser distinto al actual.");
    setGuardando(true);
    setError(null);
    try {
      await alCambiarPin(actual, nuevo);
      setExito(true);
      setActual("");
      setNuevo("");
      setRepetir("");
    } catch (fallo) {
      setError(
        fallo instanceof ErrorBlink ? fallo.message : "No pudimos cambiar el PIN. Inténtalo otra vez."
      );
    } finally {
      setGuardando(false);
    }
  }

  return (
    <div className="vista">
      <header className="cabecera cabecera--titulo">
        <h1 className="cabecera__titulo cabecera__titulo--grande">Perfil</h1>
      </header>

      <section className="identidad">
        <span className="identidad__avatar">{iniciales(tarjeta.titular.nombre)}</span>
        <div className="identidad__datos">
          <strong>{tarjeta.titular.nombre}</strong>
          <span className="mono">{tarjeta.titular.cedula}</span>
          <span className="mono">{tarjeta.titular.telefono}</span>
        </div>
        <span
          className={`etiqueta ${
            tarjeta.estado === "activa" ? "etiqueta--bien" : "etiqueta--mal"
          }`}
        >
          {tarjeta.estado === "activa" ? "Activa" : "Bloqueada"}
        </span>
      </section>

      <section className="panel">
        <h2 className="panel__titulo">Datos de la tarjeta</h2>
        <dl className="filas">
          <div>
            <dt>Serial</dt>
            <dd className="mono">{tarjeta.serial}</dd>
          </div>
          <div>
            <dt>Chip (UID)</dt>
            <dd className="mono">{tarjeta.uid || "Sin enrolar"}</dd>
          </div>
          <div>
            <dt>Saldo</dt>
            <dd>{formatearBs(tarjeta.saldo)}</dd>
          </div>
          <div>
            <dt>Tarifa del pasaje</dt>
            <dd>{formatearBs(tarjeta.tarifa)}</dd>
          </div>
          <div>
            <dt>Emitida</dt>
            <dd>{formatearFecha(tarjeta.emitida)}</dd>
          </div>
          <div>
            <dt>Vence</dt>
            <dd className="mono">{formatearVence(tarjeta.vence)}</dd>
          </div>
        </dl>
      </section>

      <section className="panel">
        <h2 className="panel__titulo">Apariencia</h2>
        <div className="segmentado segmentado--tres" role="radiogroup" aria-label="Apariencia">
          {APARIENCIAS.map((opcion) => (
            <button
              key={opcion.id}
              type="button"
              role="radio"
              aria-checked={tema === opcion.id}
              className={`segmentado__opcion${
                tema === opcion.id ? " segmentado__opcion--activa" : ""
              }`}
              onClick={() => alCambiarTema(opcion.id)}
            >
              <Icon name={opcion.icono} />
              {opcion.etiqueta}
            </button>
          ))}
        </div>
        <p className="panel__nota">«Auto» sigue la apariencia del teléfono.</p>
      </section>

      <section className="panel">
        <h2 className="panel__titulo">Seguridad</h2>
        <button type="button" className="fila-accion" onClick={() => setPinAbierto(true)}>
          <span className="fila-accion__icono">
            <Icon name="candado" />
          </span>
          <span className="fila-accion__texto">
            <strong>Cambiar PIN</strong>
            <span>4 dígitos, sin secuencias fáciles</span>
          </span>
          <Icon name="adelante" />
        </button>
        <p className="panel__nota">
          La sesión se cierra sola a las 12 horas. El PIN nunca se envía a un tercero; se
          verifica contra su hash.
        </p>
      </section>

      <section className="panel">
        <h2 className="panel__titulo">BLINK PASAJES</h2>
        <a className="fila-accion" href={PASAJES} target="_blank" rel="noreferrer">
          <span className="fila-accion__icono">
            <Icon name="autobus" />
          </span>
          <span className="fila-accion__texto">
            <strong>Panel de la línea</strong>
            <span>Lector, fiscal y administración</span>
          </span>
          <Icon name="compartir" />
        </a>
        <a className="fila-accion" href={SITIO} target="_blank" rel="noreferrer">
          <span className="fila-accion__icono">
            <Icon name="escudo" />
          </span>
          <span className="fila-accion__texto">
            <strong>Sitio de BLINK</strong>
            <span>blink.com.ve</span>
          </span>
          <Icon name="compartir" />
        </a>
        <div className="fila-accion fila-accion--estatica">
          <span className="fila-accion__icono">
            <Icon name="ayuda" />
          </span>
          <span className="fila-accion__texto">
            <strong>Atención al cliente</strong>
            <span className="mono">{ajustes.atencion}</span>
          </span>
        </div>
      </section>

      <p className="panel__nota panel__nota--centro">
        BLINK TARJETA v{__APP_VERSION__} ·{" "}
        {modoDatos === "nube" ? "Conectada a BLINK Cloud" : "Modo demostración (datos locales)"}
      </p>

      <button type="button" className="boton boton--peligro" onClick={alSalir}>
        <Icon name="salir" />
        Cerrar sesión
      </button>

      <Hoja
        abierta={pinAbierto}
        alCerrar={cerrarPin}
        titulo="Cambiar PIN"
        descripcion="Elige cuatro dígitos que no sean fáciles de adivinar."
        pie={
          exito ? (
            <button type="button" className="boton boton--primario" onClick={cerrarPin}>
              Listo
            </button>
          ) : (
            <>
              <button type="button" className="boton boton--fantasma" onClick={cerrarPin}>
                Cancelar
              </button>
              <button
                type="button"
                className="boton boton--primario"
                onClick={() => void guardarPin()}
                disabled={guardando}
              >
                {guardando ? <span className="girador" aria-label="Guardando" /> : "Guardar PIN"}
              </button>
            </>
          )
        }
      >
        {exito ? (
          <div className="exito-mini">
            <span className="exito__sello">
              <Icon name="check" />
            </span>
            <p>Tu PIN quedó actualizado. Úsalo la próxima vez que entres.</p>
          </div>
        ) : (
          <div className="pin-form">
            <div className="campo">
              <span className="campo__etiqueta">PIN actual</span>
              <PinEntrada valor={actual} alCambiar={setActual} etiqueta="PIN actual" autoFocus />
            </div>
            <div className="campo">
              <span className="campo__etiqueta">PIN nuevo</span>
              <PinEntrada valor={nuevo} alCambiar={setNuevo} etiqueta="PIN nuevo" />
            </div>
            <div className="campo">
              <span className="campo__etiqueta">Repite el PIN nuevo</span>
              <PinEntrada valor={repetir} alCambiar={setRepetir} etiqueta="Repite el PIN nuevo" />
            </div>
            {error && (
              <div className="aviso aviso--peligro" role="alert">
                <Icon name="alerta" />
                <p>{error}</p>
              </div>
            )}
          </div>
        )}
      </Hoja>
    </div>
  );
}
