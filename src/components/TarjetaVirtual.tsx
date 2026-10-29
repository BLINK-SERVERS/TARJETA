import { useRef, type PointerEvent } from "react";
import { Icon } from "./Icon";
import { formatearBs, formatearVence, nombreTarjeta, partesBs } from "../lib/formato";
import { pasajesEquivalentes } from "../lib/dominio";
import { useNumeroAnimado } from "../lib/hooks";
import type { Tarjeta } from "../lib/tipos";

interface Props {
  tarjeta: Tarjeta;
  saldoOculto: boolean;
  alAlternarSaldo: () => void;
}

export function TarjetaVirtual({ tarjeta, saldoOculto, alAlternarSaldo }: Props) {
  const ref = useRef<HTMLElement>(null);
  const saldo = useNumeroAnimado(tarjeta.saldo);
  const { entero, decimal } = partesBs(saldo);
  const pasajes = pasajesEquivalentes(tarjeta.saldo, tarjeta.tarifa);
  const bloqueada = tarjeta.estado === "bloqueada";

  function inclinar(evento: PointerEvent<HTMLElement>) {
    if (evento.pointerType !== "mouse") return;
    const caja = ref.current?.getBoundingClientRect();
    if (!caja) return;
    const x = (evento.clientX - caja.left) / caja.width - 0.5;
    const y = (evento.clientY - caja.top) / caja.height - 0.5;
    const estilo = ref.current!.style;
    estilo.setProperty("--ry", `${(x * 11).toFixed(2)}deg`);
    estilo.setProperty("--rx", `${(-y * 9).toFixed(2)}deg`);
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

  return (
    <article
      ref={ref}
      className={`tarjeta${bloqueada ? " tarjeta--bloqueada" : ""}`}
      onPointerMove={inclinar}
      onPointerLeave={reposar}
      aria-label={`Tarjeta BLINK de ${tarjeta.titular.nombre}, saldo ${formatearBs(
        tarjeta.saldo
      )}`}
    >
      <div className="tarjeta__brillo" aria-hidden="true" />
      <div className="tarjeta__orbes" aria-hidden="true">
        <span />
        <span />
      </div>

      <header className="tarjeta__cabecera">
        <span className="tarjeta__marca">
          BLINK<em>TARJETA</em>
        </span>
        <span className="tarjeta__red" aria-hidden="true">
          <svg viewBox="0 0 34 22" className="tarjeta__contacto">
            <path d="M3 4.5a14 14 0 0 1 0 13" />
            <path d="M9.5 2a18 18 0 0 1 0 18" />
            <path d="M16 0a22 22 0 0 1 0 22" />
          </svg>
        </span>
      </header>

      <div className="tarjeta__cuerpo">
        <span className="tarjeta__chip" aria-hidden="true">
          <span className="tarjeta__chip-lineas" />
        </span>
        <div className="tarjeta__saldo">
          <span className="tarjeta__etiqueta">Saldo disponible</span>
          <div className="tarjeta__monto">
            <span className="tarjeta__moneda">Bs</span>
            {saldoOculto ? (
              <strong aria-label="Saldo oculto">••••</strong>
            ) : (
              <strong aria-live="polite">
                {entero}
                <span className="tarjeta__decimalos">,{decimal}</span>
              </strong>
            )}
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
          <span className="tarjeta__pasajes">
            {tarjeta.estado === "bloqueada"
              ? "Tarjeta bloqueada · atención al cliente"
              : pasajes > 0
                ? `Alcanza para ${pasajes} ${pasajes === 1 ? "pasaje" : "pasajes"}`
                : "Sin saldo para viajar"}
          </span>
        </div>
      </div>

      <footer className="tarjeta__pie">
        <div className="tarjeta__dato tarjeta__dato--titular">
          <span className="tarjeta__etiqueta">Titular</span>
          <span className="tarjeta__firma">
            <strong>{nombreTarjeta(tarjeta.titular.nombre)}</strong>
            <span className="tarjeta__cedula">{tarjeta.titular.cedula}</span>
          </span>
        </div>
        <div className="tarjeta__dato tarjeta__dato--serial">
          <span className="tarjeta__etiqueta">Serial</span>
          <strong className="mono">{tarjeta.serial}</strong>
        </div>
        <div className="tarjeta__dato tarjeta__dato--vence">
          <span className="tarjeta__etiqueta">Vence</span>
          <strong className="mono">{formatearVence(tarjeta.vence)}</strong>
        </div>
      </footer>

      {bloqueada && (
        <div className="tarjeta__bloqueo">
          <Icon name="candado" />
          Bloqueada
        </div>
      )}
    </article>
  );
}
