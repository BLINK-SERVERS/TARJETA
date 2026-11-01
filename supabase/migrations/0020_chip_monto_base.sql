-- ============================================================
-- BLINK · el chip recibe el monto base, no el bruto
-- Ejecutar después de 0019_motor_tarifario.sql.
--
-- Desde 0019 la recarga tiene dos importes: `amount` (lo que el
-- pasajero transfirió y se concilia con el banco) y `monto_base`
-- (lo que se acredita a la tarjeta). `bt_validador_sincronizar`
-- seguía enviando `amount` al validador, así que el chip recibía
-- de más (por ejemplo 1.060 en una recarga de 2 pasajes que solo
-- acredita 1.000). Esta migración reescribe la función con el
-- crédito correcto; las recargas anteriores a 0019 no tienen
-- `monto_base` y conservan su importe.
-- ============================================================

create or replace function public.bt_validador_sincronizar(
  p_validator_mac text,
  p_taps jsonb default '[]'::jsonb,
  p_recargas jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_mac       text := public.bt_normalizar_mac(p_validator_mac);
  v_vehiculo  public.vehicles;
  v_tap       jsonb;
  v_recarga   jsonb;
  v_tarjeta   public.cards;
  v_offline   text;
  v_fare      numeric;
  v_saldo     numeric;
  v_tap_id    uuid;
  v_rech_id   uuid;
  v_rechazadas jsonb := '[]'::jsonb;
  v_procesadas int := 0;
begin
  select * into v_vehiculo from public.vehicles where validator_mac = v_mac;

  if not found then
    raise exception 'Validador no registrado: %.', v_mac;
  end if;

  for v_tap in select * from jsonb_array_elements(coalesce(p_taps, '[]'::jsonb)) loop
    v_offline := nullif(trim(coalesce(v_tap ->> 'offline_id', '')), '');

    if v_offline is null then
      v_rechazadas := v_rechazadas || jsonb_build_object(
        'serial', v_tap ->> 'visible_id', 'motivo', 'Falta offline_id'
      );
      continue;
    end if;

    if exists (select 1 from public.trips_telemetry where offline_id = v_offline) then
      continue;
    end if;

    select * into v_tarjeta
      from public.cards
     where visible_id = trim(coalesce(v_tap ->> 'visible_id', ''));

    if not found then
      v_rechazadas := v_rechazadas || jsonb_build_object(
        'serial', v_tap ->> 'visible_id', 'motivo', 'Tarjeta desconocida'
      );
      continue;
    end if;

    select case when v_tarjeta.fare_type = 2 then r.student_fare else r.general_fare end
      into v_fare
      from public.transit_routes r
     where r.id = v_vehiculo.route_id;

    v_fare := coalesce(nullif(v_tap ->> 'fare_charged', '')::numeric, v_fare, v_tarjeta.tarifa);

    v_saldo := coalesce(
      nullif(v_tap ->> 'chip_balance_after', '')::numeric,
      greatest(v_tarjeta.last_chip_balance - v_fare, 0)
    );

    insert into public.trips_telemetry
      (card_id, vehicle_id, route_id, fare_charged, fare_type, latitude, longitude,
       validator_mac, offline_id, chip_balance_after, tapped_at)
    values
      (v_tarjeta.id, v_vehiculo.id, v_vehiculo.route_id, v_fare,
       coalesce((v_tap ->> 'fare_type')::smallint, v_tarjeta.fare_type),
       nullif(v_tap ->> 'latitude', '')::double precision,
       nullif(v_tap ->> 'longitude', '')::double precision,
       v_mac, v_offline, v_saldo,
       coalesce(nullif(v_tap ->> 'tapped_at', '')::timestamptz, now()))
    returning id into v_tap_id;

    insert into public.card_movements
      (card_id, tipo, monto, saldo_despues, detalle, estado, unidad, at)
    values
      (v_tarjeta.id, 'viaje', -v_fare, v_saldo,
       'Pasaje en ' || v_vehiculo.plate_number, 'aprobado', v_vehiculo.plate_number,
       coalesce(nullif(v_tap ->> 'tapped_at', '')::timestamptz, now()));

    update public.cards
       set virtual_balance = v_saldo,
           last_chip_balance = v_saldo
     where id = v_tarjeta.id;

    v_procesadas := v_procesadas + 1;
  end loop;

  for v_recarga in select * from jsonb_array_elements(coalesce(p_recargas, '[]'::jsonb)) loop
    v_rech_id := null;
    begin
      v_rech_id := coalesce(
        nullif(v_recarga ->> 'id', ''),
        v_recarga #>> '{}'
      )::uuid;
    exception when others then
      v_rech_id := null;
    end;

    if v_rech_id is not null then
      update public.recharges
         set synced_to_chip = true, synced_at = now()
       where id = v_rech_id
         and status = 'aprobado'
         and not synced_to_chip;
    end if;
  end loop;

  return jsonb_build_object(
    'validador', jsonb_build_object(
      'mac', v_mac,
      'placa', v_vehiculo.plate_number,
      'ruta', v_vehiculo.route_id
    ),
    'procesadas', v_procesadas,
    'rechazadas', v_rechazadas,
    'pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id,
               'serial', c.visible_id,
               'uid', c.chip_uid,
               'monto', coalesce(r.monto_base, r.amount),
               'acreditada', r.created_at
             ) order by r.created_at)
        from public.recharges r
        join public.cards c on c.id = r.card_id
       where r.status = 'aprobado'
         and not r.synced_to_chip
         and c.chip_uid is not null
         and c.status = 'ACTIVE'
    ), '[]'::jsonb),
    'bloqueadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'serial', c.visible_id,
               'uid', c.chip_uid,
               'estado', c.status
             ))
        from public.cards c
       where c.status <> 'ACTIVE'
    ), '[]'::jsonb)
  );
end;
$$;
