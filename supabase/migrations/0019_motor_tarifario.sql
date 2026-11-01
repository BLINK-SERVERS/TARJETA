-- ============================================================
-- BLINK · motor tarifario y recarga por pasajes
-- Ejecutar después de 0018_admin_recargas.sql.
--
-- El pasajero deja de escribir bolívares: compra una cantidad
-- entera de pasajes. El monto que transfiere cubre el valor neto
-- que recibe el chofer, la comisión bancaria de entrada, la
-- provisión para la comisión de salida y el margen de la
-- plataforma, con redondeo a la decena superior:
--
--   total = ceil( N × base × (1 + salida + margen) / (1 - entrada) / 10 ) × 10
--
-- `recharges.amount` sigue siendo el monto bruto que se concilia
-- contra el banco; `monto_base` es lo que realmente se acredita al
-- saldo de la tarjeta. La aprobación acredita `monto_base` y las
-- recargas anteriores (sin desglose) conservan su comportamiento.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Desglose contable de cada recarga
-- ------------------------------------------------------------
alter table public.recharges
  add column if not exists pasajes int,
  add column if not exists tarifa_base numeric(12,2),
  add column if not exists monto_base numeric(12,2),
  add column if not exists comision_entrada numeric(12,2),
  add column if not exists provision_salida numeric(12,2),
  add column if not exists margen_blink numeric(12,2),
  add column if not exists excedente_redondeo numeric(12,2),
  add column if not exists tarifario jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'recharges_pasajes_check'
  ) then
    alter table public.recharges
      add constraint recharges_pasajes_check check (pasajes is null or pasajes > 0);
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'recharges_base_check'
  ) then
    alter table public.recharges
      add constraint recharges_base_check check (monto_base is null or monto_base > 0);
  end if;
end;
$$;

comment on column public.recharges.amount is
  'Monto bruto transferido por Pago Móvil (se concilia contra el banco).';
comment on column public.recharges.monto_base is
  'Bs acreditados al saldo de la tarjeta (N × tarifa_base). NULL en recargas anteriores a 0019.';
comment on column public.recharges.tarifario is
  'Copia de los parámetros usados al cotizar, para auditoría.';

-- ------------------------------------------------------------
-- 2. Parámetros publicados del motor
-- ------------------------------------------------------------
create or replace function public.bt_tarifario()
returns jsonb
language sql stable security definer set search_path = public as $$
  with p as (
    select coalesce(valor -> 'tarifario', '{}'::jsonb) as t
      from public.settings where clave = 'publico'
  )
  select jsonb_build_object(
    'base', coalesce((t ->> 'base')::numeric, 500),
    'comisionEntrada', coalesce((t ->> 'comisionEntrada')::numeric, 0.015),
    'comisionSalida', coalesce((t ->> 'comisionSalida')::numeric, 0.003),
    'margen', coalesce((t ->> 'margen')::numeric, 0.04),
    'redondeo', coalesce((t ->> 'redondeo')::numeric, 10)
  )
  from p;
$$;

-- Publica el tarifario por defecto y sube el tope a 20.000 Bs para que
-- quepan los bloques de 10 y 20 pasajes de la especificación. No baja un
-- tope mayor que ya haya configurado el propietario.
update public.settings
   set valor = jsonb_set(
         valor || jsonb_build_object(
           'tarifario',
           jsonb_build_object(
             'base', 500,
             'comisionEntrada', 0.015,
             'comisionSalida', 0.003,
             'margen', 0.04,
             'redondeo', 10
           )
         ),
         '{topeRecarga}',
         to_jsonb(greatest(coalesce((valor ->> 'topeRecarga')::numeric, 20000), 20000)),
         true
       ),
       actualizada = now()
 where clave = 'publico';

-- ------------------------------------------------------------
-- 3. Cotizador (solo servidor)
-- ------------------------------------------------------------
create or replace function public.bt_cotizar_recarga(
  p_pasajes int,
  p_base numeric default null
)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tarifario  jsonb := public.bt_tarifario();
  v_base       numeric := coalesce(p_base, (v_tarifario ->> 'base')::numeric);
  v_ce         numeric := (v_tarifario ->> 'comisionEntrada')::numeric;
  v_cs         numeric := (v_tarifario ->> 'comisionSalida')::numeric;
  v_mg         numeric := (v_tarifario ->> 'margen')::numeric;
  v_redondeo   numeric := (v_tarifario ->> 'redondeo')::numeric;
  v_acreditado numeric;
  v_bruto      numeric;
  v_total      numeric;
  v_entrada    numeric;
  v_salida     numeric;
  v_margen     numeric;
begin
  if p_pasajes is null or p_pasajes < 1 then
    raise exception 'bt:datos:La cantidad de pasajes debe ser un entero mayor que cero.';
  end if;

  if v_base <= 0 or v_redondeo <= 0 or v_ce < 0 or v_ce >= 1
     or v_cs < 0 or v_mg < 0 then
    raise exception 'bt:datos:Los parámetros tarifarios no son válidos.';
  end if;

  v_acreditado := round(p_pasajes * v_base, 2);
  v_bruto      := v_acreditado * (1 + v_cs + v_mg) / (1 - v_ce);
  -- Múltiplo inmediato superior; el epsilon evita subir de década por un
  -- residuo de representación cuando el bruto ya es exacto.
  v_total      := ceil(v_bruto / v_redondeo - 1e-9) * v_redondeo;

  v_entrada := round(v_total * v_ce, 2);
  v_salida  := round(v_acreditado * v_cs, 2);
  v_margen  := round(v_acreditado * v_mg, 2);

  return jsonb_build_object(
    'pasajes', p_pasajes,
    'tarifaBase', v_base,
    'acreditado', v_acreditado,
    'bruto', round(v_bruto, 2),
    'total', v_total,
    'comisionEntrada', v_entrada,
    'provisionSalida', v_salida,
    'margen', v_margen,
    'excedente', round(v_total - v_bruto, 2),
    'utilidad', round(v_total - v_acreditado - v_entrada - v_salida, 2)
  );
end;
$$;

-- ------------------------------------------------------------
-- 4. Reportar una recarga por pasajes
-- ------------------------------------------------------------
create or replace function public.bt_recargar_pasajes(
  p_token text,
  p_serial text,
  p_pasajes int,
  p_telefono text,
  p_banco text,
  p_referencia text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta     public.accounts := public.bt_sesion_cuenta(p_token);
  v_tarjeta    public.cards := public.bt_tarjeta_de_cuenta(v_cuenta, p_serial);
  v_tope       numeric := public.bt_tope_recarga();
  v_pasajes    int := coalesce(p_pasajes, 0);
  v_base       numeric;
  v_cotizacion jsonb;
  v_total      numeric;
  v_acreditado numeric;
  v_tel        text := public.bt_solo_digitos(p_telefono);
  v_banco      text := trim(coalesce(p_banco, ''));
  v_ref_dig    text := public.bt_solo_digitos(p_referencia);
  v_ref        text;
  v_movimiento public.card_movements;
  v_reportes   int;
begin
  if v_pasajes < 1 then
    raise exception 'bt:pin-invalido:Elige cuántos pasajes quieres recargar.';
  end if;

  -- La tarifa del plástico manda: una tarjeta de estudiante compra
  -- pasajes a su propia tarifa, con las mismas comisiones y margen.
  v_base := coalesce(nullif(v_tarjeta.tarifa, 0), (public.bt_tarifario() ->> 'base')::numeric);
  v_cotizacion := public.bt_cotizar_recarga(v_pasajes, v_base);
  v_total      := (v_cotizacion ->> 'total')::numeric;
  v_acreditado := (v_cotizacion ->> 'acreditado')::numeric;

  if v_total > v_tope then
    raise exception 'bt:pin-invalido:El tope por recarga es % Bs. Compra menos pasajes o divide el pago.',
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
    (v_tarjeta.id, 'recarga', v_acreditado, v_tarjeta.virtual_balance,
     format('Recarga de %s %s en revisión', v_pasajes,
            case when v_pasajes = 1 then 'pasaje' else 'pasajes' end),
     'pendiente', v_banco, v_ref)
  returning * into v_movimiento;

  insert into public.recharges
    (card_id, movement_id, amount, sender_phone, bank, bank_reference, created_at,
     pasajes, tarifa_base, monto_base, comision_entrada, provision_salida,
     margen_blink, excedente_redondeo, tarifario)
  values
    (v_tarjeta.id, v_movimiento.id, v_total, v_tel, v_banco, v_ref, v_movimiento.at,
     v_pasajes, v_base, v_acreditado,
     (v_cotizacion ->> 'comisionEntrada')::numeric,
     (v_cotizacion ->> 'provisionSalida')::numeric,
     (v_cotizacion ->> 'margen')::numeric,
     (v_cotizacion ->> 'excedente')::numeric,
     public.bt_tarifario());

  return jsonb_build_object(
    'movimiento', public.bt_movimiento_json(v_movimiento, v_tarjeta.visible_id),
    'cotizacion', v_cotizacion
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. La aprobación acredita el monto base, no el bruto
-- ------------------------------------------------------------
create or replace function public.bt_aprobar_recarga(p_recarga uuid, p_admin text default 'admin')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_recarga  public.recharges;
  v_credito  numeric;
  v_saldo    numeric;
begin
  select * into v_recarga from public.recharges where id = p_recarga for update;

  if not found then
    raise exception 'Recarga no encontrada.';
  end if;

  if v_recarga.status <> 'pendiente' then
    raise exception 'Esa recarga ya fue %.', v_recarga.status;
  end if;

  -- Recargas anteriores a 0019 no tienen monto_base: se acredita el bruto.
  v_credito := coalesce(v_recarga.monto_base, v_recarga.amount);

  update public.cards
     set virtual_balance = virtual_balance + v_credito
   where id = v_recarga.card_id
  returning virtual_balance into v_saldo;

  update public.card_movements
     set estado = 'aprobado',
         monto = v_credito,
         saldo_despues = v_saldo,
         detalle = case
                     when v_recarga.pasajes is null then 'Pago Móvil aprobado'
                     else format('Pago Móvil aprobado · %s %s', v_recarga.pasajes,
                                 case when v_recarga.pasajes = 1 then 'pasaje' else 'pasajes' end)
                   end
   where id = v_recarga.movement_id;

  update public.recharges
     set status = 'aprobado', resolved_at = now(), resolved_by = p_admin
   where id = v_recarga.id;

  return jsonb_build_object(
    'ok', true,
    'saldo', v_saldo,
    'acreditado', v_credito,
    'pasajes', v_recarga.pasajes
  );
end;
$$;

-- ------------------------------------------------------------
-- 6. Bandeja con el desglose de pasajes
-- ------------------------------------------------------------
create or replace function public.bt_admin_recargas(
  p_token text,
  p_limite int default 100
)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_limite int := least(greatest(coalesce(p_limite, 100), 1), 200);
  v_total bigint;
  v_monto numeric;
  v_base numeric;
  v_pasajes bigint;
  v_filas jsonb;
begin
  select count(*),
         coalesce(sum(r.amount), 0),
         coalesce(sum(coalesce(r.monto_base, r.amount)), 0),
         coalesce(sum(r.pasajes), 0)
    into v_total, v_monto, v_base, v_pasajes
    from public.recharges r
   where r.status = 'pendiente';

  select coalesce(
           jsonb_agg(fila order by fila ->> 'reportada' asc, fila ->> 'recarga' asc),
           '[]'::jsonb
         )
    into v_filas
    from (
      select jsonb_build_object(
               'recarga', r.id,
               'movimiento', r.movement_id,
               'serial', c.visible_id,
               'titular', coalesce(nullif(trim(c.nombre), ''), 'Sin titular'),
               'cedula', coalesce(c.cedula, ''),
               'monto', r.amount,
               'montoBase', coalesce(r.monto_base, r.amount),
               'pasajes', r.pasajes,
               'tarifaBase', r.tarifa_base,
               'telefono', r.sender_phone,
               'banco', r.bank,
               'referencia', r.bank_reference,
               'estado', r.status,
               'reportada', r.created_at,
               'saldo', c.virtual_balance
             ) as fila
        from public.recharges r
        join public.cards c on c.id = r.card_id
       where r.status = 'pendiente'
       order by r.created_at asc
       limit v_limite
    ) pendientes;

  return jsonb_build_object(
    'total', v_total,
    'monto', v_monto,
    'base', v_base,
    'pasajes', v_pasajes,
    'recargas', v_filas,
    'operador', trim(v_cuenta.nombres || ' ' || v_cuenta.apellidos)
  );
end;
$$;

-- ------------------------------------------------------------
-- 7. Permisos
-- ------------------------------------------------------------
revoke all on function public.bt_tarifario() from public, anon, authenticated;
revoke all on function public.bt_cotizar_recarga(int, numeric) from public, anon, authenticated;
revoke all on function public.bt_recargar_pasajes(text, text, int, text, text, text)
  from public, anon, authenticated;

grant execute on function public.bt_recargar_pasajes(text, text, int, text, text, text) to anon;

-- La bandeja se redefine aquí; se reafirman sus permisos.
revoke all on function public.bt_admin_recargas(text, int) from public, anon, authenticated;
grant execute on function public.bt_admin_recargas(text, int) to anon;

-- `bt_recargar` (monto libre) queda como compatibilidad temporal para
-- clientes con la versión anterior en caché. Se retirará cuando el
-- parque haya actualizado (BLINK-DOC-19, B-27).
