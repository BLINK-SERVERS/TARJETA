-- ============================================================
-- BLINK · estación de enrolado secuencial
-- Ejecutar después de 0010_maestra_once_digitos.sql.
--
-- La consola ya no teclea serial ni UID: el lector entrega el UID y la
-- estación pide aquí el siguiente serial sin grabar del lote. Así una
-- tanda se enrola en orden, tarjeta por tarjeta.
-- ============================================================

create or replace function public.bt_admin_siguiente(
  p_token text,
  p_lote uuid default null
)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_tarjeta public.cards;
begin
  select * into v_tarjeta
    from public.cards
   where status = 'FABRICADA'
     and chip_uid is null
     and (p_lote is null or batch_id = p_lote)
   order by visible_id
   limit 1;

  if not found then
    return jsonb_build_object('fin', true);
  end if;

  return jsonb_build_object(
    'fin', false,
    'serial', v_tarjeta.visible_id,
    'tarifa', v_tarjeta.fare_type,
    'lote', v_tarjeta.batch_id
  );
end;
$$;

revoke all on function public.bt_admin_siguiente(text, uuid) from public, anon, authenticated;
grant execute on function public.bt_admin_siguiente(text, uuid) to anon;
