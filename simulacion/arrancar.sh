#!/usr/bin/env bash
# Deja una base PostgreSQL limpia con todas las migraciones y la API PostgREST.
# No toca el proyecto de Supabase de producción.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE=(docker-compose -p blink-simulacion)

echo "· Reiniciando la base local…"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d db

for _ in $(seq 1 60); do
  "${COMPOSE[@]}" exec -T db pg_isready -U postgres -d blink >/dev/null 2>&1 && break
  sleep 1
done

echo "· Creando roles de Supabase…"
"${COMPOSE[@]}" exec -T db psql -U postgres -d blink -v ON_ERROR_STOP=1 -q <<'SQL'
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
SQL

echo "· Aplicando todas las migraciones…"
for archivo in ../supabase/migrations/*.sql; do
  nombre="$(basename "$archivo")"
  case "$nombre" in
    0002_demo.sql) continue ;;
  esac
  printf '  %s\n' "$nombre"
  if [ "$nombre" = "0014_serie_cinco_mas_tres.sql" ]; then
    # Producción llegó a 0014 sin las tarjetas de arranque de 0006; la
    # simulación hace la misma limpieza antes de cambiar la serie.
    "${COMPOSE[@]}" exec -T db psql -U postgres -d blink -v ON_ERROR_STOP=1 -q <<'SQL'
truncate public.card_events, public.card_movements, public.recharges,
         public.card_sessions, public.cards, public.card_batches,
         public.trips_telemetry cascade;
SQL
  fi
  "${COMPOSE[@]}" exec -T db psql -U postgres -d blink -v ON_ERROR_STOP=1 -q -f - < "$archivo"
done

echo "· Sembrando ruta, validador y operador…"
"${COMPOSE[@]}" exec -T db psql -U postgres -d blink -v ON_ERROR_STOP=1 -q -f - < seed.sql

echo "· Levantando la API PostgREST…"
"${COMPOSE[@]}" up -d rest api
for _ in $(seq 1 30); do
  curl -sf http://127.0.0.1:54321/ >/dev/null 2>&1 && break
  sleep 1
done

node generar-claves.mjs > .entorno

echo "Listo: base en 127.0.0.1:54329 y API en 127.0.0.1:54321"
