-- ============================================================
-- BLINK · el portal tampoco activa plásticos sin chip
-- Ejecutar después de 0012_asignar_exige_enrolada.sql.
--
-- 0012 cerró la taquilla; quedaban abiertas las dos vías del portal
-- del pasajero (bt_vincular y la heredada bt_activar). Ambas marcaban
-- ACTIVE una tarjeta con chip_uid nulo, que el validador no puede leer.
-- Ahora responden bt:sin-enrolar y remiten a taquilla.
-- ============================================================

create or replace function public.bt_vincular(p_token text, p_serial text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta  public.accounts := public.bt_sesion_cuenta(p_token);
  v_serial  text := trim(coalesce(p_serial, ''));
  v_tarjeta public.cards;
begin
  if v_serial !~ '^\d{2}-\d-\d{6,7}-\d$' or not public.bt_luhn_valido(v_serial) then
    raise exception 'bt:datos:El serial tiene 10 u 11 dígitos (ej. 23-1-0000001-9).';
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
