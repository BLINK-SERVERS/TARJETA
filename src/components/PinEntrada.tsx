import { useEffect, useRef } from "react";
import { soloDigitos } from "../lib/formato";

interface Props {
  valor: string;
  alCambiar: (pin: string) => void;
  alCompletar?: (pin: string) => void;
  error?: boolean;
  etiqueta?: string;
  autoFocus?: boolean;
  deshabilitado?: boolean;
}

/** PIN de 4 dígitos con cajas, como el campo de clave de iOS. */
export function PinEntrada({
  valor,
  alCambiar,
  alCompletar,
  error = false,
  etiqueta = "PIN de 4 dígitos",
  autoFocus = false,
  deshabilitado = false,
}: Props) {
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (autoFocus) {
      const t = window.setTimeout(() => input.current?.focus(), 320);
      return () => window.clearTimeout(t);
    }
  }, [autoFocus]);

  return (
    <div
      className={`pin${error ? " pin--error" : ""}${deshabilitado ? " pin--off" : ""}`}
      onClick={() => input.current?.focus()}
    >
      {[0, 1, 2, 3].map((indice) => (
        <span
          key={indice}
          className={`pin__caja${valor.length === indice ? " pin__caja--activa" : ""}${
            valor[indice] ? " pin__caja--llena" : ""
          }`}
          aria-hidden="true"
        >
          {valor[indice] ? "•" : ""}
        </span>
      ))}
      <input
        ref={input}
        className="pin__input"
        type="password"
        inputMode="numeric"
        autoComplete="one-time-code"
        pattern="[0-9]*"
        maxLength={4}
        value={valor}
        aria-label={etiqueta}
        aria-invalid={error || undefined}
        disabled={deshabilitado}
        onChange={(evento) => {
          const limpio = soloDigitos(evento.target.value).slice(0, 4);
          alCambiar(limpio);
          if (limpio.length === 4) alCompletar?.(limpio);
        }}
      />
    </div>
  );
}
