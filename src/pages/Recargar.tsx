import { useMemo, useRef, useState, type FormEvent } from "react";
import { Icon } from "../components/Icon";
import { ErrorBlink } from "../lib/repo";
import { CAMPOS_RECARGA, buscarRecargaDuplicada, erroresRecarga, pasajesEquivalentes } from "../lib/dominio";
import type { BorradorRecarga, CampoRecarga, ErroresRecarga } from "../lib/dominio";
import { formatearBs, formatearEntero, formatearMovimiento, formatearTelefono, soloDigitos } from "../lib/formato";
import { useCopiar } from "../lib/hooks";
import { BANCOS } from "../lib/tipos";
import type { Ajustes, DatosPago, Movimiento, RecargaNueva, Tarjeta } from "../lib/tipos";

type Paso = "monto" | "pago" | "revision" | "listo";

const MONTOS = [50, 100, 200, 500];
const PASOS: { id: Paso; etiqueta: string }[] = [
  { id: "monto", etiqueta: "Monto" },
  { id: "pago", etiqueta: "Pago" },
  { id: "revision", etiqueta: "Confirmar" },
];



interface Props {
  tarjeta: Tarjeta;
  datosPago: DatosPago;
  ajustes: Ajustes;
  movimientos: Movimiento[];
  alReportar: (recarga: RecargaNueva) => Promise<Movimiento>;
  alInicio: () => void;
  alVerMovimientos: () => void;
  alEditarPago: () => void;
}

export function Recargar({
  tarjeta,
  datosPago,
  ajustes,
  movimientos,
  alReportar,
  alInicio,
  alVerMovimientos,
  alEditarPago,
}: Props) {
  const [paso, setPaso] = useState<Paso>("monto");
  const [borrador, setBorrador] = useState<BorradorRecarga>(() => ({
    monto: "",
    telefono: formatearTelefono(datosPago.telefono),
    banco: datosPago.banco,
    referencia: "",
  }));
  const [errores, setErrores] = useState<ErroresRecarga>({});
  const [aviso, setAviso] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [reportada, setReportada] = useState<Movimiento | null>(null);
  const [copiado, copiar] = useCopiar();
  const titulo = useRef<HTMLHeadingElement>(null);

  const monto = Number(borrador.monto);
  const montoValido = Number.isFinite(monto) && monto > 0;
  const saldoResultante = tarjeta.saldo + (montoValido ? monto : 0);
  const pasajesNuevos = pasajesEquivalentes(saldoResultante, tarjeta.tarifa);

  const indicePaso = PASOS.findIndex((p) => p.id === paso);

  const pagoMovil = ajustes.pagoMovil;

  function irA(nuevo: Paso) {
    setPaso(nuevo);
    setAviso(null);
    window.setTimeout(() => titulo.current?.focus(), 40);
  }

  function cambiar(campo: CampoRecarga, valor: string) {
    setBorrador((actual) => ({ ...actual, [campo]: valor }));
    setErrores((actual) => {
      if (!actual[campo]) return actual;
      const siguiente = { ...actual };
      delete siguiente[campo];
      return siguiente;
    });
  }

  function enfocar(campo: CampoRecarga) {
    requestAnimationFrame(() => document.getElementById(`rc-${campo}`)?.focus());
  }

  function validarMonto() {
    const problemas = erroresRecarga({ ...borrador, telefono: "04140000000", banco: "Otro", referencia: "0000" }, ajustes);
    if (problemas.monto) {
      setErrores({ monto: problemas.monto });
      enfocar("monto");
      return false;
    }
    setErrores({});
    return true;
  }

  function continuarMonto(evento: FormEvent) {
    evento.preventDefault();
    if (validarMonto()) irA("pago");
  }

  function continuarPago(evento: FormEvent) {
    evento.preventDefault();
    const problemas = erroresRecarga(borrador, ajustes);
    const primerCampo = CAMPOS_RECARGA.find((campo) => problemas[campo]);
    if (primerCampo) {
      setErrores(problemas);
      enfocar(primerCampo);
      return;
    }

    const duplicada = buscarRecargaDuplicada(movimientos, {
      banco: borrador.banco,
      referencia: borrador.referencia,
    });
    if (duplicada) {
      setErrores({
        referencia: `Ya reportaste esta referencia el ${formatearMovimiento(duplicada.at)}. Revisa «Movimientos».`,
      });
      enfocar("referencia");
      return;
    }

    setErrores({});
    irA("revision");
  }

  async function confirmar() {
    if (enviando) return;
    setEnviando(true);
    setAviso(null);
    try {
      const movimiento = await alReportar({
        monto: Math.round(monto * 100) / 100,
        telefono: soloDigitos(borrador.telefono),
        banco: borrador.banco,
        referencia: soloDigitos(borrador.referencia).slice(-4),
      });
      setReportada(movimiento);
      irA("listo");
    } catch (error) {
      setAviso(
        error instanceof ErrorBlink
          ? error.message
          : "No pudimos registrar el reporte. Inténtalo otra vez."
      );
      if (error instanceof ErrorBlink && error.codigo === "duplicada") {
        setPaso("pago");
        enfocar("referencia");
      }
    } finally {
      setEnviando(false);
    }
  }

  function otraRecarga() {
    setBorrador({
      monto: "",
      telefono: formatearTelefono(datosPago.telefono),
      banco: datosPago.banco,
      referencia: "",
    });
    setReportada(null);
    setErrores({});
    irA("monto");
  }

  const comprobante = useMemo(() => {
    if (!reportada) return "";
    return [
      "BLINK PASAJES — reporte de recarga",
      `Tarjeta: ${tarjeta.serial}`,
      `Titular: ${tarjeta.titular.nombre}`,
      `Monto: ${formatearBs(reportada.monto)}`,
      `Banco: ${reportada.banco ?? ""}`,
      `Teléfono: ${formatearTelefono(reportada.referencia ? borrador.telefono || "" : "")}`,
      `Referencia: ${reportada.referencia ?? ""}`,
      `Fecha: ${formatearMovimiento(reportada.at)}`,
      "Estado: en revisión (Admin confirma el Pago Móvil)",
    ].join("\n");
  }, [reportada, tarjeta, borrador.telefono]);

  if (paso === "listo" && reportada) {
    return (
      <div className="vista">
        <section className="exito" aria-live="polite">
          <span className="exito__sello">
            <Icon name="check" />
          </span>
          <h1 className="exito__titulo">Recarga reportada</h1>
          <p className="exito__texto">
            Registramos tu Pago Móvil de <strong>{formatearBs(reportada.monto)}</strong>. El
            saldo se acredita cuando Admin confirme la referencia{" "}
            <span className="mono">{reportada.referencia}</span>.
          </p>
          <dl className="datos">
            <div>
              <dt>Tarjeta</dt>
              <dd className="mono">{tarjeta.serial}</dd>
            </div>
            <div>
              <dt>Banco emisor</dt>
              <dd>{reportada.banco}</dd>
            </div>
            <div>
              <dt>Fecha</dt>
              <dd>{formatearMovimiento(reportada.at)}</dd>
            </div>
            <div>
              <dt>Estado</dt>
              <dd>
                <span className="etiqueta etiqueta--espera">En revisión</span>
              </dd>
            </div>
          </dl>
          <div className="exito__acciones">
            <button
              type="button"
              className="boton boton--primario"
              onClick={() => void copiar(comprobante, "comprobante")}
            >
              <Icon name={copiado === "comprobante" ? "check" : "copiar"} />
              {copiado === "comprobante" ? "Comprobante copiado" : "Copiar comprobante"}
            </button>
            <button type="button" className="boton boton--secundario" onClick={otraRecarga}>
              Reportar otra recarga
            </button>
            <button type="button" className="enlace-sutil" onClick={alVerMovimientos}>
              Ver mis movimientos
            </button>
            <button type="button" className="enlace-sutil" onClick={alInicio}>
              Volver al inicio
            </button>
          </div>
        </section>
      </div>
    );
  }

  return (
    <div className="vista">
      <header className="cabecera cabecera--titulo">
        <h1 className="cabecera__titulo cabecera__titulo--grande">Recargar</h1>
        <p className="cabecera__sub">Tarjeta {tarjeta.serial}</p>
      </header>

      <ol className="progreso" aria-label={`Paso ${indicePaso + 1} de ${PASOS.length}`}>
        {PASOS.map((item, indice) => (
          <li
            key={item.id}
            className={`progreso__paso${indice <= indicePaso ? " progreso__paso--hecho" : ""}${
              indice === indicePaso ? " progreso__paso--actual" : ""
            }`}
            aria-current={indice === indicePaso ? "step" : undefined}
          >
            <span className="progreso__numero">{indice + 1}</span>
            <span className="progreso__nombre">{item.etiqueta}</span>
          </li>
        ))}
      </ol>

      <h2 className="paso-titulo" tabIndex={-1} ref={titulo}>
        {paso === "monto"
          ? "¿Cuánto vas a recargar?"
          : paso === "pago"
            ? "Datos del Pago Móvil"
            : "Revisa antes de reportar"}
      </h2>

      {paso === "monto" && (
        <form className="tarjeta-panel" onSubmit={continuarMonto} noValidate>
          <div className="chips" role="group" aria-label="Montos frecuentes">
            {MONTOS.map((valor) => (
              <button
                key={valor}
                type="button"
                className={`chip${borrador.monto === String(valor) ? " chip--activo" : ""}`}
                aria-pressed={borrador.monto === String(valor)}
                onClick={() => {
                  cambiar("monto", String(valor));
                  setErrores({});
                }}
              >
                {formatearEntero(valor)}
                <span>Bs</span>
              </button>
            ))}
          </div>

          <div className="campo">
            <label className="campo__etiqueta" htmlFor="rc-monto">
              Otro monto (Bs)
            </label>
            <input
              id="rc-monto"
              className="entrada entrada--cifra"
              type="number"
              min="1"
              step="0.01"
              inputMode="decimal"
              placeholder="0,00"
              value={borrador.monto}
              onChange={(evento) => cambiar("monto", evento.target.value)}
              aria-invalid={errores.monto ? true : undefined}
              aria-describedby={errores.monto ? "rc-monto-error" : "rc-monto-ayuda"}
            />
            <span className="campo__ayuda" id="rc-monto-ayuda">
              Tope por operación: {formatearBs(ajustes.topeRecarga)}. Si transferiste más,
              divide el pago en varias referencias.
            </span>
            {errores.monto && (
              <p className="campo__error" id="rc-monto-error">
                {errores.monto}
              </p>
            )}
          </div>

          <div className="proyeccion">
            <div>
              <span>Saldo actual</span>
              <strong>{formatearBs(tarjeta.saldo)}</strong>
            </div>
            <Icon name="adelante" />
            <div>
              <span>Saldo al aprobarse</span>
              <strong className="proyeccion__nuevo">{formatearBs(saldoResultante)}</strong>
            </div>
          </div>
          {montoValido && (
            <p className="proyeccion__pasajes">
              <Icon name="autobus" />
              Te quedarían {pasajesNuevos} {pasajesNuevos === 1 ? "pasaje" : "pasajes"} a{" "}
              {formatearBs(tarjeta.tarifa)}.
            </p>
          )}

          <button type="submit" className="boton boton--primario">
            Continuar
            <Icon name="adelante" />
          </button>
        </form>
      )}

      {paso === "pago" && (
        <>
          <section className="pago-movil">
            <header className="pago-movil__cabecera">
              <span className="pago-movil__icono">
                <Icon name="banco" />
              </span>
              <div>
                <strong>Paga a BLINK</strong>
                <p>Desde tu banco, con Pago Móvil.</p>
              </div>
            </header>
            <dl className="datos datos--copiar">
              {[
                ["Banco", pagoMovil.banco, "banco"],
                ["RIF", pagoMovil.rif, "rif"],
                ["Teléfono", pagoMovil.telefono, "telefono-pm"],
                ["Titular", pagoMovil.titular, "titular"],
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
            <button
              type="button"
              className="boton boton--secundario boton--compacto"
              onClick={() =>
                void copiar(
                  `${pagoMovil.banco}\n${pagoMovil.rif}\n${pagoMovil.telefono}\n${pagoMovil.titular}`,
                  "todo"
                )
              }
            >
              <Icon name={copiado === "todo" ? "check" : "copiar"} />
              {copiado === "todo" ? "Datos copiados" : "Copiar datos"}
            </button>
            <p className="pago-movil__monto">
              Transfiere exactamente <strong>{formatearBs(montoValido ? monto : 0)}</strong>.
            </p>
          </section>

          <form className="tarjeta-panel" onSubmit={continuarPago} noValidate>
            <p className="form-titulo">Ahora reporta el pago</p>

            <div className="fuente-pago">
              <span className="fuente-pago__icono">
                <Icon name="banco" />
              </span>
              <div className="fuente-pago__texto">
                <strong>
                  {datosPago.banco ? `Pagas desde ${datosPago.banco}` : "Elige tu banco emisor"}
                </strong>
                <span className="mono">
                  {formatearTelefono(datosPago.telefono)} · {datosPago.cedula}
                </span>
              </div>
              <button type="button" className="seccion__enlace" onClick={alEditarPago}>
                Cambiar
              </button>
            </div>

            <div className="campo">
              <label className="campo__etiqueta" htmlFor="rc-banco">
                Banco emisor
              </label>
              <select
                id="rc-banco"
                className="entrada"
                value={borrador.banco}
                onChange={(evento) => cambiar("banco", evento.target.value)}
                aria-invalid={errores.banco ? true : undefined}
                aria-describedby={errores.banco ? "rc-banco-error" : undefined}
              >
                <option value="">Selecciona…</option>
                {BANCOS.map((banco) => (
                  <option key={banco.codigo} value={banco.nombre}>
                    {banco.codigo} · {banco.nombre}
                  </option>
                ))}
              </select>
              {errores.banco && (
                <p className="campo__error" id="rc-banco-error">
                  {errores.banco}
                </p>
              )}
            </div>

            <div className="campo">
              <label className="campo__etiqueta" htmlFor="rc-telefono">
                Teléfono desde el que pagaste
              </label>
              <input
                id="rc-telefono"
                className="entrada mono"
                type="tel"
                inputMode="tel"
                autoComplete="tel-national"
                placeholder="0414-1234567"
                maxLength={12}
                value={borrador.telefono}
                onChange={(evento) => cambiar("telefono", formatearTelefono(evento.target.value))}
                aria-invalid={errores.telefono ? true : undefined}
                aria-describedby={errores.telefono ? "rc-telefono-error" : undefined}
              />
              {errores.telefono && (
                <p className="campo__error" id="rc-telefono-error">
                  {errores.telefono}
                </p>
              )}
            </div>

            <div className="campo">
              <label className="campo__etiqueta" htmlFor="rc-referencia">
                Últimos 4 dígitos de la referencia
              </label>
              <input
                id="rc-referencia"
                className="entrada mono"
                inputMode="numeric"
                autoComplete="off"
                maxLength={4}
                placeholder="1234"
                value={borrador.referencia}
                onChange={(evento) =>
                  cambiar("referencia", soloDigitos(evento.target.value).slice(0, 4))
                }
                aria-invalid={errores.referencia ? true : undefined}
                aria-describedby={errores.referencia ? "rc-referencia-error" : "rc-referencia-ayuda"}
              />
              <span className="campo__ayuda" id="rc-referencia-ayuda">
                Aparece en el comprobante que te dio tu banco.
              </span>
              {errores.referencia && (
                <p className="campo__error" id="rc-referencia-error">
                  {errores.referencia}
                </p>
              )}
            </div>

            {aviso && (
              <div className="aviso aviso--peligro" role="alert">
                <Icon name="alerta" />
                <p>{aviso}</p>
              </div>
            )}

            <div className="acciones-paso">
              <button type="button" className="boton boton--fantasma" onClick={() => irA("monto")}>
                <Icon name="atras" />
                Atrás
              </button>
              <button type="submit" className="boton boton--primario">
                Revisar
                <Icon name="adelante" />
              </button>
            </div>
          </form>
        </>
      )}

      {paso === "revision" && (
        <section className="tarjeta-panel">
          <dl className="datos">
            <div>
              <dt>Tarjeta</dt>
              <dd className="mono">{tarjeta.serial}</dd>
            </div>
            <div>
              <dt>Monto</dt>
              <dd className="mono">{formatearBs(monto)}</dd>
            </div>
            <div>
              <dt>Banco emisor</dt>
              <dd>{borrador.banco}</dd>
            </div>
            <div>
              <dt>Teléfono</dt>
              <dd className="mono">{formatearTelefono(borrador.telefono)}</dd>
            </div>
            <div>
              <dt>Referencia</dt>
              <dd className="mono">…{borrador.referencia}</dd>
            </div>
            <div>
              <dt>Pasajes</dt>
              <dd>
                +{pasajesEquivalentes(monto, tarjeta.tarifa)} a{" "}
                {formatearBs(tarjeta.tarifa)}
              </dd>
            </div>
          </dl>

          {aviso && (
            <div className="aviso aviso--peligro" role="alert">
              <Icon name="alerta" />
              <p>{aviso}</p>
            </div>
          )}

          <div className="aviso aviso--info">
            <Icon name="escudo" />
            <p>
              Al confirmar, tu reporte queda en revisión. Admin verifica el Pago Móvil y
              acredita el saldo; normalmente en minutos.
            </p>
          </div>

          <div className="acciones-paso">
            <button type="button" className="boton boton--fantasma" onClick={() => irA("pago")}>
              <Icon name="atras" />
              Editar
            </button>
            <button
              type="button"
              className="boton boton--primario"
              onClick={() => void confirmar()}
              disabled={enviando}
            >
              {enviando ? (
                <span className="girador" aria-label="Enviando" />
              ) : (
                <>
                  <Icon name="check" />
                  Confirmar recarga
                </>
              )}
            </button>
          </div>
        </section>
      )}
    </div>
  );
}
