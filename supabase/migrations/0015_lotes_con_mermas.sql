-- ============================================================
-- BLINK · lectura de lotes con mermas
-- Ejecutar después de 0014_serie_cinco_mas_tres.sql.
--
-- La estación calculaba las tarjetas pendientes como
-- cantidad - enroladas, pero desde que existe SCRAP una tarjeta
-- desechada nunca se enrola y ese número queda inflado para
-- siempre. El lote entrega ahora el conteo exacto.
-- ============================================================

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
                 'fabricadas', count(c.id) filter (where c.status = 'FABRICADA'),
                 'desechadas', count(c.id) filter (where c.status = 'SCRAP'),
                 'sinEnrolar', count(c.id) filter (
                   where c.status = 'FABRICADA' and c.chip_uid is null
                 )
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

revoke all on function public.bt_admin_lotes(text, int) from public, anon, authenticated;
grant execute on function public.bt_admin_lotes(text, int) to anon;
