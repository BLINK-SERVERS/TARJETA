-- ============================================================
-- BLINK TARJETA · datos de demostración
-- Opcional: solo para probar la app en la nube con las mismas
-- tarjetas del modo local. NO ejecutar en producción.
--
-- PIN de las tres tarjetas: 1234
-- ============================================================

insert into public.bt_tarjetas
  (serial, uid, nombre, cedula, telefono, saldo, tarifa, estado, emitida, vence, pin_hash)
values
  ('23-1-000001-9', '3981BF06', 'María Fernanda Fernández', 'V-12345678', '04141234567',
   485, 15, 'activa', '2025-03-14T12:00:00Z', '2030-03-14T12:00:00Z',
   extensions.crypt('1234', extensions.gen_salt('bf', 10))),
  ('23-1-000002-7', '058151954F3400', 'Carlos Andrés Rondón', 'V-87654321', '04248765432',
   0, 15, 'activa', '2025-06-02T12:00:00Z', '2030-06-02T12:00:00Z',
   extensions.crypt('1234', extensions.gen_salt('bf', 10))),
  ('23-1-000003-5', 'A1B2C3D4', 'Luis Enrique Pérez', 'V-11223344', '04125556677',
   30, 15, 'bloqueada', '2024-11-20T12:00:00Z', '2029-11-20T12:00:00Z',
   extensions.crypt('1234', extensions.gen_salt('bf', 10)))
on conflict (serial) do nothing;

-- Extracto de la primera tarjeta
insert into public.bt_movimientos
  (tarjeta_id, tipo, monto, saldo_despues, detalle, estado, unidad, banco, referencia, at)
select t.id, v.tipo, v.monto, v.saldo, v.detalle, 'aprobado', v.unidad, v.banco, v.ref, now() - v.hace
  from public.bt_tarjetas t
  cross join (values
    ('viaje',   -15::numeric, 485::numeric, 'Pasaje en la línea', 'Demo-01', null::text, null::text, interval '7 hours'),
    ('viaje',   -15,          500,           'Pasaje en la línea', 'Demo-01', null, null, interval '8 hours'),
    ('recarga',  500,         515,           'Pago Móvil aprobado', null, 'Banesco', '4821', interval '1 day 3 hours'),
    ('viaje',   -15,          15,            'Pasaje en la línea', 'Demo-02', null, null, interval '2 days 2 hours'),
    ('viaje',   -15,          30,            'Pasaje en la línea', 'Demo-02', null, null, interval '2 days 3 hours'),
    ('recarga',  200,         45,            'Pago Móvil aprobado', null, 'Mercantil', '9034', interval '6 days')
  ) as v(tipo, monto, saldo, detalle, unidad, banco, ref, hace)
 where t.serial = '23-1-000001-9'
   and not exists (select 1 from public.bt_movimientos m where m.tarjeta_id = t.id);

-- Viaje de la tarjeta bloqueada
insert into public.bt_movimientos
  (tarjeta_id, tipo, monto, saldo_despues, detalle, estado, unidad, at)
select t.id, 'viaje', -15, 30, 'Pasaje en la línea', 'aprobado', 'Demo-03', now() - interval '3 days'
  from public.bt_tarjetas t
 where t.serial = '23-1-000003-5'
   and not exists (select 1 from public.bt_movimientos m where m.tarjeta_id = t.id);

-- Recarga en revisión de la segunda tarjeta
do $$
declare
  v_tarjeta uuid;
  v_mov     uuid;
begin
  select id into v_tarjeta from public.bt_tarjetas where serial = '23-1-000002-7';

  if exists (select 1 from public.bt_recargas where tarjeta_id = v_tarjeta) then
    return;
  end if;

  insert into public.bt_movimientos
    (tarjeta_id, tipo, monto, saldo_despues, detalle, estado, banco, referencia, at)
  values
    (v_tarjeta, 'recarga', 100, 0, 'Pago Móvil en revisión', 'pendiente',
     'Banco de Venezuela', '1177', now() - interval '1 hour')
  returning id into v_mov;

  insert into public.bt_recargas
    (tarjeta_id, movimiento_id, monto, telefono, banco, referencia, reportada)
  values
    (v_tarjeta, v_mov, 100, '04248765432', 'Banco de Venezuela', '1177', now() - interval '1 hour');
end;
$$;
