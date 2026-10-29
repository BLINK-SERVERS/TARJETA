import { useState, type FormEvent } from "react";
import { Icon } from "../components/Icon";
import { PinEntrada } from "../components/PinEntrada";
import { Hoja } from "../components/Hoja";
import { ErrorBlink } from "../lib/repo";
import { repositorio, type Repositorio } from "../lib/repo";
import { validarCedula, validarPin, validarSerial } from "../lib/dominio";
import { formatearCedula, formatearSerial, formatearTelefono, soloDigitos } from "../lib/formato";
import type { Sesion } from "../lib/tipos";

type Modo = "entrar" | "activar";

interface Props {
  repo?: Repositorio;
  alEntrar: (sesion: Sesion) => void;
}

export function Acceso({ repo = repositorio, alEntrar }: Props) {
  const [modo, setModo] = useState<Modo>("entrar");
  const [cedula, setCedula] = useState("");
  const [pin, setPin] = useState("");
  const [serial, setSerial] = useState("");
  const [telefono, setTelefono] = useState("");
  const [pinNuevo, setPinNuevo] = useState("");
  const [errores, setErrores] = useState<Record<string, string>>({});
  const [aviso, setAviso] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [ayuda, setAyuda] = useState(false);

  const demo = repo.modo === "local";

  function cambiarModo(nuevo: Modo) {
    setModo(nuevo);
    setErrores({});
    setAviso(null);
    setPin("");
    setPinNuevo("");
  }

  function validar(pinActual = pin): boolean {
    const nuevos: Record<string, string> = {};
    const errorCedula = validarCedula(cedula);
    if (errorCedula) nuevos.cedula = errorCedula;

    if (modo === "entrar") {
      if (pinActual.length !== 4) nuevos.pin = "Escribe tu PIN de 4 dígitos.";
    } else {
      const errorSerial = validarSerial(serial);
      if (errorSerial) nuevos.serial = errorSerial;
      if (!/^0\d{10}$/.test(soloDigitos(telefono))) {
        nuevos.telefono = "Escribe el teléfono con 11 dígitos (0414-1234567).";
      }
      const errorPin = validarPin(pinActual);
      if (errorPin) nuevos.pin = errorPin;
      if (pinNuevo !== pinActual) nuevos.pinNuevo = "Los dos PIN no coinciden.";
    }

    setErrores(nuevos);
    return Object.keys(nuevos).length === 0;
  }

  async function enviar(evento?: FormEvent, pinActual = pin) {
    evento?.preventDefault();
    if (enviando || !validar(pinActual)) return;
    setEnviando(true);
    setAviso(null);
    try {
      const sesion =
        modo === "entrar"
          ? await repo.entrar(cedula, pinActual)
          : await repo.activar({
              cedula,
              serial: formatearSerial(soloDigitos(serial)),
              telefono: soloDigitos(telefono),
              pin: pinActual,
            });
      alEntrar(sesion);
    } catch (error) {
      const mensaje =
        error instanceof ErrorBlink
          ? error.message
          : "No pudimos completar la operación. Inténtalo de nuevo.";
      setAviso(mensaje);
      setPin("");
      setPinNuevo("");
    } finally {
      setEnviando(false);
    }
  }

  return (
    <div className="acceso">
      <div className="acceso__fondo" aria-hidden="true">
        <span className="acceso__orbe acceso__orbe--uno" />
        <span className="acceso__orbe acceso__orbe--dos" />
      </div>

      <header className="acceso__marca">
        <span className="marca">
          BLINK<em>TARJETA</em>
        </span>
        <p className="acceso__lema">
          Tu tarjeta de transporte,<br />
          en el bolsillo.
        </p>
      </header>

      <section className="acceso__panel">
        <div className="segmentado" role="tablist" aria-label="Acceso">
          <button
            type="button"
            role="tab"
            aria-selected={modo === "entrar"}
            className={`segmentado__opcion${modo === "entrar" ? " segmentado__opcion--activa" : ""}`}
            onClick={() => cambiarModo("entrar")}
          >
            Entrar
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={modo === "activar"}
            className={`segmentado__opcion${modo === "activar" ? " segmentado__opcion--activa" : ""}`}
            onClick={() => cambiarModo("activar")}
          >
            Activar
          </button>
        </div>

        <form className="acceso__form" onSubmit={enviar} noValidate>
          <div className="campo">
            <label className="campo__etiqueta" htmlFor="cedula">
              Cédula del titular
            </label>
            <input
              id="cedula"
              className="entrada mono"
              inputMode="numeric"
              autoComplete="off"
              autoCapitalize="characters"
              spellCheck={false}
              placeholder="V-12345678"
              value={cedula}
              onChange={(evento) => setCedula(formatearCedula(evento.target.value))}
              aria-invalid={errores.cedula ? true : undefined}
              aria-describedby={errores.cedula ? "cedula-error" : undefined}
            />
            {errores.cedula && (
              <p className="campo__error" id="cedula-error">
                {errores.cedula}
              </p>
            )}
          </div>

          {modo === "activar" && (
            <>
              <div className="campo">
                <label className="campo__etiqueta" htmlFor="serial">
                  Serial de la tarjeta
                </label>
                <input
                  id="serial"
                  className="entrada mono"
                  inputMode="numeric"
                  autoComplete="off"
                  placeholder="23-1-000001-9"
                  value={serial}
                  onChange={(evento) => setSerial(formatearSerial(soloDigitos(evento.target.value)))}
                  aria-invalid={errores.serial ? true : undefined}
                  aria-describedby={errores.serial ? "serial-error" : "serial-ayuda"}
                />
                <span className="campo__ayuda" id="serial-ayuda">
                  Está impreso al reverso del plástico, debajo del código de barras.
                </span>
                {errores.serial && (
                  <p className="campo__error" id="serial-error">
                    {errores.serial}
                  </p>
                )}
              </div>

              <div className="campo">
                <label className="campo__etiqueta" htmlFor="telefono">
                  Teléfono de contacto
                </label>
                <input
                  id="telefono"
                  className="entrada mono"
                  type="tel"
                  inputMode="tel"
                  autoComplete="tel-national"
                  placeholder="0414-1234567"
                  maxLength={12}
                  value={telefono}
                  onChange={(evento) => setTelefono(formatearTelefono(evento.target.value))}
                  aria-invalid={errores.telefono ? true : undefined}
                  aria-describedby={errores.telefono ? "telefono-error" : undefined}
                />
                {errores.telefono && (
                  <p className="campo__error" id="telefono-error">
                    {errores.telefono}
                  </p>
                )}
              </div>
            </>
          )}

          <div className="campo">
            <span className="campo__etiqueta" id="pin-etiqueta">
              {modo === "entrar" ? "PIN de acceso" : "Crea tu PIN de 4 dígitos"}
            </span>
            <PinEntrada
              valor={pin}
              alCambiar={setPin}
              alCompletar={(completo) => {
                if (modo === "entrar") void enviar(undefined, completo);
              }}
              error={Boolean(errores.pin)}
              etiqueta={modo === "entrar" ? "PIN de acceso" : "PIN nuevo"}
            />
            {errores.pin && <p className="campo__error">{errores.pin}</p>}
          </div>

          {modo === "activar" && (
            <div className="campo">
              <span className="campo__etiqueta">Repite el PIN</span>
              <PinEntrada
                valor={pinNuevo}
                alCambiar={setPinNuevo}
                error={Boolean(errores.pinNuevo)}
                etiqueta="Repite el PIN"
              />
              {errores.pinNuevo && <p className="campo__error">{errores.pinNuevo}</p>}
            </div>
          )}

          {aviso && (
            <div className="aviso aviso--peligro" role="alert">
              <Icon name="alerta" />
              <p>{aviso}</p>
            </div>
          )}

          <button type="submit" className="boton boton--primario" disabled={enviando}>
            {enviando ? (
              <span className="girador" aria-label="Verificando" />
            ) : (
              <>
                <Icon name={modo === "entrar" ? "candado" : "check-circulo"} />
                {modo === "entrar" ? "Entrar a mi tarjeta" : "Activar mi tarjeta"}
              </>
            )}
          </button>

          <button type="button" className="enlace-sutil" onClick={() => setAyuda(true)}>
            ¿Olvidaste tu PIN o no tienes tarjeta?
          </button>
        </form>
      </section>

      <footer className="acceso__pie">
        {demo && (
          <p className="acceso__demo">
            <Icon name="rayo" />
            Demostración: <strong className="mono">V-12345678</strong> · PIN{" "}
            <strong className="mono">1234</strong>
          </p>
        )}
        <p className="acceso__legal">
          Al entrar aceptas las condiciones de uso de BLINK PASAJES. Tus datos se tratan
          según la política de privacidad de la línea.
        </p>
      </footer>

      <Hoja
        abierta={ayuda}
        alCerrar={() => setAyuda(false)}
        titulo="¿Necesitas ayuda?"
        descripcion="Tres caminos según lo que te pase."
      >
        <ul className="ayuda-lista">
          <li>
            <span className="ayuda-lista__icono">
              <Icon name="candado" />
            </span>
            <div>
              <strong>Olvidaste el PIN</strong>
              <p>
                Acércate a un punto de atención con tu cédula y la tarjeta. Un agente
                verifica tu identidad y restablece el PIN en el momento.
              </p>
            </div>
          </li>
          <li>
            <span className="ayuda-lista__icono">
              <Icon name="tarjeta" />
            </span>
            <div>
              <strong>Todavía no tienes tarjeta</strong>
              <p>
                La primera tarjeta se entrega en taquilla al comprar el primer viaje. Si ya
                la tienes y nunca la activaste, usa «Activar» con el serial impreso.
              </p>
            </div>
          </li>
          <li>
            <span className="ayuda-lista__icono">
              <Icon name="autobus" />
            </span>
            <div>
              <strong>Tu tarjeta no pasa en el lector</strong>
              <p>
                Acércala de nuevo al lector por 2 segundos. Si sigue sin responder, está
                dañada: te la reponen sin costo conservando el saldo.
              </p>
            </div>
          </li>
        </ul>
      </Hoja>
    </div>
  );
}
