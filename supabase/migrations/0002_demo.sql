-- ============================================================
-- BLINK · datos de demostración
-- Opcional: solo para probar el portal en la nube con las mismas
-- tarjetas del modo local. NO ejecutar en producción.
--
-- PIN de las tres tarjetas: 1234
-- ============================================================

insert into public.card_batches (batch_number, sponsor_name, cards_quantity, state_code, fare_type)
values (1, 'Lotería del Zulia', 3, 23, 1)
on conflict (batch_number) do nothing;

insert into public.transit_routes (name, general_fare, student_fare)
values
  ('Curva de Molina - Centro', 15, 7.5),
  ('La Limpia - Terminal', 15, 7.5)
on conflict do nothing;

insert into public.vehicles
  (route_id, plate_number, vehicle_type, driver_name, driver_doc_id,
   bank_code, bank_account_or_phone, validator_mac, commission_pct, line_fee)
select r.id, v.placa, v.tipo, v.chofer, v.cedula, v.banco, v.cuenta, v.mac, 8, 0
  from (values
    ('Curva de Molina - Centro', 'A12BC3D', 'CARRO', 'José Ángel Nava', 'V-14555666',
     '0102', '04141234567', 'A0B1C2D3E4F5'),
    ('La Limpia - Terminal', 'A99XY7Z', 'BUS', 'Marisol Urdaneta', 'V-10222333',
     '0134', '04248765432', '001122334455')
  ) as v(ruta, placa, tipo, chofer, cedula, banco, cuenta, mac)
  join public.transit_routes r on r.name = v.ruta
on conflict (plate_number) do nothing;

insert into public.cards
  (visible_id, chip_uid, nombre, cedula, telefono, virtual_balance, last_chip_balance,
   tarifa, status, batch_id, emitida, vence, pin_hash)
select v.serial, v.uid, v.nombre, v.cedula, v.telefono, v.saldo, v.saldo,
       v.tarifa, v.estado, b.id, v.emitida, v.vence,
       extensions.crypt('1234', extensions.gen_salt('bf', 10))
  from (values
    ('23-1-000001-9', '3981BF06', 'María Fernanda Fernández', 'V-12345678', '04141234567',
     485, 15, 'ACTIVE', timestamptz '2025-03-14T12:00:00Z', timestamptz '2030-03-14T12:00:00Z'),
    ('23-1-000002-7', '058151954F3400', 'Carlos Andrés Rondón', 'V-87654321', '04248765432',
     0, 15, 'ACTIVE', timestamptz '2025-06-02T12:00:00Z', timestamptz '2030-06-02T12:00:00Z'),
    ('23-1-000003-5', 'A1B2C3D4', 'Luis Enrique Pérez', 'V-11223344', '04125556677',
     30, 30, 'BLOCKED', timestamptz '2024-11-20T12:00:00Z', timestamptz '2029-11-20T12:00:00Z')
  ) as v(serial, uid, nombre, cedula, telefono, saldo, tarifa, estado, emitida, vence)
  cross join (select id from public.card_batches where batch_number = 1) b
on conflict (visible_id) do nothing;

-- Extracto de la primera tarjeta
insert into public.card_movements
  (card_id, tipo, monto, saldo_despues, detalle, estado, unidad, banco, referencia, at)
select t.id, v.tipo, v.monto, v.saldo, v.detalle, 'aprobado', v.unidad, v.banco, v.ref, now() - v.hace
  from public.cards t
  cross join (values
    ('viaje',   -15::numeric, 485::numeric, 'Pasaje en la línea', 'A12BC3D', null::text, null::text, interval '7 hours'),
    ('viaje',   -15,          500,           'Pasaje en la línea', 'A12BC3D', null, null, interval '8 hours'),
    ('recarga',  500,         515,           'Pago Móvil aprobado', null, 'Banesco', '4821', interval '1 day 3 hours'),
    ('viaje',   -15,          15,            'Pasaje en la línea', 'A99XY7Z', null, null, interval '2 days 2 hours'),
    ('viaje',   -15,          30,            'Pasaje en la línea', 'A99XY7Z', null, null, interval '2 days 3 hours'),
    ('recarga',  200,         45,            'Pago Móvil aprobado', null, 'Mercantil', '9034', interval '6 days')
  ) as v(tipo, monto, saldo, detalle, unidad, banco, ref, hace)
 where t.visible_id = '23-1-000001-9'
   and not exists (select 1 from public.card_movements m where m.card_id = t.id);

-- Viaje de la tarjeta bloqueada
insert into public.card_movements
  (card_id, tipo, monto, saldo_despues, detalle, estado, unidad, at)
select t.id, 'viaje', -15, 30, 'Pasaje en la línea', 'aprobado', 'A99XY7Z', now() - interval '3 days'
  from public.cards t
 where t.visible_id = '23-1-000003-5'
   and not exists (select 1 from public.card_movements m where m.card_id = t.id);

-- Recargas: una acreditada y sincronizada, otra en revisión
insert into public.recharges
  (card_id, movement_id, amount, sender_phone, bank, bank_reference,
   status, synced_to_chip, synced_at, created_at, resolved_at, resolved_by)
select m.card_id, m.id, 500, '04141234567', 'Banesco', '4821',
       'aprobado', true, m.at + interval '2 hours', m.at, m.at + interval '10 minutes', 'admin'
  from public.card_movements m
  join public.cards c on c.id = m.card_id
 where c.visible_id = '23-1-000001-9'
   and m.tipo = 'recarga'
   and m.referencia = '4821'
   and not exists (select 1 from public.recharges r where r.movement_id = m.id);

do $$
declare
  v_tarjeta uuid;
  v_mov     uuid;
begin
  select id into v_tarjeta from public.cards where visible_id = '23-1-000002-7';

  if exists (select 1 from public.recharges where card_id = v_tarjeta) then
    return;
  end if;

  insert into public.card_movements
    (card_id, tipo, monto, saldo_despues, detalle, estado, banco, referencia, at)
  values
    (v_tarjeta, 'recarga', 100, 0, 'Pago Móvil en revisión', 'pendiente',
     'Banco de Venezuela', '1177', now() - interval '1 hour')
  returning id into v_mov;

  insert into public.recharges
    (card_id, movement_id, amount, sender_phone, bank, bank_reference, created_at)
  values
    (v_tarjeta, v_mov, 100, '04248765432', 'Banco de Venezuela', '1177', now() - interval '1 hour');
end;
$$;

-- Telemetría de ejemplo: dos cobros que aún no se liquidan
insert into public.trips_telemetry
  (card_id, vehicle_id, route_id, fare_charged, fare_type, latitude, longitude,
   validator_mac, offline_id, chip_balance_after, tapped_at)
select c.id, v.id, v.route_id, 15, 1, 10.6427, -71.6125, v.validator_mac,
       'demo-' || c.visible_id || '-' || to_char(now() - x.hace, 'YYYYMMDDHH24MI'),
       c.virtual_balance, now() - x.hace
  from (values
    ('23-1-000001-9', 'A12BC3D', interval '7 hours'),
    ('23-1-000003-5', 'A99XY7Z', interval '3 days')
  ) as x(serial, placa, hace)
  join public.cards c on c.visible_id = x.serial
  join public.vehicles v on v.plate_number = x.placa
on conflict (offline_id) do nothing;
