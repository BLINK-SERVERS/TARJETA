#!/usr/bin/env bash
# Abre el back-office contra la base local.
set -euo pipefail
BASE="$(dirname "$(readlink -f "$0")")"
cd "$BASE"
PROYECTO="$(dirname "$(dirname "$BASE")")/backoffice"

if [ ! -f .entorno ]; then
  echo "Falta .entorno. Ejecuta primero ./arrancar.sh"
  exit 1
fi

BLINK_DESTINO="$PROYECTO/.env.simulacion.local" node -e '
  const fs = require("node:fs");
  const e = JSON.parse(fs.readFileSync(".entorno", "utf8"));
  fs.writeFileSync(
    process.env.BLINK_DESTINO,
    `VITE_SUPABASE_URL=${e.url}\nVITE_SUPABASE_ANON_KEY=${e.anonKey}\n`,
  );
'

cd "$PROYECTO"
npm run dev -- --mode simulacion --port 5173
