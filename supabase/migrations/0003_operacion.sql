-- ============================================================
-- BLINK · operación del ecosistema
-- Ejecutar después de 0001_tarjeta.sql (y de 0002_demo.sql si
-- se quieren datos de demostración).
--
-- Aquí viven las funciones que usan el validador IoT, la taquilla
-- y el cierre de lote: enrolado de chips, generación de lotes,
-- acreditación de recargas, sincronización offline y liquidación.
-- Todas son solo para service_role.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Utilidades
-- ------------------------------------------------------------

-- Dígito verificador de Luhn para una base de 9 dígitos.
create or replace function public.bt_luhn_digito(p_base text)
returns text language plpgsql immutable as $$
declare
  v_digitos text := regexp_replace(coalesce(p_base, ''), '\D', '', 'g');
  v_suma int := 0;
  v_n int;
  i int;
begin
  if length(v_digitos) <> 9 then
    raise exception 'La base del ID BLINK debe tener 9 dígitos.';
  end if;

  for i in 1..9 loop
    v_n := substr(v_digitos, i, 1)::int;
    if i % 2 = 1 then
      v_n := v_n * 2;
      if v_n > 9 then
        v_n := v_n - 9;
      end if;
    end if;
    v_suma := v_suma + v_n;
  end loop;

  return ((10 - (v_suma % 10)) % 10)::text;
end;
$$;

create or replace function public.bt_normalizar_mac(p_mac text)
returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(p_mac, ''), '[^0-9A-Fa-f]', '', 'g'));
$$;

-- ------------------------------------------------------------
-- 2. Enrolado: vincula el CSN de fábrica con el ID visible
-- ------------------------------------------------------------
create or replace function public.bt_enrolar_tarjeta(p_visible_id text, p_chip_uid text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_serial text := trim(coalesce(p_visible_id, ''));
  v_uid    text := public.bt_normalizar_mac(p_chip_uid);
  v_tarjeta public.cards;
begin
  if v_uid !~ '^[0-9A-F]{8,20}$' then
    raise exception 'El UID del chip debe ser hexadecimal de 4 a 10 bytes (ej. 0484CC62).';
  end if;

  select * into v_tarjeta from public.cards where visible_id = v_serial for update;

  if not found then
    raise exception 'No existe la tarjeta %.', v_serial;
  end if;

  if v_tarjeta.chip_uid is not null and v_tarjeta.chip_uid <> v_uid then
    raise exception 'La tarjeta % ya está enrolada con el chip %.', v_serial, v_tarjeta.chip_uid;
  end if;

  if exists (
    select 1 from public.cards
     where chip_uid = v_uid and id <> v_tarjeta.id
  ) then
    raise exception 'El chip % ya está vinculado a otra tarjeta.', v_uid;
  end if;

  update public.cards set chip_uid = v_uid where id = v_tarjeta.id;

  return jsonb_build_object('ok', true, 'serial', v_serial, 'uid', v_uid);
end;
$$;

-- ------------------------------------------------------------
-- 3. Producción: lotes con ID BLINK secuencial y Luhn
-- ------------------------------------------------------------
create or replace function public.bt_generar_lote(
  p_cantidad int,
  p_patrocinante text default null,
  p_estado int default 23,
  p_tarifa int default 1
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cantidad int := coalesce(p_cantidad, 0);
  v_estado   int := coalesce(p_estado, 23);
  v_tarifa   int := coalesce(p_tarifa, 1);
  v_lote     uuid;
  v_numero   int;
  v_desde    int;
  v_base     text;
  v_serial   text;
  v_tarjetas jsonb := '[]'::jsonb;
  i int;
begin
  if v_cantidad < 1 or v_cantidad > 20000 then
    raise exception 'La cantidad del lote debe estar entre 1 y 20.000 tarjetas.';
  end if;

  if v_estado < 1 or v_estado > 99 then
    raise exception 'El código de entidad federal debe tener 2 dígitos (23 = Zulia).';
  end if;

  if v_tarifa not in (1, 2) then
    raise exception 'El tipo de tarifa debe ser 1 (general) o 2 (estudiante / tercera edad).';
  end if;

  select coalesce(max(batch_number), 0) + 1 into v_numero from public.card_batches;

  select coalesce(max(substring(visible_id from 6 for 6)::int), 0) + 1
    into v_desde
    from public.cards
   where state_code = v_estado
     and fare_type = v_tarifa;

  if v_desde + v_cantidad - 1 > 999999 then
    raise exception 'El secuencial del estado % y tarifa % se agotó.', v_estado, v_tarifa;
  end if;

  insert into public.card_batches
    (batch_number, sponsor_name, cards_quantity, state_code, fare_type)
  values
    (v_numero, nullif(trim(coalesce(p_patrocinante, '')), ''), v_cantidad, v_estado, v_tarifa)
  returning id into v_lote;

  for i in 0..(v_cantidad - 1) loop
    v_base := lpad(v_estado::text, 2, '0') || v_tarifa::text
              || lpad((v_desde + i)::text, 6, '0');
    v_serial := substr(v_base, 1, 2) || '-' || substr(v_base, 3, 1) || '-'
                || substr(v_base, 4, 6) || '-' || public.bt_luhn_digito(v_base);

    insert into public.cards (visible_id, state_code, fare_type, batch_id)
    values (v_serial, v_estado, v_tarifa, v_lote);

    v_tarjetas := v_tarjetas || jsonb_build_object(
      'serial', v_serial,
      'barcode', regexp_replace(v_serial, '\D', '', 'g')
    );
  end loop;

  return jsonb_build_object(
    'lote', jsonb_build_object(
      'id', v_lote,
      'numero', v_numero,
      'patrocinante', nullif(trim(coalesce(p_patrocinante, '')), ''),
      'cantidad', v_cantidad,
      'desde', (v_tarjetas -> 0 ->> 'serial'),
      'hasta', (v_tarjetas -> (v_cantidad - 1) ->> 'serial')
    ),
    'tarjetas', v_tarjetas
  );
end;
$$;

-- Reporte de extravío o robo: LOST es irreversible desde el portal.
create or replace function public.bt_reportar_perdida(p_visible_id text, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  update public.cards
     set status = 'LOST'
   where visible_id = trim(coalesce(p_visible_id, ''))
  returning id into v_id;

  if v_id is null then
    raise exception 'No existe la tarjeta %.', trim(coalesce(p_visible_id, ''));
  end if;

  delete from public.card_sessions where card_id = v_id;

  return jsonb_build_object('ok', true, 'estado', 'LOST', 'motivo', p_motivo);
end;
$$;

-- ------------------------------------------------------------
-- 4. Acreditación automática de Pago Móvil (webhook bancario)
-- ------------------------------------------------------------
create or replace function public.bt_acreditar_recarga(
  p_visible_id text,
  p_monto numeric,
  p_referencia text,
  p_banco text default 'Pago Móvil',
  p_telefono text default ''
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.cards;
  v_monto   numeric := round(coalesce(p_monto, 0), 2);
  v_ref     text := trim(coalesce(p_referencia, ''));
  v_banco   text := trim(coalesce(p_banco, ''));
  v_saldo   numeric;
  v_mov     uuid;
  v_recarga uuid;
begin
  if v_monto <= 0 then
    raise exception 'El monto de la recarga debe ser mayor que 0.';
  end if;

  if v_monto <> coalesce(p_monto, 0) then
    raise exception 'Usa como máximo dos decimales.';
  end if;

  if v_ref = '' then
    raise exception 'Falta la referencia bancaria.';
  end if;

  select * into v_tarjeta from public.cards where visible_id = trim(p_visible_id) for update;

  if not found then
    raise exception 'No existe la tarjeta %.', trim(p_visible_id);
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'La tarjeta % está vencida.', v_tarjeta.visible_id;
  end if;

  if exists (
    select 1 from public.recharges
     where card_id = v_tarjeta.id
       and bank = v_banco
       and bank_reference = v_ref
       and status <> 'rechazado'
  ) then
    raise exception 'La referencia % ya fue acreditada en esta tarjeta.', v_ref;
  end if;

  v_saldo := v_tarjeta.virtual_balance + v_monto;

  update public.cards set virtual_balance = v_saldo where id = v_tarjeta.id;

  insert into public.card_movements
    (card_id, tipo, monto, saldo_despues, detalle, estado, banco, referencia)
  values
    (v_tarjeta.id, 'recarga', v_monto, v_saldo, 'Pago Móvil acreditado', 'aprobado', v_banco, v_ref)
  returning id into v_mov;

  insert into public.recharges
    (card_id, movement_id, amount, sender_phone, bank, bank_reference,
     status, resolved_at, resolved_by)
  values
    (v_tarjeta.id, v_mov, v_monto, public.bt_solo_digitos(p_telefono), v_banco, v_ref,
     'aprobado', now(), 'conciliacion')
  returning id into v_recarga;

  return jsonb_build_object(
    'recarga', v_recarga,
    'serial', v_tarjeta.visible_id,
    'saldo', v_saldo
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Sincronización del validador (offline-first)
-- ------------------------------------------------------------
-- El validador cobra sin red y luego envía sus taps. Cada tap trae un
-- offline_id propio para poder reenviarlo sin duplicar el cobro.
-- p_taps:    [{offline_id, visible_id, fare_charged, chip_balance_after,
--              tapped_at, latitude, longitude, fare_type}]
-- p_recargas:[uuid, ...] recargas que el validador ya escribió en el chip.
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
               'monto', r.amount,
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

-- ------------------------------------------------------------
-- 6. Liquidación a choferes y propietarios
-- ------------------------------------------------------------
create or replace function public.bt_liquidar(
  p_vehicle uuid default null,
  p_desde timestamptz default null,
  p_hasta timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_desde  timestamptz := coalesce(p_desde, date_trunc('day', now()));
  v_hasta  timestamptz := coalesce(p_hasta, now());
  v_veh    public.vehicles;
  v_bruto  numeric;
  v_cant   int;
  v_comis  numeric;
  v_neto   numeric;
  v_lote   uuid;
  v_lista  jsonb := '[]'::jsonb;
begin
  if v_hasta <= v_desde then
    raise exception 'El cierre debe terminar después de empezar.';
  end if;

  for v_veh in
    select * from public.vehicles
     where active
       and (p_vehicle is null or id = p_vehicle)
     order by plate_number
  loop
    select coalesce(sum(fare_charged), 0), count(*)
      into v_bruto, v_cant
      from public.trips_telemetry
     where vehicle_id = v_veh.id
       and not settled
       and tapped_at >= v_desde
       and tapped_at <= v_hasta;

    if v_cant = 0 then
      continue;
    end if;

    v_comis := round(v_bruto * v_veh.commission_pct / 100, 2);
    v_neto  := v_bruto - v_comis - v_veh.line_fee;

    insert into public.settlements
      (vehicle_id, period_start, period_end, trips_count, gross,
       commission_pct, commission, line_fee, net)
    values
      (v_veh.id, v_desde, v_hasta, v_cant, v_bruto,
       v_veh.commission_pct, v_comis, v_veh.line_fee, v_neto)
    returning id into v_lote;

    update public.trips_telemetry
       set settled = true, settlement_id = v_lote
     where vehicle_id = v_veh.id
       and not settled
       and tapped_at >= v_desde
       and tapped_at <= v_hasta;

    v_lista := v_lista || jsonb_build_object(
      'liquidacion', v_lote,
      'unidad', v_veh.plate_number,
      'chofer', v_veh.driver_name,
      'pasajes', v_cant,
      'bruto', v_bruto,
      'comision', v_comis,
      'aporteLinea', v_veh.line_fee,
      'neto', v_neto,
      'banco', v_veh.bank_code,
      'cuenta', v_veh.bank_account_or_phone
    );
  end loop;

  return jsonb_build_object(
    'desde', v_desde,
    'hasta', v_hasta,
    'liquidaciones', v_lista
  );
end;
$$;

-- ------------------------------------------------------------
-- 7. Resumen operativo (tablero de Admin / fiscal)
-- ------------------------------------------------------------
create or replace function public.bt_resumen_operativo()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_hoy timestamptz := date_trunc('day', now());
begin
  return jsonb_build_object(
    'tarjetas', jsonb_build_object(
      'total', (select count(*) from public.cards),
      'activas', (select count(*) from public.cards where status = 'ACTIVE'),
      'bloqueadas', (select count(*) from public.cards where status = 'BLOCKED'),
      'perdidas', (select count(*) from public.cards where status = 'LOST'),
      'sinEnrolar', (select count(*) from public.cards where chip_uid is null),
      'saldoTotal', (select coalesce(sum(virtual_balance), 0) from public.cards)
    ),
    'recargas', jsonb_build_object(
      'pendientes', (select count(*) from public.recharges where status = 'pendiente'),
      'montoPendiente', (select coalesce(sum(amount), 0) from public.recharges where status = 'pendiente'),
      'porSincronizar', (select count(*) from public.recharges where status = 'aprobado' and not synced_to_chip)
    ),
    'hoy', jsonb_build_object(
      'pasajes', (select count(*) from public.trips_telemetry where tapped_at >= v_hoy),
      'recaudado', (select coalesce(sum(fare_charged), 0) from public.trips_telemetry where tapped_at >= v_hoy),
      'porLiquidar', (select coalesce(sum(fare_charged), 0) from public.trips_telemetry where not settled)
    ),
    'flota', jsonb_build_object(
      'unidades', (select count(*) from public.vehicles where active),
      'rutas', (select count(*) from public.transit_routes where active)
    )
  );
end;
$$;

-- ------------------------------------------------------------
-- 8. Permisos: solo service_role
-- ------------------------------------------------------------
revoke all on function public.bt_luhn_digito(text)                      from public;
revoke all on function public.bt_normalizar_mac(text)                   from public;
revoke all on function public.bt_enrolar_tarjeta(text, text)            from public;
revoke all on function public.bt_generar_lote(int, text, int, int)      from public;
revoke all on function public.bt_reportar_perdida(text, text)           from public;
revoke all on function public.bt_acreditar_recarga(text, numeric, text, text, text) from public;
revoke all on function public.bt_validador_sincronizar(text, jsonb, jsonb) from public;
revoke all on function public.bt_liquidar(uuid, timestamptz, timestamptz) from public;
revoke all on function public.bt_resumen_operativo()                    from public;

grant execute on function public.bt_enrolar_tarjeta(text, text)            to service_role;
grant execute on function public.bt_generar_lote(int, text, int, int)      to service_role;
grant execute on function public.bt_reportar_perdida(text, text)           to service_role;
grant execute on function public.bt_acreditar_recarga(text, numeric, text, text, text) to service_role;
grant execute on function public.bt_validador_sincronizar(text, jsonb, jsonb) to service_role;
grant execute on function public.bt_liquidar(uuid, timestamptz, timestamptz) to service_role;
grant execute on function public.bt_resumen_operativo()                    to service_role;
