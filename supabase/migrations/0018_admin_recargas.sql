-- ============================================================
-- BLINK · bandeja de recargas del back-office
-- Ejecutar después de 0017_contador_de_chip.sql.
--
-- Hasta hoy la revisión del Pago Móvil se hacía en el SQL Editor de
-- Supabase con `bt_recargas_pendientes` y `bt_aprobar_recarga`, que
-- están cerradas a `anon`. Estas dos RPC envuelven ese flujo con la
-- sesión del operador y el segundo factor ya activo, igual que el
-- resto de la consola (0007/0008), para que la bandeja viva en el
-- back-office.
--
-- No cambia datos ni toca las funciones existentes: solo agrega dos
-- envoltorios SECURITY DEFINER y sus permisos.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Bandeja de recargas pendientes
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
  v_filas jsonb;
begin
  select count(*), coalesce(sum(r.amount), 0)
    into v_total, v_monto
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
    'recargas', v_filas,
    'operador', trim(v_cuenta.nombres || ' ' || v_cuenta.apellidos)
  );
end;
$$;

-- ------------------------------------------------------------
-- 2. Aprobar o rechazar una recarga
-- ------------------------------------------------------------
create or replace function public.bt_admin_resolver_recarga(
  p_token text,
  p_recarga uuid,
  p_aprobar boolean,
  p_motivo text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_operador text;
  v_estado text;
  v_resultado jsonb;
begin
  v_operador := coalesce(
    nullif(trim(v_cuenta.nombres || ' ' || v_cuenta.apellidos), ''),
    v_cuenta.cedula
  );

  select r.status into v_estado
    from public.recharges r
   where r.id = p_recarga
     for update;

  if not found then
    raise exception 'bt:datos:La recarga no existe.';
  end if;

  if v_estado <> 'pendiente' then
    raise exception 'bt:datos:Esa recarga ya fue resuelta (estado: %).', v_estado;
  end if;

  if not coalesce(p_aprobar, false)
     and nullif(trim(coalesce(p_motivo, '')), '') is null then
    raise exception 'bt:datos:Escribe el motivo del rechazo.';
  end if;

  begin
    if coalesce(p_aprobar, false) then
      v_resultado := public.bt_aprobar_recarga(p_recarga, v_operador);
    else
      v_resultado := public.bt_rechazar_recarga(p_recarga, v_operador, trim(p_motivo));
    end if;
  exception
    when sqlstate 'P0001' then
      -- La función interna también valida el estado (carrera entre dos
      -- operadores); se devuelve como error de datos legible.
      raise exception 'bt:datos:%', sqlerrm;
  end;

  return v_resultado || jsonb_build_object(
    'recarga', p_recarga,
    'aprobada', coalesce(p_aprobar, false),
    'operador', v_operador
  );
end;
$$;

-- ------------------------------------------------------------
-- 3. Permisos
-- ------------------------------------------------------------
revoke all on function public.bt_admin_recargas(text, int)
  from public, anon, authenticated;
revoke all on function public.bt_admin_resolver_recarga(text, uuid, boolean, text)
  from public, anon, authenticated;

grant execute on function public.bt_admin_recargas(text, int) to anon;
grant execute on function public.bt_admin_resolver_recarga(text, uuid, boolean, text) to anon;
