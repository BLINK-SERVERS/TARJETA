-- ============================================================
-- BLINK · lectura del back-office (lotes e inventario)
-- Ejecutar después de 0007_backoffice_mfa.sql.
--
-- Las funciones de 0006 solo devuelven el lote recién creado; el
-- operador necesita volver a ver los lotes anteriores y buscar una
-- tarjeta concreta antes de asignarla. Estas dos RPC son de solo
-- lectura, exigen sesión con segundo factor y se abren a `anon`
-- igual que el resto de la consola.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Lotes con su avance de enrolado y asignación
-- ------------------------------------------------------------
create or replace function public.bt_admin_lotes(p_token text, p_limite int default 20)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_limite int := least(greatest(coalesce(p_limite, 20), 1), 200);
begin
  return coalesce((
    select jsonb_agg(fila order by fila->>'creado' desc)
      from (
        select jsonb_build_object(
                 'id', b.id,
                 'numero', b.batch_number,
                 'patrocinante', b.sponsor_name,
                 'cantidad', b.cards_quantity,
                 'origen', b.origen,
                 'creado', b.created_at,
                 'enroladas', count(c.id) filter (where c.chip_uid is not null),
                 'asignadas', count(c.id) filter (where c.account_id is not null),
                 'fabricadas', count(c.id) filter (where c.status = 'FABRICADA')
               ) as fila
          from public.card_batches b
          left join public.cards c on c.batch_id = b.id
         group by b.id
         order by b.created_at desc
         limit v_limite
      ) t
  ), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------
-- 2. Inventario de tarjetas con filtros
-- ------------------------------------------------------------
create or replace function public.bt_admin_tarjetas(
  p_token text,
  p_lote uuid default null,
  p_buscar text default '',
  p_estado text default null,
  p_limite int default 200
)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_buscar text := lower(trim(coalesce(p_buscar, '')));
  v_limite int := least(greatest(coalesce(p_limite, 200), 1), 1000);
  v_total bigint;
  v_filas jsonb;
begin
  select count(*) into v_total
    from public.cards c
   where (p_lote is null or c.batch_id = p_lote)
     and (p_estado is null or c.status = p_estado)
     and (
       v_buscar = ''
       or lower(c.visible_id) like '%' || v_buscar || '%'
       or lower(coalesce(c.chip_uid, '')) like '%' || v_buscar || '%'
       or lower(coalesce(c.nombre, '')) like '%' || v_buscar || '%'
       or lower(coalesce(c.cedula, '')) like '%' || v_buscar || '%'
     );

  select coalesce(jsonb_agg(fila order by fila->>'serial'), '[]'::jsonb)
    into v_filas
    from (
      select jsonb_build_object(
               'serial', c.visible_id,
               'uid', coalesce(c.chip_uid, ''),
               'estado', c.status,
               'enrolada', c.enrolada_at,
               'asignada', c.asignada_at,
               'titular', case
                            when c.account_id is null then null
                            else nullif(trim(coalesce(c.nombre, '')), '')
                          end,
               'cedula', case
                           when c.account_id is null then null
                           else nullif(trim(coalesce(c.cedula, '')), '')
                         end,
               'lote', c.batch_id,
               'saldo', c.virtual_balance
             ) as fila
        from public.cards c
       where (p_lote is null or c.batch_id = p_lote)
         and (p_estado is null or c.status = p_estado)
         and (
           v_buscar = ''
           or lower(c.visible_id) like '%' || v_buscar || '%'
           or lower(coalesce(c.chip_uid, '')) like '%' || v_buscar || '%'
           or lower(coalesce(c.nombre, '')) like '%' || v_buscar || '%'
           or lower(coalesce(c.cedula, '')) like '%' || v_buscar || '%'
         )
       order by c.visible_id
       limit v_limite
    ) t;

  return jsonb_build_object('total', v_total, 'tarjetas', v_filas,
                            'creadoPor', v_cuenta.nombres || ' ' || v_cuenta.apellidos);
end;
$$;

-- ------------------------------------------------------------
-- 3. Permisos
-- ------------------------------------------------------------
revoke all on function public.bt_admin_lotes(text, int) from public, anon, authenticated;
revoke all on function public.bt_admin_tarjetas(text, uuid, text, text, int)
  from public, anon, authenticated;

grant execute on function public.bt_admin_lotes(text, int) to anon;
grant execute on function public.bt_admin_tarjetas(text, uuid, text, text, int) to anon;
