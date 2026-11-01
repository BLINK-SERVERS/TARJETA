-- ============================================================
-- BLINK · contador de transacciones del chip (Tx_Counter)
-- Ejecutar después de 0016_corrige_alfabeto_verificador.sql.
--
-- Cierra la brecha de auditoría de la especificación offline: cada
-- cobro lleva el contador del bloque de valor del chip para poder
-- detectar saltos o retrocesos (clonación, replay o escritura
-- interrumpida). El validador ya lo transmite dentro de offline_id
-- con la forma UID-epoch-contador-aleatorio; el trigger lo copia a
-- una columna consultable sin tocar la función de sincronización.
--
-- Cambio aditivo: no altera permisos, políticas RLS ni funciones
-- públicas existentes.
-- ============================================================

alter table public.trips_telemetry
  add column if not exists chip_counter integer;

comment on column public.trips_telemetry.chip_counter is
  'Contador de transacciones grabado en el bloque de valor del chip (Tx_Counter).';

create or replace function public.bt_trip_contador_chip()
returns trigger language plpgsql as $$
declare
  v_texto text;
begin
  if new.chip_counter is null then
    v_texto := substring(new.offline_id from '^[^-]+-[^-]+-([0-9]+)-');
    if v_texto is not null then
      begin
        new.chip_counter := v_texto::integer;
      exception when others then
        new.chip_counter := null;
      end;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.bt_trip_contador_chip()
  from public, anon, authenticated;

-- Relleno de las filas anteriores al cambio.
update public.trips_telemetry
   set chip_counter = substring(offline_id from '^[^-]+-[^-]+-([0-9]+)-')::integer
 where chip_counter is null
   and offline_id ~ '^[^-]+-[^-]+-[0-9]+-';

drop trigger if exists trips_telemetry_contador_chip on public.trips_telemetry;
create trigger trips_telemetry_contador_chip
  before insert on public.trips_telemetry
  for each row execute function public.bt_trip_contador_chip();
