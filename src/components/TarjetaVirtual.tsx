import { useMemo, useRef, useState, type PointerEvent } from "react";
import { Icon } from "./Icon";
import {
  formatearBs,
  formatearVence,
  nombreTarjeta,
  partesBs,
  soloDigitos,
} from "../lib/formato";
import { pasajesEquivalentes, perfilTarifa } from "../lib/dominio";
import { useCopiar, useNumeroAnimado, vibrar } from "../lib/hooks";
import { QR_PORTAL, svgCode128 } from "../lib/codigos";
import type { Tarjeta } from "../lib/tipos";

interface Props {
  tarjeta: Tarjeta;
  saldoOculto: boolean;
  alAlternarSaldo: () => void;
}

type NivelPasajes = "ok" | "bajo" | "sin-saldo";

function nivelPasajes(pasajes: number): NivelPasajes {
  if (pasajes === 0) return "sin-saldo";
  return pasajes <= 2 ? "bajo" : "ok";
}

function textoPasajes(pasajes: number): string {
  if (pasajes === 0) return "Saldo insuficiente — Recarga ahora";
  if (pasajes === 1) return "Te alcanza para 1 pasaje";
  return `Te alcanza para ${pasajes} pasajes`;
}

export function TarjetaVirtual({ tarjeta, saldoOculto, alAlternarSaldo }: Props) {
  const [girado, setGirado] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const botonInstrumento = useRef<HTMLButtonElement>(null);
  const botonFrente = useRef<HTMLButtonElement>(null);
  const [copiado, copiar] = useCopiar();

  const saldo = useNumeroAnimado(tarjeta.saldo);
  const { entero, decimal } = partesBs(saldo);
  const pasajes = pasajesEquivalentes(tarjeta.saldo, tarjeta.tarifa);
  const perfil = perfilTarifa(tarjeta.serial);
  const bloqueada = tarjeta.estado === "bloqueada";
  const nivel = nivelPasajes(pasajes);
  const barras = useMemo(() => svgCode128(tarjeta.serial), [tarjeta.serial]);

  function inclinar(evento: PointerEvent<HTMLElement>) {
    if (girado || evento.pointerType !== "mouse") return;
    const caja = ref.current?.getBoundingClientRect();
    if (!caja) return;
    const x = (evento.clientX - caja.left) / caja.width - 0.5;
    const y = (evento.clientY - caja.top) / caja.height - 0.5;
    const estilo = ref.current!.style;
    estilo.setProperty("--ry", `${(x * 8).toFixed(2)}deg`);
    estilo.setProperty("--rx", `${(-y * 7).toFixed(2)}deg`);
    estilo.setProperty("--brillo-x", `${((x + 0.5) * 100).toFixed(1)}%`);
    estilo.setProperty("--brillo-y", `${((y + 0.5) * 100).toFixed(1)}%`);
  }

  function reposar() {
    const estilo = ref.current?.style;
    if (!estilo) return;
    estilo.setProperty("--ry", "0deg");
    estilo.setProperty("--rx", "0deg");
    estilo.setProperty("--brillo-x", "62%");
    estilo.setProperty("--brillo-y", "0%");
  }

  function girar(destino: boolean) {
    if (destino === girado) return;
    setGirado(destino);
    reposar();
    vibrar(6);
    const siguiente = destino ? botonFrente : botonInstrumento;
    requestAnimationFrame(() => siguiente.current?.focus());
  }

  const iconoCopiado =
    copiado === "serial" ? "check" : copiado === "error" ? "alerta" : "copiar";

  return (
    <div className={`tarjeta-caja${bloqueada ? " tarjeta-caja--bloqueada" : ""}`}>
      <div
        ref={ref}
        className="tarjeta"
        onPointerMove={inclinar}
        onPointerLeave={reposar}
        aria-label={`Tarjeta BLINK de ${tarjeta.titular.nombre}, perfil ${perfil.toLowerCase()}, saldo ${formatearBs(
          tarjeta.saldo
        )}${bloqueada ? ", bloqueada" : ""}`}
        role="group"
      >
        <div className="tarjeta__inclinacion">
          <div className={`tarjeta__giro${girado ? " tarjeta__giro--volteada" : ""}`}>
            <article
              className={`tarjeta__cara tarjeta__cara--anverso${bloqueada ? " tarjeta__cara--bloqueada" : ""}`}
              inert={girado}
              aria-hidden={girado}
            >
              <div className="tarjeta__brillo" aria-hidden="true" />
              <div className="tarjeta__orbes" aria-hidden="true">
                <span />
                <span />
              </div>

              <header className="tarjeta__cabecera">
                <span className="tarjeta__marca">
                  <span className="tarjeta__logo">BLINK</span>
                  <svg className="tarjeta__guiño" viewBox="0 0 26 14" aria-hidden="true">
                    <rect x="0" y="2" width="10" height="3.4" rx="1.7" />
                    <circle cx="18.4" cy="3.7" r="3.4" />
                    <path d="M10.4 9.2h10.2a5.1 5.1 0 0 1-10.2 0Z" />
                  </svg>
                  <em>PASAJES</em>
                </span>

                <span
                  className={`tarjeta__pastilla${bloqueada ? " tarjeta__pastilla--bloqueada" : ""}`}
                  title={`Perfil tarifario ${perfil.toLowerCase()}`}
                >
                  <span className="tarjeta__punto" aria-hidden="true" />
                  {bloqueada ? "Bloqueada" : perfil}
                </span>
              </header>

              <div className="tarjeta__nucleo">
                <span className="tarjeta__etiqueta">Saldo disponible</span>
                <div className="tarjeta__monto">
                  {saldoOculto ? (
                    <strong aria-label="Saldo oculto">••••</strong>
                  ) : (
                    <strong aria-live="polite">
                      {entero}
                      <span className="tarjeta__decimalos">,{decimal}</span>
                    </strong>
                  )}
                  <span className="tarjeta__moneda">Bs</span>
                  <button
                    type="button"
                    className="tarjeta__ojo"
                    onClick={alAlternarSaldo}
                    aria-pressed={saldoOculto}
                    aria-label={saldoOculto ? "Mostrar saldo" : "Ocultar saldo"}
                  >
                    <Icon name={saldoOculto ? "ojo-tachado" : "ojo"} />
                  </button>
                </div>

                <span className={`tarjeta__capsula tarjeta__capsula--${nivel}`}>
                  <Icon name={nivel === "sin-saldo" ? "alerta" : "autobus"} />
                  {textoPasajes(pasajes)}
                </span>
              </div>

              <footer className="tarjeta__pie">
                <div className="tarjeta__identidad">
                  <span className="tarjeta__titular">{nombreTarjeta(tarjeta.titular.nombre)}</span>
                  <span className="tarjeta__serial">
                    <span className="mono">
                      ID: <strong>{tarjeta.serial}</strong>
                    </span>
                    <button
                      type="button"
                      className={`tarjeta__copiar${copiado === "serial" ? " tarjeta__copiar--hecho" : ""}`}
                      onClick={() => void copiar(soloDigitos(tarjeta.serial), "serial")}
                      aria-label={copiado === "serial" ? "Número copiado" : "Copiar número de tarjeta"}
                      title="Copiar número de tarjeta"
                    >
                      <Icon name={iconoCopiado} />
                    </button>
                  </span>
                </div>

                <div className="tarjeta__acciones">
                  <button
                    ref={botonInstrumento}
                    type="button"
                    className="tarjeta__voltear"
                    onClick={() => girar(true)}
                    aria-pressed={girado}
                    aria-label="Ver reverso y código de barras"
                  >
                    <Icon name="actualizar" />
                    <span>Reverso</span>
                  </button>
                  <svg viewBox="0 0 34 22" className="tarjeta__contacto" aria-hidden="true">
                    <path d="M3 4.5a14 14 0 0 1 0 13" />
                    <path d="M9.5 2a18 18 0 0 1 0 18" />
                    <path d="M16 0a22 22 0 0 1 0 22" />
                  </svg>
                </div>
              </footer>
            </article>

            <article
              className="tarjeta__cara tarjeta__cara--reverso"
              inert={!girado}
              aria-hidden={!girado}
            >
              <div className="tarjeta__reverso">
                <div className="tarjeta__reverso-texto">
                  <h3 className="tarjeta__lema">¡Modernicemos juntos el transporte público!</h3>

                  <div className="tarjeta__recarga">
                    <div className="tarjeta__qr">
                      <img src={QR_PORTAL} alt="Código QR para recargar en el portal BLINK" />
                    </div>
                    <div>
                      <p className="tarjeta__recarga-titulo">Código de recarga</p>
                      <p className="tarjeta__recarga-texto">
                        Muestra este código o usa tu ID para recargar por Pago Móvil.
                      </p>
                    </div>
                  </div>

                  <div className="tarjeta__reverso-pie">
                    <span>
                      Vence {formatearVence(tarjeta.vence)} · protegida con validación ISO Luhn
                    </span>
                    <button
                      ref={botonFrente}
                      type="button"
                      className="tarjeta__voltear tarjeta__voltear--claro"
                      onClick={() => girar(false)}
                      aria-pressed={girado}
                      aria-label="Volver al frente de la tarjeta"
                    >
                      <Icon name="actualizar" />
                      <span>Frente</span>
                    </button>
                  </div>
                </div>

                <div className="tarjeta__franja">
                  <span className="tarjeta__franja-serial mono">{tarjeta.serial}</span>
                  {barras ? (
                    <img
                      className="tarjeta__barras"
                      src={barras}
                      alt={`Código de barras de la tarjeta ${tarjeta.serial}`}
                    />
                  ) : (
                    <span className="tarjeta__barras-espera" aria-hidden="true" />
                  )}
                  <span className="tarjeta__franja-etiqueta">Número de tarjeta</span>
                </div>
              </div>
            </article>
          </div>
        </div>
      </div>

      <p className="tarjeta__sincro">
        <Icon name="escudo" />
        Sincronizado con la red BLINK · Tarifa actual {formatearBs(tarjeta.tarifa)}
      </p>
      <span className="visualmente-oculto" role="status">
        {girado ? "Mostrando el reverso de la tarjeta" : "Mostrando el frente de la tarjeta"}
      </span>
    </div>
  );
}
