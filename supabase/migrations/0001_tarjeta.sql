-- ============================================================
-- BLINK · esquema del ecosistema (tarjetas, rutas y unidades)
-- Pegar completo en el SQL Editor del proyecto Supabase
-- (gakkfzqcrapxeierfdhk) y ejecutar una sola vez.
--
-- Este archivo es la migración base: crea las tablas del documento
-- técnico (cards, card_batches, transit_routes, vehicles, recharges,
-- trips_telemetry) más el extracto del pasajero y las sesiones.
-- La operación (validador, lotes, liquidación) va en 0003_operacion.sql.
--
-- Todo el acceso pasa por funciones RPC `bt_*` con SECURITY DEFINER:
-- las tablas tienen RLS activado y sin políticas, así que la llave
-- pública del navegador no puede leer ni escribir nada por su cuenta.
-- ============================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------
-- 1. Ajustes públicos (datos de Pago Móvil, topes, atención)
-- ------------------------------------------------------------
create table if not exists public.settings (
  clave      text primary key,
  valor      jsonb not null,
  actualizada timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. Utilidades internas
-- ------------------------------------------------------------
create or replace function public.bt_solo_digitos(p_texto text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(p_texto, ''), '\D', '', 'g');
$$;

-- ID BLINK impreso (ISO/IEC 7812-1): 2 dígitos de entidad federal, 1 de
-- tarifa, 6 secuenciales y el verificador de Luhn. 231000001 → 23-1-000001-9.
create or replace function public.bt_luhn_valido(p_serial text)
returns boolean language plpgsql immutable as $$
declare
  v_digitos text := regexp_replace(coalesce(p_serial, ''), '\D', '', 'g');
  v_suma int := 0;
  v_n int;
  i int;
begin
  if length(v_digitos) <> 10 then
    return false;
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

  return (10 - (v_suma % 10)) % 10 = substr(v_digitos, 10, 1)::int;
end;
$$;

-- Mismo criterio que la app: 4 dígitos, sin repeticiones ni secuencias.
create or replace function public.bt_pin_valido(p_pin text)
returns boolean language sql immutable as $$
  select p_pin ~ '^\d{4}$'
     and p_pin !~ '^(\d)\1{3}$'
     and p_pin not in (
       '0123', '1234', '2345', '3456', '4567', '5678', '6789',
       '9876', '8765', '7654', '6543', '5432', '4321', '3210'
     );
$$;

-- ------------------------------------------------------------
-- 3. Lotes de producción y patrocinantes
-- ------------------------------------------------------------
create table if not exists public.card_batches (
  id             uuid primary key default gen_random_uuid(),
  batch_number   int unique not null check (batch_number > 0),
  sponsor_name   varchar(120),
  cards_quantity int not null check (cards_quantity > 0),
  state_code     smallint not null default 23 check (state_code between 1 and 99),
  fare_type      smallint not null default 1 check (fare_type in (1, 2)),
  created_at     timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 4. Rutas de transporte
-- ------------------------------------------------------------
create table if not exists public.transit_routes (
  id            uuid primary key default gen_random_uuid(),
  name          varchar(100) not null,
  general_fare  numeric(10,2) not null check (general_fare > 0),
  student_fare  numeric(10,2) not null check (student_fare > 0),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 5. Unidades, choferes y cuenta de liquidación
-- ------------------------------------------------------------
create table if not exists public.vehicles (
  id                    uuid primary key default gen_random_uuid(),
  route_id              uuid references public.transit_routes(id) on delete set null,
  plate_number          varchar(20) unique not null,
  vehicle_type          varchar(20) not null check (vehicle_type in ('CARRO', 'VAN', 'BUS')),
  driver_name           varchar(120) not null,
  driver_doc_id         varchar(20) not null,
  bank_code             varchar(4) not null,
  bank_account_or_phone varchar(30) not null,
  -- MAC del ESP32 sin separadores, en mayúsculas: A0B1C2D3E4F5.
  validator_mac         varchar(32) unique not null
                        check (validator_mac ~ '^[0-9A-F]{12}$'),
  commission_pct        numeric(5,2) not null default 8.00
                        check (commission_pct between 0 and 50),
  line_fee              numeric(12,2) not null default 0 check (line_fee >= 0),
  active                boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 6. Tarjetas (vínculo físico-virtual)
-- ------------------------------------------------------------
create table if not exists public.cards (
  id               uuid primary key default gen_random_uuid(),
  -- CSN de fábrica del MIFARE, en hex mayúsculas (ej. 0484CC62).
  chip_uid         text unique check (chip_uid is null or chip_uid ~ '^[0-9A-F]{8,20}$'),
  visible_id       text not null unique
                   check (visible_id ~ '^\d{2}-\d-\d{6}-\d$' and public.bt_luhn_valido(visible_id)),
  -- Cadena numérica del Code 128 (sin guiones).
  barcode_data     text generated always as (regexp_replace(visible_id, '\D', '', 'g')) stored,
  state_code       smallint not null default 23,
  fare_type        smallint not null default 1 check (fare_type in (1, 2)),
  virtual_balance  numeric(12,2) not null default 0 check (virtual_balance >= 0),
  last_chip_balance numeric(12,2) not null default 0 check (last_chip_balance >= 0),
  status           text not null default 'ACTIVE'
                   check (status in ('ACTIVE', 'BLOCKED', 'LOST')),
  batch_id         uuid references public.card_batches(id) on delete set null,
  nombre           text not null default 'Titular',
  cedula           text,
  cedula_digitos   text generated always as
                   (nullif(regexp_replace(coalesce(cedula, ''), '\D', '', 'g'), '')) stored,
  telefono         text not null default '',
  tarifa           numeric(12,2) not null default 15 check (tarifa > 0),
  pin_hash         text,
  intentos         int not null default 0 check (intentos >= 0),
  bloqueado_hasta  timestamptz,
  emitida          timestamptz not null default now(),
  vence            timestamptz not null default now() + interval '5 years',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint cards_identificador_coherente check (
    state_code = substring(visible_id from 1 for 2)::int
    and fare_type = substring(visible_id from 4 for 1)::int
  )
);

create unique index if not exists cards_barcode_idx on public.cards (barcode_data);
create unique index if not exists cards_cedula_idx on public.cards (cedula_digitos);

-- Un plástico vencido no se puede usar, aunque siga en la base.
create or replace function public.bt_tarjeta_vigente(t public.cards)
returns boolean language sql stable as $$
  select t.vence > now();
$$;

-- El portal conoce dos estados; LOST se presenta como bloqueada.
create or replace function public.bt_estado_portal(p_status text)
returns text language sql immutable as $$
  select case when p_status = 'ACTIVE' then 'activa' else 'bloqueada' end;
$$;

create or replace function public.bt_tarjeta_json(t public.cards)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'serial',  t.visible_id,
    'uid',     coalesce(t.chip_uid, ''),
    'titular', jsonb_build_object(
                 'nombre',   t.nombre,
                 'cedula',   coalesce(t.cedula, ''),
                 'telefono', t.telefono),
    'saldo',   t.virtual_balance,
    'estado',  public.bt_estado_portal(t.status),
    'emitida', t.emitida,
    'vence',   t.vence,
    'tarifa',  t.tarifa
  );
$$;

-- ------------------------------------------------------------
-- 7. Extracto del pasajero
-- ------------------------------------------------------------
create table if not exists public.card_movements (
  id            uuid primary key default gen_random_uuid(),
  card_id       uuid not null references public.cards(id) on delete cascade,
  tipo          text not null check (tipo in ('recarga', 'viaje', 'devolucion', 'ajuste')),
  monto         numeric(12,2) not null,
  saldo_despues numeric(12,2) not null,
  detalle       text not null,
  estado        text not null default 'aprobado'
                check (estado in ('aprobado', 'pendiente', 'rechazado')),
  unidad        text,
  banco         text,
  referencia    text,
  at            timestamptz not null default now()
);

create index if not exists card_movements_card_idx
  on public.card_movements (card_id, at desc);

create or replace function public.bt_movimiento_json(m public.card_movements, p_serial text)
returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id',           m.id,
    'serial',       p_serial,
    'tipo',         m.tipo,
    'monto',        m.monto,
    'saldoDespues', m.saldo_despues,
    'at',           m.at,
    'detalle',      m.detalle,
    'estado',       m.estado,
    'unidad',       m.unidad,
    'banco',        m.banco,
    'referencia',   m.referencia
  ));
$$;

-- ------------------------------------------------------------
-- 8. Recargas por Pago Móvil
-- ------------------------------------------------------------
create table if not exists public.recharges (
  id              uuid primary key default gen_random_uuid(),
  card_id         uuid not null references public.cards(id) on delete cascade,
  movement_id     uuid references public.card_movements(id) on delete set null,
  amount          numeric(12,2) not null check (amount > 0),
  bank            text not null,
  bank_reference  text not null,
  sender_phone    text not null default '',
  status          text not null default 'pendiente'
                  check (status in ('pendiente', 'aprobado', 'rechazado')),
  -- Pasa a TRUE cuando un validador la escribe en el chip.
  synced_to_chip  boolean not null default false,
  synced_at       timestamptz,
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz,
  resolved_by     text
);

-- La misma referencia del mismo banco no puede estar dos veces vigente por tarjeta.
create unique index if not exists recharges_unica_idx
  on public.recharges (card_id, bank, bank_reference)
  where status <> 'rechazado';

create index if not exists recharges_pendientes_idx
  on public.recharges (status, created_at desc);

-- ------------------------------------------------------------
-- 9. Liquidaciones (cierre de lote a choferes)
-- ------------------------------------------------------------
create table if not exists public.settlements (
  id             uuid primary key default gen_random_uuid(),
  vehicle_id     uuid not null references public.vehicles(id) on delete restrict,
  period_start   timestamptz not null,
  period_end     timestamptz not null,
  trips_count    int not null check (trips_count > 0),
  gross          numeric(12,2) not null check (gross >= 0),
  commission_pct numeric(5,2) not null check (commission_pct between 0 and 50),
  commission     numeric(12,2) not null check (commission >= 0),
  line_fee       numeric(12,2) not null default 0 check (line_fee >= 0),
  net            numeric(12,2) not null,
  status         text not null default 'pendiente'
                 check (status in ('pendiente', 'pagada')),
  bank_reference text,
  created_at     timestamptz not null default now(),
  paid_at        timestamptz,
  unique (vehicle_id, period_start, period_end)
);

-- ------------------------------------------------------------
-- 10. Telemetría de viajes (cobros en unidades)
-- ------------------------------------------------------------
create table if not exists public.trips_telemetry (
  id                 uuid primary key default gen_random_uuid(),
  card_id            uuid not null references public.cards(id) on delete cascade,
  vehicle_id         uuid references public.vehicles(id) on delete set null,
  route_id           uuid references public.transit_routes(id) on delete set null,
  movement_id        uuid references public.card_movements(id) on delete set null,
  fare_charged       numeric(10,2) not null check (fare_charged > 0),
  fare_type          smallint not null default 1,
  latitude           double precision,
  longitude          double precision,
  validator_mac      text,
  -- Clave de idempotencia generada por el validador; permite reenviar sin duplicar.
  offline_id         text not null unique,
  chip_balance_after numeric(12,2) check (chip_balance_after >= 0),
  settled            boolean not null default false,
  settlement_id      uuid references public.settlements(id) on delete set null,
  tapped_at          timestamptz not null,
  synced_at          timestamptz not null default now()
);

create index if not exists trips_telemetry_vehicle_idx
  on public.trips_telemetry (vehicle_id, tapped_at desc);
create index if not exists trips_telemetry_settled_idx
  on public.trips_telemetry (settled, tapped_at);

-- ------------------------------------------------------------
-- 11. Sesiones (token que guarda la app por 12 horas)
-- ------------------------------------------------------------
create table if not exists public.card_sessions (
  token    uuid primary key default gen_random_uuid(),
  card_id  uuid not null references public.cards(id) on delete cascade,
  creada   timestamptz not null default now(),
  expira   timestamptz not null default now() + interval '12 hours'
);

create index if not exists card_sessions_expira_idx on public.card_sessions (expira);

-- Devuelve la tarjeta de una sesión válida o lanza el error del dominio.
create or replace function public.bt_sesion_tarjeta(p_token text)
returns public.cards
language plpgsql stable security definer set search_path = public as $$
declare
  v_tarjeta public.cards;
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    raise exception 'bt:sesion:La sesión expiró. Vuelve a entrar con tu PIN.';
  end if;

  select t.* into v_tarjeta
    from public.card_sessions s
    join public.cards t on t.id = s.card_id
   where s.token = p_token::uuid
     and s.expira > now();

  if not found then
    raise exception 'bt:sesion:La sesión expiró. Vuelve a entrar con tu PIN.';
  end if;

  if v_tarjeta.status = 'BLOCKED' then
    raise exception 'bt:bloqueada:Tu tarjeta está bloqueada. Comunícate con atención al cliente.';
  end if;

  if v_tarjeta.status = 'LOST' then
    raise exception 'bt:bloqueada:Tu tarjeta está reportada como perdida. Comunícate con atención al cliente.';
  end if;

  return v_tarjeta;
end;
$$;

-- Tope de recarga por operación, publicado por Admin.
create or replace function public.bt_tope_recarga()
returns numeric language sql stable as $$
  select coalesce(
    (select (valor ->> 'topeRecarga')::numeric
       from public.settings where clave = 'publico'),
    5000
  );
$$;

create or replace function public.bt_tocar_actualizada()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists cards_actualizada on public.cards;
create trigger cards_actualizada
  before update on public.cards
  for each row execute function public.bt_tocar_actualizada();

drop trigger if exists vehicles_actualizada on public.vehicles;
create trigger vehicles_actualizada
  before update on public.vehicles
  for each row execute function public.bt_tocar_actualizada();

-- ------------------------------------------------------------
-- 12. RPC públicas (las llama la app del pasajero)
-- ------------------------------------------------------------

-- Entrar con cédula + PIN. 5 fallos dejan la tarjeta 5 minutos en espera.
--
-- Ojo: el fallo de PIN se devuelve como {'error','mensaje'} y no con RAISE.
-- RAISE revierte la transacción y con ella el contador de intentos, así que
-- el bloqueo nunca se guardaría. El resto de errores sí abortan la llamada.
create or replace function public.bt_entrar(p_cedula text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_tarjeta public.cards;
  v_token   uuid;
  v_fallos  int;
begin
  if length(v_digitos) < 6 or length(v_digitos) > 8 then
    raise exception 'bt:sin-tarjeta:No encontramos una tarjeta con esa cédula.';
  end if;

  select * into v_tarjeta
    from public.cards
   where cedula_digitos = v_digitos;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos una tarjeta con esa cédula.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Tu tarjeta venció. Pasa por taquilla para renovarla.';
  end if;

  if v_tarjeta.bloqueado_hasta is not null and v_tarjeta.bloqueado_hasta > now() then
    raise exception 'bt:credenciales:Demasiados intentos fallidos. Espera % min o recupera tu PIN en atención al cliente.',
      greatest(1, ceil(extract(epoch from (v_tarjeta.bloqueado_hasta - now())) / 60)::int);
  end if;

  if v_tarjeta.pin_hash is null then
    raise exception 'bt:sin-tarjeta:Tu tarjeta todavía no tiene PIN. Actívala primero.';
  end if;

  if v_tarjeta.status = 'BLOCKED' then
    raise exception 'bt:bloqueada:Tu tarjeta está bloqueada. Comunícate con atención al cliente.';
  end if;

  if v_tarjeta.status = 'LOST' then
    raise exception 'bt:bloqueada:Tu tarjeta está reportada como perdida. Comunícate con atención al cliente.';
  end if;

  if crypt(coalesce(p_pin, ''), v_tarjeta.pin_hash) <> v_tarjeta.pin_hash then
    v_fallos := case
      when v_tarjeta.bloqueado_hasta is not null and v_tarjeta.bloqueado_hasta <= now() then 1
      else v_tarjeta.intentos + 1
    end;

    update public.cards
       set intentos = v_fallos,
           bloqueado_hasta = case when v_fallos >= 5 then now() + interval '5 minutes' end
     where id = v_tarjeta.id;

    if v_fallos >= 5 then
      return jsonb_build_object(
        'error', 'credenciales',
        'mensaje', 'Demasiados intentos fallidos. Espera 5 min o recupera tu PIN en atención al cliente.'
      );
    end if;

    return jsonb_build_object(
      'error', 'credenciales',
      'mensaje', 'El PIN no coincide. Inténtalo de nuevo.'
    );
  end if;

  update public.cards
     set intentos = 0, bloqueado_hasta = null
   where id = v_tarjeta.id;

  delete from public.card_sessions where expira < now();

  insert into public.card_sessions (card_id, expira)
  values (v_tarjeta.id, now() + interval '12 hours')
  returning token into v_token;

  return jsonb_build_object(
    'token', v_token,
    'tarjeta', public.bt_tarjeta_json(v_tarjeta)
  );
end;
$$;

-- Activar el plástico: vincula cédula, teléfono y PIN a un serial emitido.
create or replace function public.bt_activar(
  p_cedula text, p_serial text, p_telefono text, p_pin text
)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_serial  text := trim(coalesce(p_serial, ''));
  v_tel     text := public.bt_solo_digitos(p_telefono);
  v_tarjeta public.cards;
  v_token   uuid;
begin
  if length(v_digitos) < 6 or length(v_digitos) > 8 then
    raise exception 'bt:sin-tarjeta:Revisa la cédula: debe tener entre 6 y 8 dígitos.';
  end if;

  if not public.bt_pin_valido(p_pin) then
    raise exception 'bt:pin-invalido:Usa 4 dígitos, sin repeticiones ni secuencias como 1234.';
  end if;

  if v_tel !~ '^0\d{10}$' then
    raise exception 'bt:pin-invalido:El teléfono debe tener 11 dígitos y empezar por 0 (ej. 0414-1234567).';
  end if;

  select * into v_tarjeta from public.cards where visible_id = v_serial for update;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos ese serial. Revisa el número impreso en la tarjeta.';
  end if;

  if v_tarjeta.pin_hash is not null then
    raise exception 'bt:ya-activada:Esa tarjeta ya fue activada. Si no reconoces el cobro, llama a atención al cliente.';
  end if;

  if v_tarjeta.cedula_digitos is not null and v_tarjeta.cedula_digitos <> v_digitos then
    raise exception 'bt:ya-activada:Esa tarjeta está asignada a otra cédula. Revisa el serial.';
  end if;

  if exists (
    select 1
      from public.cards
     where cedula_digitos = v_digitos
       and id <> v_tarjeta.id
  ) then
    raise exception 'bt:ya-activada:Esa cédula ya tiene una tarjeta activa. Entra con tu PIN.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Esa tarjeta venció. Pasa por taquilla para renovarla.';
  end if;

  update public.cards
     set cedula   = upper(trim(p_cedula)),
         telefono = v_tel,
         pin_hash = crypt(p_pin, gen_salt('bf', 10)),
         status   = 'ACTIVE',
         intentos = 0,
         bloqueado_hasta = null
   where id = v_tarjeta.id
  returning * into v_tarjeta;

  insert into public.card_sessions (card_id, expira)
  values (v_tarjeta.id, now() + interval '12 hours')
  returning token into v_token;

  return jsonb_build_object(
    'token', v_token,
    'tarjeta', public.bt_tarjeta_json(v_tarjeta)
  );
end;
$$;

create or replace function public.bt_tarjeta(p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.cards := public.bt_sesion_tarjeta(p_token);
begin
  return jsonb_build_object('tarjeta', public.bt_tarjeta_json(v_tarjeta));
end;
$$;

create or replace function public.bt_movimientos(p_token text, p_limite int default 100)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.cards := public.bt_sesion_tarjeta(p_token);
  v_limite  int := least(greatest(coalesce(p_limite, 100), 1), 300);
  v_lista   jsonb;
begin
  select coalesce(jsonb_agg(
           public.bt_movimiento_json(m, v_tarjeta.visible_id) order by m.at desc
         ), '[]'::jsonb)
    into v_lista
    from (
      select *
        from public.card_movements
       where card_id = v_tarjeta.id
       order by at desc
       limit v_limite
    ) m;

  return jsonb_build_object('movimientos', v_lista);
end;
$$;

-- Reportar un Pago Móvil: queda pendiente hasta que se acredite.
create or replace function public.bt_recargar(
  p_token text, p_monto numeric, p_telefono text, p_banco text, p_referencia text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta    public.cards := public.bt_sesion_tarjeta(p_token);
  v_tope       numeric := public.bt_tope_recarga();
  v_monto      numeric := round(coalesce(p_monto, 0), 2);
  v_tel        text := public.bt_solo_digitos(p_telefono);
  v_banco      text := trim(coalesce(p_banco, ''));
  v_ref_dig    text := public.bt_solo_digitos(p_referencia);
  v_ref        text;
  v_movimiento public.card_movements;
  v_reportes   int;
begin
  if v_monto <= 0 then
    raise exception 'bt:pin-invalido:Escribe el monto que transferiste (mayor que 0).';
  end if;

  if v_monto <> coalesce(p_monto, 0) then
    raise exception 'bt:pin-invalido:Usa como máximo dos decimales.';
  end if;

  if v_monto < 1 then
    raise exception 'bt:pin-invalido:El monto mínimo por recarga es Bs 1,00.';
  end if;

  if v_monto > v_tope then
    raise exception 'bt:pin-invalido:El tope por recarga es % Bs. Divide el pago en varias operaciones.',
      trim(to_char(round(v_tope), 'FM999999999'));
  end if;

  if v_tel !~ '^0\d{10}$' then
    raise exception 'bt:pin-invalido:El teléfono debe tener 11 dígitos y empezar por 0 (ej. 0414-1234567).';
  end if;

  if length(v_banco) < 2 then
    raise exception 'bt:pin-invalido:Selecciona el banco emisor.';
  end if;

  if length(v_ref_dig) < 4 then
    raise exception 'bt:pin-invalido:Escribe los últimos 4 dígitos de la referencia.';
  end if;

  v_ref := right(v_ref_dig, 4);

  select count(*) into v_reportes
    from public.recharges
   where card_id = v_tarjeta.id
     and created_at > now() - interval '10 minutes';

  if v_reportes >= 6 then
    raise exception 'bt:duplicada:Demasiados reportes seguidos. Espera unos minutos antes de enviar otro.';
  end if;

  if exists (
    select 1
      from public.recharges
     where card_id = v_tarjeta.id
       and bank = v_banco
       and bank_reference = v_ref
       and status <> 'rechazado'
  ) then
    raise exception 'bt:duplicada:Ya reportaste esa referencia. Revisa Movimientos.';
  end if;

  insert into public.card_movements
    (card_id, tipo, monto, saldo_despues, detalle, estado, banco, referencia)
  values
    (v_tarjeta.id, 'recarga', v_monto, v_tarjeta.virtual_balance, 'Pago Móvil en revisión',
     'pendiente', v_banco, v_ref)
  returning * into v_movimiento;

  insert into public.recharges
    (card_id, movement_id, amount, sender_phone, bank, bank_reference, created_at)
  values
    (v_tarjeta.id, v_movimiento.id, v_monto, v_tel, v_banco, v_ref, v_movimiento.at);

  return jsonb_build_object(
    'movimiento', public.bt_movimiento_json(v_movimiento, v_tarjeta.visible_id)
  );
end;
$$;

create or replace function public.bt_cambiar_pin(p_token text, p_actual text, p_nuevo text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tarjeta public.cards := public.bt_sesion_tarjeta(p_token);
begin
  if v_tarjeta.pin_hash is null
     or crypt(coalesce(p_actual, ''), v_tarjeta.pin_hash) <> v_tarjeta.pin_hash then
    raise exception 'bt:credenciales:El PIN actual no coincide.';
  end if;

  if not public.bt_pin_valido(p_nuevo) then
    raise exception 'bt:pin-invalido:Usa 4 dígitos, sin repeticiones ni secuencias como 1234.';
  end if;

  if p_nuevo = p_actual then
    raise exception 'bt:pin-invalido:El PIN nuevo debe ser distinto al actual.';
  end if;

  update public.cards
     set pin_hash = crypt(p_nuevo, gen_salt('bf', 10)),
         intentos = 0,
         bloqueado_hasta = null
   where id = v_tarjeta.id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bt_salir(p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_token ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    delete from public.card_sessions where token = p_token::uuid;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bt_ajustes()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_valor jsonb;
begin
  select valor into v_valor from public.settings where clave = 'publico';

  return coalesce(v_valor, jsonb_build_object(
    'pagoMovil', jsonb_build_object(
      'banco', 'Banesco',
      'rif', 'J-00000000-0',
      'telefono', '0414-0000000',
      'titular', 'BLINK PASAJES, C.A.'),
    'topeRecarga', 5000,
    'atencion', '0800-BLINK-00'
  ));
end;
$$;

-- ------------------------------------------------------------
-- 13. RPC de operación (solo service_role: taquilla, lector y admin)
-- ------------------------------------------------------------

-- Emite un plástico sin PIN: queda listo para que el pasajero lo active.
create or replace function public.bt_emitir_tarjeta(
  p_serial text, p_nombre text, p_cedula text,
  p_telefono text default '', p_tarifa numeric default 15
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.cards;
begin
  if coalesce(trim(p_serial), '') !~ '^\d{2}-\d-\d{6}-\d$'
     or not public.bt_luhn_valido(trim(p_serial)) then
    raise exception 'El serial debe tener 10 dígitos y Luhn válido (ej. 23-1-000001-9).';
  end if;

  insert into public.cards (visible_id, nombre, cedula, telefono, tarifa, pin_hash)
  values (trim(p_serial), coalesce(nullif(trim(p_nombre), ''), 'Titular'),
          nullif(trim(p_cedula), ''), public.bt_solo_digitos(p_telefono), p_tarifa, null)
  returning * into v_tarjeta;

  return public.bt_tarjeta_json(v_tarjeta);
end;
$$;

-- Cobra un pasaje. Lo llama el lector (POS) al validar el chip.
create or replace function public.bt_cobrar_viaje(
  p_serial text, p_unidad text default null, p_monto numeric default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta    public.cards;
  v_monto      numeric;
  v_saldo      numeric;
  v_movimiento public.card_movements;
begin
  select * into v_tarjeta
    from public.cards
   where visible_id = trim(coalesce(p_serial, ''))
     for update;

  if not found then
    raise exception 'Tarjeta desconocida.';
  end if;

  if v_tarjeta.status <> 'ACTIVE' then
    raise exception 'Tarjeta bloqueada.';
  end if;

  v_monto := coalesce(p_monto, v_tarjeta.tarifa);

  if v_monto <= 0 then
    raise exception 'Monto inválido.';
  end if;

  if v_tarjeta.virtual_balance < v_monto then
    raise exception 'Saldo insuficiente.';
  end if;

  v_saldo := v_tarjeta.virtual_balance - v_monto;

  update public.cards set virtual_balance = v_saldo where id = v_tarjeta.id;

  insert into public.card_movements
    (card_id, tipo, monto, saldo_despues, detalle, estado, unidad)
  values
    (v_tarjeta.id, 'viaje', -v_monto, v_saldo, 'Pasaje en la línea', 'aprobado',
     nullif(trim(coalesce(p_unidad, '')), ''))
  returning * into v_movimiento;

  return jsonb_build_object(
    'movimiento', public.bt_movimiento_json(v_movimiento, v_tarjeta.visible_id),
    'saldo', v_saldo,
    'titular', v_tarjeta.nombre
  );
end;
$$;

create or replace function public.bt_aprobar_recarga(p_recarga uuid, p_admin text default 'admin')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_recarga  public.recharges;
  v_saldo    numeric;
begin
  select * into v_recarga from public.recharges where id = p_recarga for update;

  if not found then
    raise exception 'Recarga no encontrada.';
  end if;

  if v_recarga.status <> 'pendiente' then
    raise exception 'Esa recarga ya fue %.', v_recarga.status;
  end if;

  update public.cards
     set virtual_balance = virtual_balance + v_recarga.amount
   where id = v_recarga.card_id
  returning virtual_balance into v_saldo;

  update public.card_movements
     set estado = 'aprobado',
         saldo_despues = v_saldo,
         detalle = 'Pago Móvil aprobado'
   where id = v_recarga.movement_id;

  update public.recharges
     set status = 'aprobado', resolved_at = now(), resolved_by = p_admin
   where id = v_recarga.id;

  return jsonb_build_object('ok', true, 'saldo', v_saldo);
end;
$$;

create or replace function public.bt_rechazar_recarga(
  p_recarga uuid, p_admin text default 'admin', p_motivo text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_recarga public.recharges;
begin
  select * into v_recarga from public.recharges where id = p_recarga for update;

  if not found then
    raise exception 'Recarga no encontrada.';
  end if;

  if v_recarga.status <> 'pendiente' then
    raise exception 'Esa recarga ya fue %.', v_recarga.status;
  end if;

  update public.card_movements
     set estado = 'rechazado',
         detalle = coalesce(nullif(trim(p_motivo), ''), 'Pago Móvil rechazado')
   where id = v_recarga.movement_id;

  update public.recharges
     set status = 'rechazado', resolved_at = now(), resolved_by = p_admin
   where id = v_recarga.id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bt_bloquear_tarjeta(p_serial text, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  update public.cards
     set status = 'BLOCKED'
   where visible_id = trim(coalesce(p_serial, ''))
  returning id into v_id;

  if v_id is null then
    raise exception 'Tarjeta desconocida.';
  end if;

  delete from public.card_sessions where card_id = v_id;

  return jsonb_build_object('ok', true, 'motivo', p_motivo);
end;
$$;

create or replace function public.bt_desbloquear_tarjeta(p_serial text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.cards
     set status = 'ACTIVE', intentos = 0, bloqueado_hasta = null
   where visible_id = trim(coalesce(p_serial, ''));

  if not found then
    raise exception 'Tarjeta desconocida.';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Bandeja de recargas para el panel de Admin.
create or replace function public.bt_recargas_pendientes(p_limite int default 100)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_lista jsonb;
begin
  select coalesce(jsonb_agg(fila order by fila ->> 'reportada' desc), '[]'::jsonb)
    into v_lista
    from (
      select jsonb_build_object(
               'recarga', r.id,
               'movimiento', r.movement_id,
               'serial', c.visible_id,
               'titular', c.nombre,
               'cedula', coalesce(c.cedula, ''),
               'monto', r.amount,
               'telefono', r.sender_phone,
               'banco', r.bank,
               'referencia', r.bank_reference,
               'estado', r.status,
               'reportada', r.created_at
             ) as fila
        from public.recharges r
        join public.cards c on c.id = r.card_id
       where r.status = 'pendiente'
       order by r.created_at asc
       limit least(greatest(coalesce(p_limite, 100), 1), 500)
    ) pendientes;

  return jsonb_build_object('recargas', v_lista);
end;
$$;

-- ------------------------------------------------------------
-- 14. Seguridad: RLS cerrado, sin políticas directas
-- ------------------------------------------------------------
alter table public.settings         enable row level security;
alter table public.card_batches     enable row level security;
alter table public.transit_routes   enable row level security;
alter table public.vehicles         enable row level security;
alter table public.cards            enable row level security;
alter table public.card_movements   enable row level security;
alter table public.recharges        enable row level security;
alter table public.settlements      enable row level security;
alter table public.trips_telemetry  enable row level security;
alter table public.card_sessions    enable row level security;

revoke all on public.settings        from anon, authenticated;
revoke all on public.card_batches    from anon, authenticated;
revoke all on public.transit_routes  from anon, authenticated;
revoke all on public.vehicles        from anon, authenticated;
revoke all on public.cards           from anon, authenticated;
revoke all on public.card_movements  from anon, authenticated;
revoke all on public.recharges       from anon, authenticated;
revoke all on public.settlements     from anon, authenticated;
revoke all on public.trips_telemetry from anon, authenticated;
revoke all on public.card_sessions   from anon, authenticated;

revoke all on function public.bt_solo_digitos(text)                  from public;
revoke all on function public.bt_luhn_valido(text)                   from public;
revoke all on function public.bt_pin_valido(text)                    from public;
revoke all on function public.bt_tarjeta_vigente(public.cards)       from public;
revoke all on function public.bt_estado_portal(text)                 from public;
revoke all on function public.bt_tarjeta_json(public.cards)          from public;
revoke all on function public.bt_movimiento_json(public.card_movements, text) from public;
revoke all on function public.bt_sesion_tarjeta(text)                from public;
revoke all on function public.bt_tope_recarga()                      from public;
revoke all on function public.bt_tocar_actualizada()                 from public;

-- Supabase concede EXECUTE a anon y authenticated en cada función nueva de
-- public. Revocar solo de PUBLIC no alcanza: el permiso explícito sigue
-- vivo. Se cierra todo y se vuelve a abrir únicamente la superficie del
-- portal; las funciones futuras quedan cerradas por defecto.
alter default privileges in schema public
  revoke execute on functions from public, anon, authenticated;

revoke all on all functions in schema public from public, anon, authenticated;

-- Las que usa el navegador con la llave pública.
grant execute on function public.bt_entrar(text, text)                              to anon, authenticated;
grant execute on function public.bt_activar(text, text, text, text)                 to anon, authenticated;
grant execute on function public.bt_tarjeta(text)                                   to anon, authenticated;
grant execute on function public.bt_movimientos(text, int)                          to anon, authenticated;
grant execute on function public.bt_recargar(text, numeric, text, text, text)       to anon, authenticated;
grant execute on function public.bt_cambiar_pin(text, text, text)                   to anon, authenticated;
grant execute on function public.bt_salir(text)                                     to anon, authenticated;
grant execute on function public.bt_ajustes()                                       to anon, authenticated;

-- Solo el backend (service_role): taquilla, lector y panel.
revoke all on function public.bt_emitir_tarjeta(text, text, text, text, numeric) from public;
revoke all on function public.bt_cobrar_viaje(text, text, numeric)               from public;
revoke all on function public.bt_aprobar_recarga(uuid, text)                     from public;
revoke all on function public.bt_rechazar_recarga(uuid, text, text)              from public;
revoke all on function public.bt_bloquear_tarjeta(text, text)                    from public;
revoke all on function public.bt_desbloquear_tarjeta(text)                       from public;
revoke all on function public.bt_recargas_pendientes(int)                        from public;

grant execute on function public.bt_emitir_tarjeta(text, text, text, text, numeric) to service_role;
grant execute on function public.bt_cobrar_viaje(text, text, numeric)               to service_role;
grant execute on function public.bt_aprobar_recarga(uuid, text)                     to service_role;
grant execute on function public.bt_rechazar_recarga(uuid, text, text)              to service_role;
grant execute on function public.bt_bloquear_tarjeta(text, text)                    to service_role;
grant execute on function public.bt_desbloquear_tarjeta(text)                       to service_role;
grant execute on function public.bt_recargas_pendientes(int)                        to service_role;

-- ------------------------------------------------------------
-- 15. Ajustes iniciales (Admin los edita en la tabla settings)
-- ------------------------------------------------------------
insert into public.settings (clave, valor)
values ('publico', jsonb_build_object(
  'pagoMovil', jsonb_build_object(
    'banco', 'Banesco',
    'rif', 'J-00000000-0',
    'telefono', '0414-0000000',
    'titular', 'BLINK PASAJES, C.A.'),
  'topeRecarga', 5000,
  'atencion', '0800-BLINK-00'
))
on conflict (clave) do nothing;
