-- ============================================================
-- BLINK · aprovisionamiento en lote y activación (claiming)
-- Ejecutar después de 0005_cuentas.sql.
--
-- Implementa el modelo corporativo del documento «Arquitectura
-- Global de Seguridad y Enrolamiento»:
--
--   Fase 1 · Pre-generación (Batch Provisioning)
--     Las tarjetas nacen con estado FABRICADA: existen en el
--     inventario con su serial y su lote, sin dueño ni saldo.
--
--   Fase 2 · Activación (Claiming)
--     El pasajero reclama el serial desde el portal (bt_vincular)
--     o la taquilla lo asigna a una cuenta (bt_estacion_asignar).
--     Solo entonces el plástico pasa a ACTIVE y queda ligado a la
--     cuenta matriz.
--
--   Estación de asignación
--     Para lotes sin archivo de fábrica, bt_estacion_enrolar carga
--     los pares UID ↔ serial capturados con el lector USB/ESP32.
--
-- La migración también deja la base en el estado de arranque
-- corporativo: archiva y purga los datos de demostración y crea la
-- cuenta administradora única. El PIN de esa cuenta no se versiona:
-- se pasa en la sesión con set_config('blink.admin_pin', …, false).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Estado FABRICADA y trazabilidad de la asignación
-- ------------------------------------------------------------
alter table public.cards drop constraint if exists cards_status_check;

alter table public.cards
  add constraint cards_status_check
  check (status in ('FABRICADA', 'ACTIVE', 'BLOCKED', 'LOST'));

alter table public.cards
  add column if not exists asignada_at  timestamptz,
  add column if not exists asignada_por text,
  add column if not exists enrolada_at  timestamptz,
  add column if not exists enrolada_por text;

create index if not exists cards_estado_idx on public.cards (status);

-- Bitácora de ciclo de vida del plástico (ISO/IEC 27001 · trazabilidad).
create table if not exists public.card_events (
  id       bigserial primary key,
  card_id  uuid not null references public.cards(id) on delete cascade,
  evento   text not null check (evento in ('ENROLADA', 'ASIGNADA', 'PERDIDA')),
  canal    text not null default 'sistema' check (canal in ('portal', 'taquilla', 'estacion', 'sistema')),
  operador text,
  detalle  jsonb not null default '{}'::jsonb,
  at       timestamptz not null default now()
);

create index if not exists card_events_card_idx on public.card_events (card_id, at desc);

alter table public.card_events enable row level security;

-- ------------------------------------------------------------
-- 2. Lotes: origen del aprovisionamiento
-- ------------------------------------------------------------
alter table public.card_batches
  add column if not exists origen text not null default 'FABRICANTE'
    check (origen in ('FABRICANTE', 'ESTACION')),
  add column if not exists creado_por text not null default '',
  add column if not exists cerrado_at timestamptz;

-- ------------------------------------------------------------
-- 3. Cuentas: rol para el control de acceso del back-office
-- ------------------------------------------------------------
alter table public.accounts
  add column if not exists rol text not null default 'PASAJERO'
    check (rol in ('PASAJERO', 'TAQUILLA', 'ADMIN'));

-- ------------------------------------------------------------
-- 4. Respaldo y purga de los datos de demostración
-- ------------------------------------------------------------
create schema if not exists respaldo;
revoke all on schema respaldo from public, anon, authenticated;

create table if not exists respaldo.bitacora (
  clave      text primary key,
  ejecutado  timestamptz not null default now(),
  detalle    jsonb not null default '{}'::jsonb
);

do $$
declare
  v_tarjetas  bigint;
  v_cuentas   bigint;
  v_recargas  bigint;
begin
  if to_regclass('respaldo.cards_0006') is null then
    execute 'create table respaldo.cards_0006 as select * from public.cards';
    execute 'create table respaldo.card_movements_0006 as select * from public.card_movements';
    execute 'create table respaldo.recharges_0006 as select * from public.recharges';
    execute 'create table respaldo.trips_telemetry_0006 as select * from public.trips_telemetry';
    execute 'create table respaldo.settlements_0006 as select * from public.settlements';
    execute 'create table respaldo.card_sessions_0006 as select * from public.card_sessions';
    execute 'create table respaldo.account_sessions_0006 as select * from public.account_sessions';
    execute 'create table respaldo.accounts_0006 as select * from public.accounts';
    execute 'create table respaldo.card_batches_0006 as select * from public.card_batches';
  end if;

  if exists (select 1 from respaldo.bitacora where clave = '0006_purga') then
    raise notice 'La purga corporativa ya se aplicó; no se repite.';
    return;
  end if;

  select count(*) into v_tarjetas from public.cards;
  select count(*) into v_cuentas  from public.accounts;
  select count(*) into v_recargas from public.recharges;

  delete from public.trips_telemetry;
  delete from public.recharges;
  delete from public.card_movements;
  delete from public.card_sessions;
  delete from public.settlements;
  delete from public.card_events;
  delete from public.cards;
  delete from public.card_batches;
  delete from public.account_sessions;
  delete from public.accounts;

  insert into respaldo.bitacora (clave, detalle)
  values ('0006_purga', jsonb_build_object(
    'tarjetas',  v_tarjetas,
    'cuentas',   v_cuentas,
    'recargas',  v_recargas,
    'nota',      'Filas archivadas en el esquema respaldo (sufijo _0006).'
  ));

  raise notice 'Purga corporativa: % tarjetas, % cuentas, % recargas archivadas.',
    v_tarjetas, v_cuentas, v_recargas;
end;
$$;

-- ------------------------------------------------------------
-- 5. Cuenta administradora única
-- ------------------------------------------------------------
-- El PIN viaja por la sesión, nunca por el repositorio:
--   select set_config('blink.admin_pin', '<PIN de 6 dígitos>', false);
do $$
declare
  v_pin    text := nullif(current_setting('blink.admin_pin', true), '');
  v_cuenta public.accounts;
begin
  if exists (
    select 1 from public.accounts where cedula_digitos = '34201580'
  ) then
    raise notice 'La cuenta administradora ya existe.';
    return;
  end if;

  if v_pin is null then
    raise notice 'Sin blink.admin_pin: la cuenta administradora no se creó.';
    return;
  end if;

  if not public.bt_pin6_valido(v_pin) then
    raise exception 'El PIN administrador no cumple la regla de 6 dígitos.';
  end if;

  insert into public.accounts
    (nombres, apellidos, cedula, telefono, correo, pin_hash, rol,
     pago_propio, pago_banco, pago_telefono, pago_cedula)
  values
    ('Diego', 'Beleño', 'V-34201580', '04246603660', 'belenodiego0702@gmail.com',
     extensions.crypt(v_pin, extensions.gen_salt('bf', 10)), 'ADMIN',
     true, '', '04246603660', 'V-34201580')
  returning * into v_cuenta;

  raise notice 'Cuenta administradora creada para %.', v_cuenta.cedula;
end;
$$;

-- La cuenta viaja a la app sin el hash ni el estado de bloqueo.
create or replace function public.bt_cuenta_json(a public.accounts)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'nombres',   a.nombres,
    'apellidos', a.apellidos,
    'cedula',    a.cedula,
    'telefono',  a.telefono,
    'correo',    a.correo,
    'rol',       a.rol,
    'datosPago', jsonb_build_object(
                   'propio',   a.pago_propio,
                   'banco',    a.pago_banco,
                   'telefono', a.pago_telefono,
                   'cedula',   a.pago_cedula)
  );
$$;

-- ------------------------------------------------------------
-- 6. Fase 1: el lote nace FABRICADA
-- ------------------------------------------------------------
drop function if exists public.bt_generar_lote(int, text, int, int);

create or replace function public.bt_generar_lote(
  p_cantidad int,
  p_patrocinante text default null,
  p_estado int default 23,
  p_tarifa int default 1,
  p_origen text default 'FABRICANTE'
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cantidad int := coalesce(p_cantidad, 0);
  v_estado   int := coalesce(p_estado, 23);
  v_tarifa   int := coalesce(p_tarifa, 1);
  v_origen   text := upper(trim(coalesce(p_origen, 'FABRICANTE')));
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

  if v_origen not in ('FABRICANTE', 'ESTACION') then
    raise exception 'El origen del lote debe ser FABRICANTE o ESTACION.';
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
    (batch_number, sponsor_name, cards_quantity, state_code, fare_type, origen)
  values
    (v_numero, nullif(trim(coalesce(p_patrocinante, '')), ''), v_cantidad, v_estado, v_tarifa, v_origen)
  returning id into v_lote;

  for i in 0..(v_cantidad - 1) loop
    v_base := lpad(v_estado::text, 2, '0') || v_tarifa::text
              || lpad((v_desde + i)::text, 6, '0');
    v_serial := substr(v_base, 1, 2) || '-' || substr(v_base, 3, 1) || '-'
                || substr(v_base, 4, 6) || '-' || public.bt_luhn_digito(v_base);

    insert into public.cards (visible_id, state_code, fare_type, batch_id, status)
    values (v_serial, v_estado, v_tarifa, v_lote, 'FABRICADA');

    v_tarjetas := v_tarjetas || jsonb_build_object(
      'serial', v_serial,
      'barcode', regexp_replace(v_serial, '\D', '', 'g'),
      'estado', 'FABRICADA'
    );
  end loop;

  return jsonb_build_object(
    'lote', jsonb_build_object(
      'id', v_lote,
      'numero', v_numero,
      'patrocinante', nullif(trim(coalesce(p_patrocinante, '')), ''),
      'cantidad', v_cantidad,
      'origen', v_origen,
      'desde', (v_tarjetas -> 0 ->> 'serial'),
      'hasta', (v_tarjetas -> (v_cantidad - 1) ->> 'serial')
    ),
    'tarjetas', v_tarjetas
  );
end;
$$;

-- ------------------------------------------------------------
-- 7. Fase 2: reclamo del plástico desde el portal
-- ------------------------------------------------------------
create or replace function public.bt_vincular(p_token text, p_serial text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta  public.accounts := public.bt_sesion_cuenta(p_token);
  v_serial  text := trim(coalesce(p_serial, ''));
  v_tarjeta public.cards;
begin
  if v_serial !~ '^\d{2}-\d-\d{6}-\d$' or not public.bt_luhn_valido(v_serial) then
    raise exception 'bt:datos:El serial tiene 10 dígitos (ej. 23-1-000001-9).';
  end if;

  select * into v_tarjeta from public.cards where visible_id = v_serial for update;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos ese serial. Revisa el número impreso.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Esa tarjeta venció. Pasa por taquilla para renovarla.';
  end if;

  if v_tarjeta.status = 'BLOCKED' then
    raise exception 'bt:bloqueada:Esa tarjeta está bloqueada. Comunícate con atención al cliente.';
  end if;

  if v_tarjeta.status = 'LOST' then
    raise exception 'bt:bloqueada:Esa tarjeta está reportada como perdida. Comunícate con atención al cliente.';
  end if;

  if v_tarjeta.account_id = v_cuenta.id then
    raise exception 'bt:duplicada:Esa tarjeta ya está en tu billetera.';
  end if;

  if v_tarjeta.account_id is not null then
    raise exception 'bt:ya-activada:Esa tarjeta ya está vinculada a otra cuenta. Verifica el serial.';
  end if;

  update public.cards
     set account_id   = v_cuenta.id,
         nombre       = v_cuenta.nombres || ' ' || v_cuenta.apellidos,
         status       = 'ACTIVE',
         asignada_at  = now(),
         asignada_por = 'portal'
   where id = v_tarjeta.id;

  insert into public.card_events (card_id, evento, canal, operador, detalle)
  values (v_tarjeta.id, 'ASIGNADA', 'portal', v_cuenta.cedula,
          jsonb_build_object('lote', v_tarjeta.batch_id, 'cuenta', v_cuenta.id));

  return public.bt_billetera_json(v_cuenta);
end;
$$;

-- ------------------------------------------------------------
-- 8. Estación de asignación (lector USB / ESP32)
-- ------------------------------------------------------------
create or replace function public.bt_estacion_enrolar(
  p_lote uuid,
  p_items jsonb,
  p_operador text default ''
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_item    jsonb;
  v_serial  text;
  v_uid     text;
  v_op      text := nullif(trim(coalesce(p_operador, '')), '');
  v_tarjeta public.cards;
  v_ok      int := 0;
  v_errores jsonb := '[]'::jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'bt:datos:Envía una lista de pares serial/UID.';
  end if;

  if jsonb_array_length(p_items) = 0 then
    raise exception 'bt:datos:La lista de enrolamiento está vacía.';
  end if;

  if jsonb_array_length(p_items) > 5000 then
    raise exception 'bt:datos:Carga máximo 5.000 tarjetas por tanda.';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_serial := trim(coalesce(v_item ->> 'serial', ''));
    v_uid    := public.bt_normalizar_mac(v_item ->> 'uid');

    begin
      if v_serial !~ '^\d{2}-\d-\d{6}-\d$' or not public.bt_luhn_valido(v_serial) then
        raise exception 'Serial inválido';
      end if;

      if v_uid !~ '^[0-9A-F]{8,20}$' then
        raise exception 'UID inválido';
      end if;

      select * into v_tarjeta from public.cards where visible_id = v_serial for update;

      if not found then
        raise exception 'Serial no registrado';
      end if;

      if p_lote is not null and v_tarjeta.batch_id is distinct from p_lote then
        raise exception 'El serial no pertenece al lote';
      end if;

      if v_tarjeta.chip_uid is not null and v_tarjeta.chip_uid <> v_uid then
        raise exception 'Ya está enrolada con el UID %', v_tarjeta.chip_uid;
      end if;

      if exists (
        select 1 from public.cards where chip_uid = v_uid and id <> v_tarjeta.id
      ) then
        raise exception 'El UID ya pertenece a otra tarjeta';
      end if;

      update public.cards
         set chip_uid    = v_uid,
             enrolada_at = coalesce(enrolada_at, now()),
             enrolada_por = coalesce(enrolada_por, v_op)
       where id = v_tarjeta.id;

      insert into public.card_events (card_id, evento, canal, operador, detalle)
      values (v_tarjeta.id, 'ENROLADA', 'estacion', v_op,
              jsonb_build_object('uid', v_uid, 'lote', v_tarjeta.batch_id));

      v_ok := v_ok + 1;
    exception when others then
      v_errores := v_errores || jsonb_build_object(
        'serial', v_serial, 'uid', v_uid, 'motivo', sqlerrm
      );
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'enroladas', v_ok,
    'rechazadas', jsonb_array_length(v_errores),
    'errores', v_errores
  );
end;
$$;

-- Espejo del lote para imprimir la hoja de la estación.
create or replace function public.bt_estacion_catalogo(p_lote uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_lote public.card_batches;
begin
  select * into v_lote from public.card_batches where id = p_lote;

  if not found then
    raise exception 'No existe el lote %.', p_lote;
  end if;

  return jsonb_build_object(
    'lote', jsonb_build_object(
      'id', v_lote.id,
      'numero', v_lote.batch_number,
      'patrocinante', v_lote.sponsor_name,
      'cantidad', v_lote.cards_quantity,
      'origen', v_lote.origen,
      'creado', v_lote.created_at
    ),
    'tarjetas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'serial', c.visible_id,
               'uid', coalesce(c.chip_uid, ''),
               'estado', c.status,
               'asignada', c.asignada_at
             ) order by c.visible_id)
        from public.cards c
       where c.batch_id = v_lote.id
    ), '[]'::jsonb)
  );
end;
$$;

-- Asignación en taquilla: vincula el plástico a una cuenta ya registrada.
create or replace function public.bt_estacion_asignar(
  p_serial text,
  p_cedula text,
  p_operador text default ''
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_op      text := nullif(trim(coalesce(p_operador, '')), '');
  v_cuenta  public.accounts;
  v_tarjeta public.cards;
begin
  if v_digitos !~ '^\d{6,8}$' then
    raise exception 'bt:datos:Escribe la cédula del titular (6 a 8 dígitos).';
  end if;

  select * into v_cuenta from public.accounts where cedula_digitos = v_digitos;

  if not found then
    raise exception 'bt:sin-cuenta:No hay una cuenta registrada con esa cédula.';
  end if;

  select * into v_tarjeta
    from public.cards
   where visible_id = trim(coalesce(p_serial, ''))
     for update;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos ese serial.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Esa tarjeta venció.';
  end if;

  if v_tarjeta.status in ('BLOCKED', 'LOST') then
    raise exception 'bt:bloqueada:Esa tarjeta no admite asignación.';
  end if;

  if v_tarjeta.account_id = v_cuenta.id then
    raise exception 'bt:duplicada:Esa tarjeta ya está en la billetera de esa cuenta.';
  end if;

  if v_tarjeta.account_id is not null then
    raise exception 'bt:ya-activada:Esa tarjeta ya está vinculada a otra cuenta.';
  end if;

  update public.cards
     set account_id   = v_cuenta.id,
         nombre       = v_cuenta.nombres || ' ' || v_cuenta.apellidos,
         status       = 'ACTIVE',
         asignada_at  = now(),
         asignada_por = coalesce(v_op, 'taquilla')
   where id = v_tarjeta.id;

  insert into public.card_events (card_id, evento, canal, operador, detalle)
  values (v_tarjeta.id, 'ASIGNADA', 'taquilla', v_op,
          jsonb_build_object('cuenta', v_cuenta.id, 'lote', v_tarjeta.batch_id));

  return public.bt_billetera_json(v_cuenta);
end;
$$;

-- ------------------------------------------------------------
-- 9. Extravío: un plástico sin dueño no se reporta
-- ------------------------------------------------------------
create or replace function public.bt_reportar_perdida(p_visible_id text, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_serial text := trim(coalesce(p_visible_id, ''));
begin
  update public.cards
     set status = 'LOST'
   where visible_id = v_serial
     and status <> 'FABRICADA'
  returning id into v_id;

  if v_id is null then
    if exists (select 1 from public.cards where visible_id = v_serial) then
      raise exception 'La tarjeta % aún no está asignada a una cuenta.', v_serial;
    end if;

    raise exception 'No existe la tarjeta %.', v_serial;
  end if;

  delete from public.card_sessions where card_id = v_id;

  insert into public.card_events (card_id, evento, canal, operador, detalle)
  values (v_id, 'PERDIDA', 'sistema', null, jsonb_build_object('motivo', p_motivo));

  return jsonb_build_object('ok', true, 'estado', 'LOST', 'motivo', p_motivo);
end;
$$;

-- ------------------------------------------------------------
-- 10. Tablero: inventario, fabricadas y asignadas
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
      'fabricadas', (select count(*) from public.cards where status = 'FABRICADA'),
      'activas', (select count(*) from public.cards where status = 'ACTIVE'),
      'bloqueadas', (select count(*) from public.cards where status = 'BLOCKED'),
      'perdidas', (select count(*) from public.cards where status = 'LOST'),
      'asignadas', (select count(*) from public.cards where asignada_at is not null),
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
-- 11. Permisos
-- ------------------------------------------------------------
revoke all on table public.card_events from anon, authenticated;

revoke all on function public.bt_generar_lote(int, text, int, int, text) from public, anon, authenticated;
revoke all on function public.bt_estacion_enrolar(uuid, jsonb, text)      from public, anon, authenticated;
revoke all on function public.bt_estacion_catalogo(uuid)                  from public, anon, authenticated;
revoke all on function public.bt_estacion_asignar(text, text, text)       from public, anon, authenticated;

grant execute on function public.bt_generar_lote(int, text, int, int, text) to service_role;
grant execute on function public.bt_estacion_enrolar(uuid, jsonb, text)      to service_role;
grant execute on function public.bt_estacion_catalogo(uuid)                  to service_role;
grant execute on function public.bt_estacion_asignar(text, text, text)       to service_role;

-- ------------------------------------------------------------
-- 12. Lote de arranque (solo si la base quedó vacía)
-- ------------------------------------------------------------
do $$
declare
  v_lote jsonb;
begin
  if exists (select 1 from public.cards) then
    return;
  end if;

  select public.bt_generar_lote(20, 'Arranque corporativo', 23, 1, 'FABRICANTE')
    into v_lote;

  raise notice 'Lote de arranque generado: %', v_lote -> 'lote';
end;
$$;
