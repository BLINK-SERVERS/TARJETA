import crypto from "node:crypto";

const SECRETO =
  process.env.PGRST_JWT_SECRET ?? "blink-simulacion-local-no-usar-en-produccion";

function firmar(rol) {
  const ahora = Math.floor(Date.now() / 1000);
  const cabecera = { alg: "HS256", typ: "JWT" };
  const cuerpo = {
    role: rol,
    iss: "blink-simulacion",
    iat: ahora,
    exp: ahora + 60 * 60 * 24 * 365,
  };
  const base = (valor) =>
    Buffer.from(JSON.stringify(valor)).toString("base64url");
  const sinFirma = `${base(cabecera)}.${base(cuerpo)}`;
  const firma = crypto
    .createHmac("sha256", SECRETO)
    .update(sinFirma)
    .digest("base64url");
  return `${sinFirma}.${firma}`;
}

process.stdout.write(
  JSON.stringify(
    {
      url: "http://127.0.0.1:54321",
      baseDatos: "postgres://postgres:blink@127.0.0.1:54329/blink",
      anonKey: firmar("anon"),
      serviceKey: firmar("service_role"),
    },
    null,
    2,
  ) + "\n",
);
