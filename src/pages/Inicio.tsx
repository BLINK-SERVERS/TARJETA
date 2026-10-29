import { useMemo } from "react";
import { Icon } from "../components/Icon";
import { MovimientoFila } from "../components/MovimientoFila";
import { TarjetaVirtual } from "../components/TarjetaVirtual";
import { formatearBs, formatearEntero, iniciales } from "../lib/formato";
import { pasajesEquivalentes } from "../lib/dominio";
import type { Movimiento, Tarjeta } from "../lib/tipos";

interface Props {
  tarjeta: Tarjeta;
  movimientos: Movimiento[];
  saldoOculto: boolean;
  alAlternarSaldo: () => void;
  alRecargar: () => void;
  alVerMovimientos: () => void;
  alVerPerfil: () => void;
  alAbrirPagoMovil: () => void;
}

function saludo(): string {
  const hora = new Date().getHours();
  if (hora < 12) return "Buenos días";
  if (hora < 19) return "Buenas tardes";
  return "Buenas noches";
}

export function Inicio({
  tarjeta,
  movimientos,
  saldoOculto,
  alAlternarSaldo,
  alRecargar,
  alVerMovimientos,
  alVerPerfil,
  alAbrirPagoMovil,
}: Props) {
  const nombre = tarjeta.titular.nombre.split(" ")[0] ?? "";
  const recientes = movimientos.slice(0, 4);
  const pendiente = movimientos.find((m) => m.estado === "pendiente");
  const pasajes = pasajesEquivalentes(tarjeta.saldo, tarjeta.tarifa);

  const mes = useMemo(() => {
    const ahora = new Date();
    const delMes = movimientos.filter((m) => {
      const fecha = new Date(m.at);
      return (
        fecha.getMonth() === ahora.getMonth() &&
        fecha.getFullYear() === ahora.getFullYear() &&
        m.estado === "aprobado"
      );
    });
    return {
      viajes: delMes.filter((m) => m.tipo === "viaje").length,
      recargado: delMes
        .filter((m) => m.tipo === "recarga")
        .reduce((total, m) => total + m.monto, 0),
    };
  }, [movimientos]);

  return (
    <div className="vista vista--inicio">
      <header className="cabecera">
        <div>
          <span className="cabecera__saludo">{saludo()}</span>
          <h1 className="cabecera__titulo">{nombre}</h1>
        </div>
        <button
          type="button"
          className="avatar"
          onClick={alVerPerfil}
          aria-label={`Perfil de ${tarjeta.titular.nombre}`}
        >
          {iniciales(tarjeta.titular.nombre)}
        </button>
      </header>

      {pendiente && (
        <button type="button" className="banda" onClick={alVerMovimientos}>
          <span className="banda__icono">
            <Icon name="reloj" />
          </span>
          <span className="banda__texto">
            <strong>Recarga en revisión</strong>
            <span>
              {formatearBs(pendiente.monto)} · {pendiente.banco ?? "Pago Móvil"} · Ref.{" "}
              {pendiente.referencia}
            </span>
          </span>
          <Icon name="adelante" className="banda__flecha" />
        </button>
      )}

      <TarjetaVirtual tarjeta={tarjeta} saldoOculto={saldoOculto} alAlternarSaldo={alAlternarSaldo} />

      <div className="acciones" role="group" aria-label="Acciones de la tarjeta">
        <button type="button" className="accion accion--principal" onClick={alRecargar}>
          <span className="accion__icono">
            <Icon name="recargar" />
          </span>
          <span>Recargar</span>
        </button>
        <button type="button" className="accion" onClick={alVerMovimientos}>
          <span className="accion__icono">
            <Icon name="movimientos" />
          </span>
          <span>Movimientos</span>
        </button>
        <button type="button" className="accion" onClick={alAbrirPagoMovil}>
          <span className="accion__icono">
            <Icon name="banco" />
          </span>
          <span>Pago Móvil</span>
        </button>
        <button type="button" className="accion" onClick={alVerPerfil}>
          <span className="accion__icono">
            <Icon name="escudo" />
          </span>
          <span>Mi tarjeta</span>
        </button>
      </div>

      <div className="tiles">
        <div className="tile">
          <span className="tile__etiqueta">Viajes este mes</span>
          <strong className="tile__valor">{mes.viajes}</strong>
          <span className="tile__pie">{formatearBs(tarjeta.tarifa)} por pasaje</span>
        </div>
        <div className="tile">
          <span className="tile__etiqueta">Recargado este mes</span>
          <strong className="tile__valor">{formatearEntero(mes.recargado)}</strong>
          <span className="tile__pie">bolívares acreditados</span>
        </div>
      </div>

      <section className="seccion">
        <div className="seccion__cabecera">
          <h2 className="seccion__titulo">Últimos movimientos</h2>
          <button type="button" className="seccion__enlace" onClick={alVerMovimientos}>
            Ver todos
          </button>
        </div>
        {recientes.length > 0 ? (
          <ul className="lista-movimientos">
            {recientes.map((movimiento) => (
              <MovimientoFila key={movimiento.id} movimiento={movimiento} />
            ))}
          </ul>
        ) : (
          <p className="vacio">Todavía no hay movimientos en esta tarjeta.</p>
        )}
      </section>

      {pasajes <= 2 && tarjeta.estado === "activa" && (
        <section className="aviso-tarjeta">
          <div className="aviso-tarjeta__texto">
            <Icon name="rayo" />
            <div>
              <strong>{pasajes === 0 ? "Te quedaste sin saldo" : "Te queda poco saldo"}</strong>
              <p>
                {pasajes === 0
                  ? "Recarga ahora y sigue viajando sin bajar de la unidad."
                  : `Con ${formatearBs(tarjeta.saldo)} te alcanza para ${pasajes} ${
                      pasajes === 1 ? "pasaje" : "pasajes"
                    }.`}
              </p>
            </div>
          </div>
          <button type="button" className="boton boton--secundario boton--compacto" onClick={alRecargar}>
            Recargar
          </button>
        </section>
      )}

      <p className="pie-marca">
        BLINK PASAJES · tarjeta recargable
      </p>
    </div>
  );
}
