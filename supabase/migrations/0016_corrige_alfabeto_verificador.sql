-- 0016_corrige_alfabeto_verificador.sql
--
-- La clase [A-HJ-NP-TV-Z] de la migración 0014 excluía por error la U (el
-- alfabeto verificador es ABCDEFGHJKLMNPRSTUVWXYZ: solo deja fuera I, O y
-- Q), así que un serial con letra U —por ejemplo G-00007-005-U— era
-- rechazado por el CHECK y por las funciones. Esta migración reabre la U
-- sin tocar ninguna otra regla.

-- 1. El CHECK de la tabla y la validación de formato.
alter table public.cards drop constraint if exists cards_visible_id_check;

alter table public.cards
  add constraint cards_visible_id_check
  check (visible_id ~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NPR-Z]$'
         and public.bt_luhn_valido(visible_id));

-- 2.1 bt_luhn_valido
create or replace function public.bt_luhn_valido(p_serial text)
returns boolean
language plpgsql
immutable
as $$
declare
  v_compacto text := upper(regexp_replace(coalesce(p_serial, ''), '[^A-Z0-9]', '', 'g'));
begin
  if v_compacto !~ '^[AGE][0-9]{8}[A-HJ-NPR-Z]$' then
    return false;
  end if;

  return public.bt_luhn_letra(substr(v_compacto, 1, 9)) = substr(v_compacto, 10, 1);
end;
$$;



-- 2.2 bt_estacion_enrolar
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
      if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NPR-Z]$'
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



-- 2.3 bt_emitir_tarjeta
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
  if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NPR-Z]$'
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



-- 2.4 bt_vincular
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
  if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NPR-Z]$'
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



-- 2.5 bt_activar
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

  if v_serial !~ '^[AGE]-[0-9]{5}-[0-9]{3}-[A-HJ-NPR-Z]$'
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


