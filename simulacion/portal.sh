#!/usr/bin/env bash
# Abre el portal del pasajero contra la base local.
set -euo pipefail
BASE="$(dirname "$(readlink -f "$0")")"
cd "$BASE"
RAIZ="$(dirname "$BASE")"

if [ ! -f .entorno ]; then
  echo "Falta .entorno. Ejecuta primero ./arrancar.sh"
  exit 1
fi

BLINK_DESTINO="$RAIZ/.env.simulacion.local" node -e '
  const fs = require("node:fs");
  const e = JSON.parse(fs.readFileSync(".entorno", "utf8"));
  fs.writeFileSync(
    process.env.BLINK_DESTINO,
    `VITE_SUPABASE_URL=${e.url}\nVITE_SUPABASE_ANON_KEY=${e.anonKey}\n`,
  );
'

cd "$RAIZ"
npm run dev -- --mode simulacion --port 5175
