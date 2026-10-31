#!/usr/bin/env bash
# Apaga y borra la base local de simulación.
set -euo pipefail
cd "$(dirname "$0")"
docker-compose -p blink-simulacion down -v --remove-orphans
rm -f .entorno
