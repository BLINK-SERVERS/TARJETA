#!/usr/bin/env bash
# Abre el back-office contra la base local.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .entorno ]; then
  echo "Falta .entorno. Ejecuta primero ./arrancar.sh"
  exit 1
fi

node -e '
  const fs = require("node:fs");
  const e = JSON.parse(fs.readFileSync(".entorno", "utf8"));
  fs.writeFileSync(
    "../../backoffice/.env.simulacion.local",
    `VITE_SUPABASE_URL=${e.url}\nVITE_SUPABASE_ANON_KEY=${e.anonKey}\n`,
  );
'

cd ../../backoffice
npm run dev -- --mode simulacion --port 5173
