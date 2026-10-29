import { useEffect, useId, useRef, type ReactNode } from "react";
import { Icon } from "./Icon";

interface Props {
  abierta: boolean;
  alCerrar: () => void;
  titulo: string;
  descripcion?: string;
  children: ReactNode;
  pie?: ReactNode;
}

/** Hoja modal al estilo iOS: sube desde abajo, fondo atenuado, esquinas 28. */
export function Hoja({ abierta, alCerrar, titulo, descripcion, children, pie }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const tituloId = useId();
  const descripcionId = useId();
  const devolverFoco = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!abierta) return;
    devolverFoco.current = document.activeElement as HTMLElement | null;
    const overflowPrevio = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const t = window.setTimeout(() => panel.current?.focus(), 60);

    function alTeclear(evento: KeyboardEvent) {
      if (evento.key === "Escape") {
        evento.preventDefault();
        alCerrar();
      }
    }
    document.addEventListener("keydown", alTeclear);
    return () => {
      window.clearTimeout(t);
      document.removeEventListener("keydown", alTeclear);
      document.body.style.overflow = overflowPrevio;
      devolverFoco.current?.focus?.();
    };
  }, [abierta, alCerrar]);

  if (!abierta) return null;

  return (
    <div className="hoja-fondo" onClick={alCerrar}>
      <div
        ref={panel}
        className="hoja"
        role="dialog"
        aria-modal="true"
        aria-labelledby={tituloId}
        aria-describedby={descripcion ? descripcionId : undefined}
        tabIndex={-1}
        onClick={(evento) => evento.stopPropagation()}
      >
        <span className="hoja__asa" aria-hidden="true" />
        <header className="hoja__cabecera">
          <div>
            <h2 className="hoja__titulo" id={tituloId}>
              {titulo}
            </h2>
            {descripcion && (
              <p className="hoja__descripcion" id={descripcionId}>
                {descripcion}
              </p>
            )}
          </div>
          <button
            type="button"
            className="boton-icono"
            onClick={alCerrar}
            aria-label="Cerrar"
          >
            <Icon name="cerrar" />
          </button>
        </header>
        <div className="hoja__cuerpo">{children}</div>
        {pie && <footer className="hoja__pie">{pie}</footer>}
      </div>
    </div>
  );
}
