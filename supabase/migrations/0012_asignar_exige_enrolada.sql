-- ============================================================
-- BLINK · la taquilla no puede activar un plástico sin chip
-- Ejecutar después de 0011_estacion_secuencial.sql.
--
-- bt_estacion_asignar marcaba ACTIVE aunque la tarjeta todavía no
-- tuviera chip_uid: el validador no podía leerla y el pasajero se
-- quedaba con un plástico inerte. Ahora exige que la estación haya
-- grabado y enrolado el chip antes de vincularla a una cuenta.
-- ============================================================

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

  if v_tarjeta.chip_uid is null then
    raise exception 'bt:sin-enrolar:Esa tarjeta todavía no está enrolada. Pásala por la estación antes de asignarla.';
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
