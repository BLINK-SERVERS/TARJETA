-- ============================================================
-- BLINK · serie 5+3, tarjeta Alfa, mermas y montos enteros
-- Ejecutar después de 0013_portal_exige_enrolada.sql.
--
-- Adopta los documentos BLINK-DOC-12 v2.0.0, BLINK-DOC-13 v2.0.0
-- y BLINK-DOC-SEC-01 v1.0.0:
--   · serial T-LLLLL-UUU-V con letra verificadora (Luhn mod 23)
--   · tarjeta Alfa A-00000-000-H (reemplaza la maestra numérica)
--   · lotes de hasta 999 unidades y números de lote de 5 dígitos
--   · estado SCRAP y rechazos RFPGC / CHIP_ERR
--   · importes enteros en bolívares (sin decimales)
--
-- Producción tiene una sola tarjeta (la maestra) y ningún lote, por
-- lo que el cambio de serie no altera inventario físico.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Importes enteros (bolívares sin decimales)
-- ------------------------------------------------------------
alter table public.cards
  alter column virtual_balance  type integer using round(virtual_balance)::integer,
  alter column last_chip_balance type integer using round(last_chip_balance)::integer,
  alter column tarifa           type integer using round(tarifa)::integer,
  alter column tarifa set default 500;

alter table public.card_movements
  alter column monto         type integer using round(monto)::integer,
  alter column saldo_despues type integer using round(saldo_despues)::integer;

alter table public.recharges
  alter column amount type integer using round(amount)::integer;

alter table public.transit_routes
  alter column general_fare type integer using round(general_fare)::integer,
  alter column student_fare type integer using round(student_fare)::integer;

alter table public.trips_telemetry
  alter column fare_charged       type integer using round(fare_charged)::integer,
  alter column chip_balance_after type integer using round(chip_balance_after)::integer;

alter table public.settlements
  alter column gross      type integer using round(gross)::integer,
  alter column commission type integer using round(commission)::integer,
  alter column line_fee   type integer using round(line_fee)::integer,
  alter column net        type integer using round(net)::integer;

alter table public.vehicles
  alter column line_fee type integer using round(line_fee)::integer;

-- Pasaje estándar del documento: 500 Bs. Estudiante / tercera edad: la mitad.
update public.transit_routes set general_fare = 500, student_fare = 250;
update public.cards set tarifa = 500 where fare_type in (0, 1);
update public.cards set tarifa = 250 where fare_type = 2;

-- ------------------------------------------------------------
-- 2. Serie 5+3: la maestra pasa a ser la tarjeta Alfa
-- ------------------------------------------------------------
alter table public.cards drop constraint if exists cards_visible_id_check;
alter table public.cards drop constraint if exists cards_identificador_coherente;

do $$
declare
  v_viejo text := '00-0-0000000-0';
  v_alfa  text := 'A-00000-000-H';
begin
  if exists (select 1 from public.cards where visible_id = v_alfa)
     and exists (select 1 from public.cards where visible_id = v_viejo) then
    raise exception 'Existen la maestra vieja y la Alfa a la vez';
  end if;

  update public.cards
     set visible_id = v_alfa,
         state_code = 0,
         fare_type  = 0
   where visible_id = v_viejo;

  if found then
    insert into public.card_events (card_id, evento, canal, operador, detalle)
    select id, 'ASIGNADA', 'sistema', 'migracion-0014',
           jsonb_build_object('de', v_viejo, 'a', v_alfa, 'serie', 'ALFA')
      from public.cards
     where visible_id = v_alfa;
  end if;
end;
$$;

-- El código de barras deja de ser solo dígitos: es el serial compacto.
drop index if exists public.cards_barcode_idx;
alter table public.cards drop column if exists barcode_data;
alter table public.cards
  add column barcode_data text
    generated always as (upper(replace(visible_id, '-', ''))) stored;
create unique index cards_barcode_idx on public.cards (barcode_data);

alter table public.cards
  add column if not exists batch_number integer
    generated always as ((substring(visible_id from 3 for 5))::integer) stored,
  add column if not exists serial_number integer
    generated always as ((substring(visible_id from 9 for 3))::integer) stored;

comment on column public.cards.batch_number is
  'Lote de 5 dígitos leído del serial T-LLLLL-UUU-V (0 en la Alfa).';
comment on column public.cards.serial_number is
  'Unidad de 3 dígitos leída del serial T-LLLLL-UUU-V (0 en la Alfa).';

-- ------------------------------------------------------------
-- 3. Estados y bitácora de mermas
-- ------------------------------------------------------------
alter table public.cards drop constraint if exists cards_status_check;
alter table public.cards
  add constraint cards_status_check
  check (status in ('FABRICADA', 'ACTIVE', 'BLOCKED', 'LOST', 'SCRAP'));

alter table public.card_events drop constraint if exists card_events_evento_check;
alter table public.card_events
  add constraint card_events_evento_check
  check (evento in ('ENROLADA', 'ASIGNADA', 'PERDIDA', 'RFPGC', 'CHIP_ERR', 'SCRAP'));

alter table public.card_batches drop constraint if exists card_batches_limite_999;
alter table public.card_batches
  add constraint card_batches_limite_999 check (cards_quantity <= 999);

alter table public.card_batches drop constraint if exists card_batches_numero_max;
alter table public.card_batches
  add constraint card_batches_numero_max check (batch_number <= 99999);

-- ------------------------------------------------------------
-- 4. Verificador Luhn mod 23
-- ------------------------------------------------------------
create or replace function public.bt_luhn_letra(p_base text)
returns text
language plpgsql
immutable
as $$
declare
  v_limpio text := upper(regexp_replace(coalesce(p_base, ''), '[^A-Z0-9]', '', 'g'));
  v_nums   text;
  v_suma   int := 0;
  v_n      int;
  i        int;
  v_alfabeto constant text := 'ABCDEFGHJKLMNPRSTUVWXYZ';  -- sin I, O, Q
begin
  if v_limpio !~ '^[AGE][0-9]{8}$' then
    raise exception 'La base del ID BLINK debe ser A/G/E + 8 dígitos.';
  end if;

  v_nums := lpad(ascii(substr(v_limpio, 1, 1))::text, 2, '0') || substr(v_limpio, 2);

  for i in 1..length(v_nums) loop
    v_n := substr(v_nums, i, 1)::int;
    if (length(v_nums) - i) % 2 = 0 then
      v_n := v_n * 2;
      if v_n > 9 then
        v_n := v_n - 9;
      end if;
    end if;
    v_suma := v_suma + v_n;
  end loop;

  return substr(v_alfabeto, (v_suma % 23) + 1, 1);
end;
$$;

revoke all on function public.bt_luhn_letra(text) from public, anon, authenticated;

create or replace function public.bt_luhn_valido(p_serial text)
returns boolean
language plpgsql
immutable
as $$
declare
  v_compacto text := upper(regexp_replace(coalesce(p_serial, ''), '[^A-Z0-9]', '', 'g'));
begin
  if v_compacto !~ '^[AGE][0-9]{8}[A-HJ-NP-TV-Z]$' then
    return false;
  end if;

  return public.bt_luhn_letra(substr(v_compacto, 1, 9)) = substr(v_compacto, 10, 1);
end;
$$;

-- Vuelven las restricciones con la serie nueva.
alter table public.cards
  add constraint cards_visible_id_check
  check (visible_id ~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NP-TV-Z]$'
         and public.bt_luhn_valido(visible_id));

alter table public.cards
  add constraint cards_identificador_coherente
  check (
    fare_type = case substring(visible_id from 1 for 1)
                  when 'A' then 0 when 'G' then 1 else 2 end
    and ((fare_type = 0) = (batch_number = 0 and serial_number = 0))
    and (fare_type = 0 or (batch_number between 1 and 99999
                           and serial_number between 1 and 999))
  );

-- ------------------------------------------------------------
-- 5. Tarjeta Alfa (reemplaza a bt_crear_tarjeta_maestra)
-- ------------------------------------------------------------
create or replace function public.bt_crear_tarjeta_alfa(
  p_cedula text,
  p_uid text default null,
  p_operador text default '',
  p_tarifa integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_serial  text := 'A-00000-000-H';
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_uid     text := public.bt_normalizar_mac(p_uid);
  v_op      text := nullif(trim(coalesce(p_operador, '')), '');
  v_cuenta  public.accounts;
  v_tarjeta public.cards;
begin
  if v_digitos !~ '^\d{6,8}$' then
    raise exception 'bt:datos:Escribe la cédula de la cuenta dueña (6 a 8 dígitos).';
  end if;

  if v_uid <> '' and v_uid !~ '^[0-9A-F]{8,20}$' then
    raise exception 'bt:datos:El UID debe ser hexadecimal de 8 a 20 caracteres.';
  end if;

  if coalesce(p_tarifa, 0) <= 0 then
    raise exception 'bt:datos:La tarifa debe ser un monto entero mayor que 0.';
  end if;

  select * into v_cuenta from public.accounts where cedula_digitos = v_digitos;

  if not found then
    raise exception 'bt:sin-cuenta:No hay una cuenta registrada con esa cédula.';
  end if;

  if exists (select 1 from public.cards where visible_id = v_serial) then
    raise exception 'bt:duplicada:La tarjeta Alfa % ya existe.', v_serial;
  end if;

  if v_uid <> '' and exists (select 1 from public.cards where chip_uid = v_uid) then
    raise exception 'bt:duplicada:El UID % ya pertenece a otra tarjeta.', v_uid;
  end if;

  insert into public.cards
    (visible_id, state_code, fare_type, nombre, cedula, telefono, tarifa,
     status, account_id, chip_uid, asignada_at, asignada_por,
     enrolada_at, enrolada_por)
  values
    (v_serial, 0, 0, v_cuenta.nombres || ' ' || v_cuenta.apellidos, v_cuenta.cedula,
     v_cuenta.telefono, p_tarifa, 'ACTIVE', v_cuenta.id,
     nullif(v_uid, ''), now(), coalesce(v_op, 'propietario'),
     case when v_uid <> '' then now() end,
     case when v_uid <> '' then coalesce(v_op, 'propietario') end)
  returning * into v_tarjeta;

  insert into public.card_events (card_id, evento, canal, operador, detalle)
  values (v_tarjeta.id, 'ASIGNADA', 'sistema', v_op,
          jsonb_build_object('cuenta', v_cuenta.id, 'serie', 'ALFA'));

  if v_uid <> '' then
    insert into public.card_events (card_id, evento, canal, operador, detalle)
    values (v_tarjeta.id, 'ENROLADA', 'estacion', v_op,
            jsonb_build_object('uid', v_uid, 'serie', 'ALFA'));
  end if;

  return jsonb_build_object(
    'tarjeta', public.bt_tarjeta_json(v_tarjeta),
    'cuenta', jsonb_build_object(
      'id', v_cuenta.id,
      'titular', v_cuenta.nombres || ' ' || v_cuenta.apellidos,
      'cedula', v_cuenta.cedula
    )
  );
end;
$$;

revoke all on function public.bt_crear_tarjeta_alfa(text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.bt_crear_tarjeta_alfa(text, text, text, integer)
  to service_role;

comment on function public.bt_crear_tarjeta_alfa(text, text, text, integer)
  is 'Crea la tarjeta Alfa A-00000-000-H y la asigna a la cuenta indicada.';

drop function if exists public.bt_crear_tarjeta_maestra(text, text, text, numeric);

-- ------------------------------------------------------------
-- 6. Lotes 5+3 (máximo 999 unidades)
-- ------------------------------------------------------------
create or replace function public.bt_generar_lote(
  p_cantidad integer,
  p_patrocinante text default null,
  p_estado integer default 23,
  p_tarifa integer default 1,
  p_origen text default 'FABRICANTE',
  p_desde bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cantidad int := coalesce(p_cantidad, 0);
  v_estado   int := coalesce(p_estado, 23);
  v_tarifa   int := coalesce(p_tarifa, 1);
  v_origen   text := upper(trim(coalesce(p_origen, 'FABRICANTE')));
  v_lote     uuid;
  v_numero   int;
  v_inicio   int := coalesce(p_desde, 1)::int;
  v_letra    text;
  v_base     text;
  v_serial   text;
  v_tarjetas jsonb := '[]'::jsonb;
  i int;
begin
  if v_cantidad < 1 or v_cantidad > 999 then
    raise exception 'La cantidad del lote debe estar entre 1 y 999 tarjetas.';
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

  if v_inicio < 1 or v_inicio + v_cantidad - 1 > 999 then
    raise exception 'Las unidades del lote van de 001 a 999; revisa el inicio y la cantidad.';
  end if;

  select coalesce(max(batch_number), 0) + 1 into v_numero from public.card_batches;

  if v_numero > 99999 then
    raise exception 'Se agotaron los números de lote (5 dígitos).';
  end if;

  v_letra := case v_tarifa when 1 then 'G' else 'E' end;

  insert into public.card_batches
    (batch_number, sponsor_name, cards_quantity, state_code, fare_type, origen)
  values
    (v_numero, nullif(trim(coalesce(p_patrocinante, '')), ''), v_cantidad,
     v_estado, v_tarifa, v_origen)
  returning id into v_lote;

  for i in 0..(v_cantidad - 1) loop
    v_base := v_letra || lpad(v_numero::text, 5, '0')
              || lpad((v_inicio + i)::text, 3, '0');
    v_serial := substr(v_base, 1, 1) || '-' || substr(v_base, 2, 5) || '-'
                || substr(v_base, 7, 3) || '-' || public.bt_luhn_letra(v_base);

    insert into public.cards (visible_id, state_code, fare_type, batch_id, status)
    values (v_serial, v_estado, v_tarifa, v_lote, 'FABRICADA');

    v_tarjetas := v_tarjetas || jsonb_build_object(
      'serial', v_serial,
      'barcode', upper(replace(v_serial, '-', '')),
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
-- 7. Enrolado, emisión y asignación con la serie nueva
-- ------------------------------------------------------------
create or replace function public.bt_estacion_enrolar(
  p_lote uuid,
  p_items jsonb,
  p_operador text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  if jsonb_array_length(p_items) > 999 then
    raise exception 'bt:datos:Carga máximo 999 tarjetas por tanda (un lote completo).';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_serial := upper(trim(coalesce(v_item ->> 'serial', '')));
    v_uid    := public.bt_normalizar_mac(v_item ->> 'uid');

    begin
      if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NP-TV-Z]$'
         or not public.bt_luhn_valido(v_serial) then
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

create or replace function public.bt_emitir_tarjeta(
  p_serial text,
  p_nombre text,
  p_cedula text,
  p_telefono text default '',
  p_tarifa numeric default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tarjeta public.cards;
  v_serial  text := upper(trim(coalesce(p_serial, '')));
begin
  if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NP-TV-Z]$'
     or not public.bt_luhn_valido(v_serial) then
    raise exception 'El serial debe tener el formato G-00001-001-N con letra verificadora válida.';
  end if;

  if coalesce(p_tarifa, 0) <= 0 or p_tarifa <> trunc(p_tarifa) then
    raise exception 'La tarifa debe ser un monto entero mayor que 0.';
  end if;

  insert into public.cards (visible_id, nombre, cedula, telefono, tarifa, pin_hash)
  values (v_serial, coalesce(nullif(trim(p_nombre), ''), 'Titular'),
          nullif(trim(p_cedula), ''), public.bt_solo_digitos(p_telefono),
          p_tarifa::integer, null)
  returning * into v_tarjeta;

  return public.bt_tarjeta_json(v_tarjeta);
end;
$$;

create or replace function public.bt_vincular(p_token text, p_serial text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cuenta  public.accounts := public.bt_sesion_cuenta(p_token);
  v_serial  text := upper(trim(coalesce(p_serial, '')));
  v_tarjeta public.cards;
begin
  if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NP-TV-Z]$'
     or not public.bt_luhn_valido(v_serial) then
    raise exception 'bt:datos:El serial tiene el formato G-00001-001-N.';
  end if;

  select * into v_tarjeta from public.cards where visible_id = v_serial for update;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos ese serial. Revisa el número impreso.';
  end if;

  if v_tarjeta.chip_uid is null then
    raise exception 'bt:sin-enrolar:Esa tarjeta todavía no está enrolada. Pasa por taquilla antes de vincularla.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Esa tarjeta venció. Pasa por taquilla para renovarla.';
  end if;

  if v_tarjeta.status in ('BLOCKED', 'LOST', 'SCRAP') then
    raise exception 'bt:bloqueada:Esa tarjeta no está disponible. Comunícate con atención al cliente.';
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

create or replace function public.bt_activar(
  p_cedula text, p_serial text, p_telefono text, p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_serial  text := upper(trim(coalesce(p_serial, '')));
  v_tel     text := public.bt_solo_digitos(p_telefono);
  v_tarjeta public.cards;
  v_token   uuid;
begin
  if length(v_digitos) < 6 or length(v_digitos) > 8 then
    raise exception 'bt:sin-tarjeta:Revisa la cédula: debe tener entre 6 y 8 dígitos.';
  end if;

  if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NP-TV-Z]$'
     or not public.bt_luhn_valido(v_serial) then
    raise exception 'bt:sin-tarjeta:El serial no tiene el formato G-00001-001-N.';
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

  if v_tarjeta.chip_uid is null then
    raise exception 'bt:sin-enrolar:Esa tarjeta todavía no está enrolada. Pasa por taquilla antes de activarla.';
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

create or replace function public.bt_estacion_asignar(
  p_serial text,
  p_cedula text,
  p_operador text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
   where visible_id = upper(trim(coalesce(p_serial, '')))
     for update;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos ese serial.';
  end if;

  if v_tarjeta.chip_uid is null then
    raise exception 'bt:sin-enrolar:Esa tarjeta todavía no está enrolada. Pásala por la estación antes de asignarla.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Esa tarjeta venció.';
  end if;

  if v_tarjeta.status in ('BLOCKED', 'LOST', 'SCRAP') then
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
-- 8. Funciones de dinero con bolívares enteros
-- ------------------------------------------------------------
create or replace function public.bt_acreditar_recarga(
  p_visible_id text,
  p_monto numeric,
  p_referencia text,
  p_banco text default 'Pago Móvil',
  p_telefono text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tarjeta public.cards;
  v_monto   int := coalesce(p_monto, 0)::int;
  v_ref     text := trim(coalesce(p_referencia, ''));
  v_banco   text := trim(coalesce(p_banco, ''));
  v_saldo   int;
  v_mov     uuid;
  v_recarga uuid;
begin
  if p_monto is not null and p_monto <> trunc(p_monto) then
    raise exception 'Usa montos enteros en bolívares (sin céntimos).';
  end if;

  if v_monto <= 0 then
    raise exception 'El monto de la recarga debe ser mayor que 0.';
  end if;

  if v_ref = '' then
    raise exception 'Falta la referencia bancaria.';
  end if;

  select * into v_tarjeta from public.cards where visible_id = upper(trim(p_visible_id)) for update;

  if not found then
    raise exception 'No existe la tarjeta %.', upper(trim(p_visible_id));
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

  update public.cards set virtual_balance = v_saldo, updated_at = now()
   where id = v_tarjeta.id;

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

create or replace function public.bt_recargar(
  p_token text,
  p_serial text,
  p_monto numeric,
  p_telefono text,
  p_banco text,
  p_referencia text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cuenta     public.accounts := public.bt_sesion_cuenta(p_token);
  v_tarjeta    public.cards := public.bt_tarjeta_de_cuenta(v_cuenta, p_serial);
  v_tope       numeric := public.bt_tope_recarga();
  v_monto      int := coalesce(p_monto, 0)::int;
  v_tel        text := public.bt_solo_digitos(p_telefono);
  v_banco      text := trim(coalesce(p_banco, ''));
  v_ref_dig    text := public.bt_solo_digitos(p_referencia);
  v_ref        text;
  v_movimiento public.card_movements;
  v_reportes   int;
begin
  if p_monto is not null and p_monto <> trunc(p_monto) then
    raise exception 'bt:pin-invalido:Usa montos enteros en bolívares (sin céntimos).';
  end if;

  if v_monto <= 0 then
    raise exception 'bt:pin-invalido:Escribe el monto que transferiste (mayor que 0).';
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

create or replace function public.bt_cobrar_viaje(
  p_serial text,
  p_unidad text default null,
  p_monto numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tarjeta    public.cards;
  v_monto      int;
  v_saldo      int;
  v_movimiento public.card_movements;
begin
  select * into v_tarjeta
    from public.cards
   where visible_id = upper(trim(coalesce(p_serial, '')))
     for update;

  if not found then
    raise exception 'Tarjeta desconocida.';
  end if;

  if v_tarjeta.status <> 'ACTIVE' then
    raise exception 'Tarjeta bloqueada.';
  end if;

  if p_monto is null then
    v_monto := v_tarjeta.tarifa;
  else
    if p_monto <> trunc(p_monto) then
      raise exception 'Usa montos enteros en bolívares (sin céntimos).';
    end if;
    v_monto := p_monto::int;
  end if;

  if v_monto <= 0 then
    raise exception 'Monto inválido.';
  end if;

  if v_tarjeta.virtual_balance < v_monto then
    raise exception 'Saldo insuficiente.';
  end if;

  v_saldo := v_tarjeta.virtual_balance - v_monto;

  update public.cards set virtual_balance = v_saldo, updated_at = now()
   where id = v_tarjeta.id;

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

create or replace function public.bt_liquidar(
  p_vehicle uuid default null,
  p_desde timestamptz default null,
  p_hasta timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_desde  timestamptz := coalesce(p_desde, date_trunc('day', now()));
  v_hasta  timestamptz := coalesce(p_hasta, now());
  v_veh    public.vehicles;
  v_bruto  int;
  v_cant   int;
  v_comis  int;
  v_neto   int;
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

    v_comis := round(v_bruto * v_veh.commission_pct / 100)::int;
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

create or replace function public.bt_validador_sincronizar(
  p_validator_mac text,
  p_taps jsonb default '[]'::jsonb,
  p_recargas jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mac       text := public.bt_normalizar_mac(p_validator_mac);
  v_vehiculo  public.vehicles;
  v_tap       jsonb;
  v_recarga   jsonb;
  v_tarjeta   public.cards;
  v_offline   text;
  v_fare      int;
  v_saldo     int;
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
     where visible_id = upper(trim(coalesce(v_tap ->> 'visible_id', '')));

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

    v_fare := coalesce(
      nullif(v_tap ->> 'fare_charged', '')::numeric::int,
      v_fare,
      v_tarjeta.tarifa
    );

    v_saldo := coalesce(
      nullif(v_tap ->> 'chip_balance_after', '')::numeric::int,
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
           last_chip_balance = v_saldo,
           updated_at = now()
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
-- 9. Mermas de fábrica y resumen con SCRAP
-- ------------------------------------------------------------
create or replace function public.bt_admin_merma(
  p_token text,
  p_serial text,
  p_tipo text,
  p_motivo text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cuenta  public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_tipo    text := upper(trim(coalesce(p_tipo, '')));
  v_serial  text := upper(trim(coalesce(p_serial, '')));
  v_tarjeta public.cards;
begin
  if v_tipo not in ('RFPGC', 'CHIP_ERR') then
    raise exception 'bt:datos:El tipo de merma debe ser RFPGC o CHIP_ERR.';
  end if;

  select * into v_tarjeta
    from public.cards
   where visible_id = v_serial
     for update;

  if not found then
    raise exception 'bt:datos:No existe la tarjeta %.', v_serial;
  end if;

  if v_tarjeta.status = 'SCRAP' then
    raise exception 'bt:duplicada:Esa tarjeta ya está registrada como merma.';
  end if;

  if v_tarjeta.account_id is not null or v_tarjeta.status = 'ACTIVE' then
    raise exception 'bt:bloqueada:No se puede dar de baja una tarjeta ya vinculada.';
  end if;

  update public.cards
     set status = 'SCRAP', updated_at = now()
   where id = v_tarjeta.id;

  insert into public.card_events (card_id, evento, canal, operador, detalle)
  values (v_tarjeta.id, v_tipo, 'estacion', v_cuenta.cedula,
          jsonb_build_object('motivo', trim(coalesce(p_motivo, '')), 'lote', v_tarjeta.batch_id));

  return jsonb_build_object(
    'ok', true,
    'serial', v_tarjeta.visible_id,
    'tipo', v_tipo,
    'estado', 'SCRAP'
  );
end;
$$;

create or replace function public.bt_resumen_operativo()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
      'desechadas', (select count(*) from public.cards where status = 'SCRAP'),
      'asignadas', (select count(*) from public.cards where asignada_at is not null),
      'sinEnrolar', (select count(*) from public.cards where chip_uid is null),
      'saldoTotal', (select coalesce(sum(virtual_balance), 0) from public.cards)
    ),
    'mermas', jsonb_build_object(
      'total', (select count(*) from public.card_events
                 where evento in ('RFPGC', 'CHIP_ERR', 'SCRAP')),
      'fabricante', (select count(*) from public.card_events where evento = 'RFPGC'),
      'grabado', (select count(*) from public.card_events where evento = 'CHIP_ERR')
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
-- 10. Retiro del verificador numérico anterior
-- ------------------------------------------------------------
drop function if exists public.bt_luhn_digito(text);

-- ------------------------------------------------------------
-- 11. Permisos de las funciones nuevas
-- ------------------------------------------------------------
revoke all on function public.bt_admin_merma(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.bt_admin_merma(text, text, text, text) to anon;
