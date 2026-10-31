#!/usr/bin/env bash
# Simulación completa desde cero. Uso:
#   ./flujo.sh               reinicia la base, migra y recorre el flujo
#   ./flujo.sh --continuar   recorre el flujo sobre la base ya preparada
set -euo pipefail
cd "$(dirname "$0")"

[ -d node_modules ] || npm install --silent

if [ "${1:-}" != "--continuar" ]; then
  ./arrancar.sh
fi

node flujo.mjs
