-- BLINK · Limpieza de datos placeholder y de demostración
-- Fecha: 2026-10-31
-- Base: PostgreSQL 17.11 · Supabase gakkfzqcrapxeierfdhk · esquema public
--
-- Objetivo: retirar únicamente registros de demostración o caducados que no
-- participan del ciclo de recarga real. El script es idempotente, se ejecuta
-- en una sola transacción y archiva cada fila borrada en respaldo.purga_20261031.
--
-- NO hace lo siguiente, a propósito:
--   * No reinicia secuencias (los huecos son normales y reiniciar el
--     contador de card_events podría chocar con IDs ya emitidos).
--   * No toca cuentas, tarjetas, recargas, movimientos ni telemetría reales.
--   * No modifica settings: el Pago Móvil público sigue con datos de ejemplo
--     (RIF J-00000000-0, teléfono 0414-0000000) y debe corregirlo el dueño.
--
-- Uso:
--   psql "$DATABASE_URL" -f 2026-10-31_auditoria_y_purga.sql
--
-- Para revisar sin borrar, sustituir el COMMIT final por ROLLBACK.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1. Archivo de seguridad -------------------------------------------------
create table if not exists respaldo.purga_20261031 (
  id          uuid primary key,
  tabla       text not null,
  fila        jsonb not null,
  purgado_en  timestamptz not null default now()
);

-- 2. Vehículo de demostración A99XY7Z ------------------------------------
-- Semilla de 0002_demo.sql: placa A99XY7Z, MAC 001122334455 (la MAC de
-- ejemplo del manual) y sin token de sincronización. Solo se borra si no
-- tiene viajes ni liquidaciones asociadas.
do $$
declare
  v_demo uuid;
begin
  select id into v_demo
    from public.vehicles
   where plate_number = 'A99XY7Z'
     and validator_mac = '001122334455';

  if v_demo is null then
    raise notice 'Vehículo demo A99XY7Z: ya no existe, nada que borrar.';
  elsif exists (select 1 from public.trips_telemetry where vehicle_id = v_demo)
     or exists (select 1 from public.settlements where vehicle_id = v_demo) then
    raise exception
      'ABORTADO: el vehículo demo A99XY7Z tiene viajes o liquidaciones; revisar a mano antes de borrar.';
  end if;
end $$;

insert into respaldo.purga_20261031 (id, tabla, fila)
select v.id, 'vehicles', to_jsonb(v)
  from public.vehicles v
 where v.plate_number = 'A99XY7Z'
   and v.validator_mac = '001122334455'
on conflict (id) do nothing;

delete from public.vehicles v
 where v.plate_number = 'A99XY7Z'
   and v.validator_mac = '001122334455'
   and not exists (select 1 from public.trips_telemetry t where t.vehicle_id = v.id)
   and not exists (select 1 from public.settlements s where s.vehicle_id = v.id);

-- 3. Sesiones caducadas --------------------------------------------------
-- Son efímeras: no se archivan. Si expira >= now() no se toca ninguna.
delete from public.account_sessions where expira < now();
delete from public.card_sessions    where expira < now();

-- 4. Comprobaciones de cierre --------------------------------------------
do $$
declare
  v_demo int;
  v_huerfanos int;
begin
  select count(*) into v_demo
    from public.vehicles
   where plate_number = 'A99XY7Z' or validator_mac = '001122334455';
  if v_demo <> 0 then
    raise exception 'Quedó el vehículo demo tras la limpieza.';
  end if;

  select count(*) into v_huerfanos
    from public.recharges r
    left join public.cards c on c.id = r.card_id
   where c.id is null;
  if v_huerfanos <> 0 then
    raise exception 'Hay % recargas huérfanas; no se cierra la limpieza.', v_huerfanos;
  end if;

  raise notice 'Limpieza verificada: sin vehículo demo ni recargas huérfanas.';
end $$;

commit;
