-- ============================================================
-- BLINK · serie de identificación de 7 dígitos y tarjeta maestra
-- Ejecutar después de 0008_backoffice_rbac.sql.
--
-- Cambios:
--   1. El ID BLINK admite 6 o 7 dígitos secuenciales:
--        23-1-000001-9   (serie heredada, 10 dígitos)
--        23-1-0000001-9  (serie nueva, 11 dígitos)
--      El verificador de Luhn pasa a calcularse de derecha a
--      izquierda, así que sirve para ambas longitudes.
--   2. La tarifa 0 queda reservada para la tarjeta maestra del
--      propietario, identificada con la serie 00 (emisor):
--        00-0-000000-0
--      No pertenece a ningún lote y no la produce bt_generar_lote.
--   3. bt_generar_lote numera con 7 dígitos y acepta un inicio
--      explícito (p_desde) para reanudar una serie impresa.
--   4. El lote de arranque de 20 tarjetas se renumera a la serie
--      de 7 dígitos (estaban sin enrolar y sin asignar).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Luhn genérico (10 y 11 dígitos)
-- ------------------------------------------------------------
create or replace function public.bt_luhn_digito(p_base text)
returns text language plpgsql immutable as $$
declare
  v_digitos text := regexp_replace(coalesce(p_base, ''), '\D', '', 'g');
  v_largo int := length(v_digitos);
  v_suma int := 0;
  v_n int;
  i int;
begin
  if v_largo < 1 then
    raise exception 'La base del ID BLINK no puede estar vacía.';
  end if;

  -- Se duplican las posiciones pares contando desde la derecha del
  -- número completo, es decir, las impares de la base.
  for i in 1..v_largo loop
    v_n := substr(v_digitos, i, 1)::int;
    if (v_largo - i) % 2 = 0 then
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

create or replace function public.bt_luhn_valido(p_serial text)
returns boolean language plpgsql immutable as $$
declare
  v_digitos text := regexp_replace(coalesce(p_serial, ''), '\D', '', 'g');
  v_largo int := length(v_digitos);
  v_suma int := 0;
  v_n int;
  i int;
begin
  if v_largo < 2 then
    return false;
  end if;

  for i in 1..v_largo loop
    v_n := substr(v_digitos, i, 1)::int;
    if (v_largo - i) % 2 = 1 then
      v_n := v_n * 2;
      if v_n > 9 then
        v_n := v_n - 9;
      end if;
    end if;
    v_suma := v_suma + v_n;
  end loop;

  return v_suma % 10 = 0;
end;
$$;

revoke all on function public.bt_luhn_digito(text) from public, anon, authenticated;
revoke all on function public.bt_luhn_valido(text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. Formato del serial y tarifa 0
-- ------------------------------------------------------------
alter table public.cards drop constraint if exists cards_visible_id_check;
alter table public.cards
  add constraint cards_visible_id_check
  check (visible_id ~ '^\d{2}-\d-\d{6,7}-\d$' and public.bt_luhn_valido(visible_id));

alter table public.cards drop constraint if exists cards_fare_type_check;
alter table public.cards
  add constraint cards_fare_type_check check (fare_type in (0, 1, 2));

comment on column public.cards.fare_type is
  '0 = tarjeta maestra del propietario (serie 00), 1 = general, 2 = estudiante / tercera edad.';

-- ------------------------------------------------------------
-- 3. Generación de lotes en la serie de 7 dígitos
-- ------------------------------------------------------------
drop function if exists public.bt_generar_lote(int, text, int, int, text);

create or replace function public.bt_generar_lote(
  p_cantidad int,
  p_patrocinante text default null,
  p_estado int default 23,
  p_tarifa int default 1,
  p_origen text default 'FABRICANTE',
  p_desde bigint default null
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
  v_desde    bigint;
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

  if p_desde is null then
    select coalesce(max(split_part(visible_id, '-', 3)::bigint), 0) + 1
      into v_desde
      from public.cards
     where state_code = v_estado
       and fare_type = v_tarifa;
  else
    v_desde := p_desde;
  end if;

  if v_desde < 1 then
    raise exception 'El secuencial inicial debe ser 1 o mayor.';
  end if;

  if v_desde + v_cantidad - 1 > 9999999 then
    raise exception 'El secuencial del estado % y tarifa % se agotó.', v_estado, v_tarifa;
  end if;

  if exists (
    select 1 from public.cards
     where state_code = v_estado
       and fare_type = v_tarifa
       and split_part(visible_id, '-', 3)::bigint between v_desde and v_desde + v_cantidad - 1
  ) then
    raise exception 'La serie %-% ya tiene tarjetas entre % y %. Elige otro inicio.',
      lpad(v_estado::text, 2, '0'), v_tarifa, v_desde, v_desde + v_cantidad - 1;
  end if;

  insert into public.card_batches
    (batch_number, sponsor_name, cards_quantity, state_code, fare_type, origen)
  values
    (v_numero, nullif(trim(coalesce(p_patrocinante, '')), ''), v_cantidad, v_estado, v_tarifa, v_origen)
  returning id into v_lote;

  for i in 0..(v_cantidad - 1) loop
    v_base := lpad(v_estado::text, 2, '0') || v_tarifa::text
              || lpad((v_desde + i)::text, 7, '0');
    v_serial := substr(v_base, 1, 2) || '-' || substr(v_base, 3, 1) || '-'
                || substr(v_base, 4, 7) || '-' || public.bt_luhn_digito(v_base);

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

revoke all on function public.bt_generar_lote(int, text, int, int, text, bigint)
  from public, anon, authenticated;
grant execute on function public.bt_generar_lote(int, text, int, int, text, bigint)
  to service_role;

-- ------------------------------------------------------------
-- 4. Seriales de 10 u 11 dígitos en las RPC existentes
-- ------------------------------------------------------------
create or replace function public.bt_emitir_tarjeta(
  p_serial text, p_nombre text, p_cedula text,
  p_telefono text default '', p_tarifa numeric default 15
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.cards;
begin
  if coalesce(trim(p_serial), '') !~ '^\d{2}-\d-\d{6,7}-\d$'
     or not public.bt_luhn_valido(trim(p_serial)) then
    raise exception 'El serial debe tener 10 u 11 dígitos y Luhn válido (ej. 23-1-0000001-9).';
  end if;

  insert into public.cards (visible_id, nombre, cedula, telefono, tarifa, pin_hash)
  values (trim(p_serial), coalesce(nullif(trim(p_nombre), ''), 'Titular'),
          nullif(trim(p_cedula), ''), public.bt_solo_digitos(p_telefono), p_tarifa, null)
  returning * into v_tarjeta;

  return public.bt_tarjeta_json(v_tarjeta);
end;
$$;

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
      if v_serial !~ '^\d{2}-\d-\d{6,7}-\d$' or not public.bt_luhn_valido(v_serial) then
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

revoke all on function public.bt_estacion_enrolar(uuid, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.bt_estacion_enrolar(uuid, jsonb, text)
  to service_role;

-- ------------------------------------------------------------
-- 5. Tarjeta maestra del propietario (00-0-000000-0)
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
  v_serial  text := '00-0-000000-0';
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
  values (v_tarjeta.id, 'ASIGNADA', 'taquilla', v_op,
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
-- 6. Renumeración del lote de arranque a la serie de 7 dígitos
--    Solo toca tarjetas FABRICADA, sin UID, sin cuenta y sin
--    movimientos. Es idempotente: al quedar con 7 dígitos dejan
--    de coincidir con el patrón de la serie heredada.
-- ------------------------------------------------------------
do $$
declare
  v_tarjeta record;
  v_base    text;
  v_nuevo   text;
begin
  for v_tarjeta in
    select id, visible_id
      from public.cards
     where visible_id ~ '^\d{2}-\d-\d{6}-\d$'
       and status = 'FABRICADA'
       and chip_uid is null
       and account_id is null
       and not exists (select 1 from public.card_movements m where m.card_id = cards.id)
     order by visible_id
  loop
    v_base := substr(v_tarjeta.visible_id, 1, 2)
              || substr(v_tarjeta.visible_id, 4, 1)
              || lpad(split_part(v_tarjeta.visible_id, '-', 3), 7, '0');
    v_nuevo := substr(v_base, 1, 2) || '-' || substr(v_base, 3, 1) || '-'
               || substr(v_base, 4, 7) || '-' || public.bt_luhn_digito(v_base);

    if not exists (select 1 from public.cards where visible_id = v_nuevo) then
      update public.cards set visible_id = v_nuevo where id = v_tarjeta.id;
    end if;
  end loop;
end;
$$;

-- ------------------------------------------------------------
-- 7. Verificación rápida
-- ------------------------------------------------------------
do $$
declare
  v_heredadas int;
  v_siete     int;
begin
  select count(*) into v_heredadas from public.cards where visible_id ~ '^\d{2}-\d-\d{6}-\d$';
  select count(*) into v_siete     from public.cards where visible_id ~ '^\d{2}-\d-\d{7}-\d$';
  raise notice 'Serie heredada (10 dígitos): % · serie nueva (11 dígitos): %',
    v_heredadas, v_siete;
end;
$$;
