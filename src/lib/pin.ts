// PIN local: PBKDF2-SHA-256 con sal por tarjeta.
//
// En la nube el PIN nunca sale del teléfono en claro hacia una tabla: viaja
// por HTTPS a una función `security definer` que compara con `crypt()` de
// pgcrypto. Aquí, en modo sin conexión, se guarda el mismo formato de
// verificación (sal + hash + iteraciones) para que el PIN tampoco quede
// escrito en localStorage.

const ITERACIONES = 150_000;

function aBase64(bytes: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

function deBase64(texto: string): Uint8Array {
  return Uint8Array.from(atob(texto), (c) => c.charCodeAt(0));
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function hashPin(pin: string, sal?: Uint8Array): Promise<string> {
  const salUsada = sal ?? crypto.getRandomValues(new Uint8Array(16));
  const clave = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pin),
    "PBKDF2",
    false,
    ["deriveBits"]
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: salUsada as BufferSource, iterations: ITERACIONES },
    clave,
    256
  );
  return `pbkdf2$${ITERACIONES}$${aBase64(salUsada.buffer as ArrayBuffer)}$${hex(new Uint8Array(bits))}`;
}

export async function verificarPin(pin: string, guardado: string): Promise<boolean> {
  const [esquema, iteraciones, sal, esperado] = guardado.split("$");
  if (esquema !== "pbkdf2" || !sal || !esperado) return false;
  const clave = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pin),
    "PBKDF2",
    false,
    ["deriveBits"]
  );
  const bits = await crypto.subtle.deriveBits(
    {
      name: "PBKDF2",
      hash: "SHA-256",
      salt: deBase64(sal) as BufferSource,
      iterations: Number(iteraciones),
    },
    clave,
    256
  );
  const calculado = hex(new Uint8Array(bits));
  // Comparación en tiempo constante: no filtrar por longitud del prefijo.
  if (calculado.length !== esperado.length) return false;
  let diferencia = 0;
  for (let i = 0; i < calculado.length; i += 1) {
    diferencia |= calculado.charCodeAt(i) ^ esperado.charCodeAt(i);
  }
  return diferencia === 0;
}
