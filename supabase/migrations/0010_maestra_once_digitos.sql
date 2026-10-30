-- ============================================================
-- 0010 — La tarjeta maestra pasa a la serie de 11 dígitos
--
-- BLINK-DOC-12 v2.0.0 fija el serial maestro en `00-0-0000000-0`:
-- entidad 00, tarifa 0 y secuencial 0000000 (7 dígitos), igual
-- que la serie comercial. La fila creada por 0009 se renombra
-- conservando su historial; los plásticos ya impresos con el
-- serial de 10 dígitos siguen siendo válidos por formato y Luhn.
-- ============================================================

-- ------------------------------------------------------------
-- 1. La función crea el serial nuevo
-- ------------------------------------------------------------
create or replace function public.bt_crear_tarjeta_maestra(
  p_cedula text,
  p_uid text default null,
  p_operador text default '',
  p_tarifa numeric default 15
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_serial  text := '00-0-0000000-0';
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

  select * into v_cuenta from public.accounts where cedula_digitos = v_digitos;

  if not found then
    raise exception 'bt:sin-cuenta:No hay una cuenta registrada con esa cédula.';
  end if;

  if exists (select 1 from public.cards where visible_id = v_serial) then
    raise exception 'bt:duplicada:La tarjeta maestra % ya existe.', v_serial;
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
     case when v_uid <> '' then now() end, case when v_uid <> '' then coalesce(v_op, 'propietario') end)
  returning * into v_tarjeta;

  insert into public.card_events (card_id, evento, canal, operador, detalle)
  values (v_tarjeta.id, 'ASIGNADA', 'sistema', v_op,
          jsonb_build_object('cuenta', v_cuenta.id, 'serie', 'MAESTRA'));

  if v_uid <> '' then
    insert into public.card_events (card_id, evento, canal, operador, detalle)
    values (v_tarjeta.id, 'ENROLADA', 'estacion', v_op,
            jsonb_build_object('uid', v_uid, 'serie', 'MAESTRA'));
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

revoke all on function public.bt_crear_tarjeta_maestra(text, text, text, numeric)
  from public, anon, authenticated;
grant execute on function public.bt_crear_tarjeta_maestra(text, text, text, numeric)
  to service_role;

-- ------------------------------------------------------------
-- 2. Renombrar la fila existente (idempotente)
-- ------------------------------------------------------------
do $$
declare
  v_viejo text := '00-0-000000-0';
  v_nuevo text := '00-0-0000000-0';
begin
  if exists (select 1 from public.cards where visible_id = v_nuevo)
     and exists (select 1 from public.cards where visible_id = v_viejo) then
    raise exception 'Existen las dos versiones de la maestra (% y %)', v_viejo, v_nuevo;
  end if;

  update public.cards
     set visible_id = v_nuevo
   where visible_id = v_viejo;

  if found then
    insert into public.card_events (card_id, evento, canal, operador, detalle)
    select id, 'ASIGNADA', 'sistema', 'migracion-0010',
           jsonb_build_object('de', v_viejo, 'a', v_nuevo)
      from public.cards
     where visible_id = v_nuevo;
  end if;
end;
$$;

comment on function public.bt_crear_tarjeta_maestra(text, text, text, numeric)
  is 'Crea la tarjeta maestra 00-0-0000000-0 (entidad 00, tarifa 0) y la asigna a la cuenta indicada.';
