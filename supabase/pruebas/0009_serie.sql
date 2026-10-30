-- ============================================================
-- Prueba de aceptación de 0009_serie_siete_digitos.sql
-- Requiere una base migrada con 0001→0009 y al menos una cuenta.
--
--   psql "$CADENA" -v ON_ERROR_STOP=1 -f supabase/pruebas/0009_serie.sql
--
-- Todo ocurre en una transacción que termina en ROLLBACK: no deja
-- tarjeta maestra, lotes ni eventos de prueba.
-- ============================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

do $$
declare
  v_cedula text;
  v_maestra jsonb;
  v_lote   jsonb;
  v_id     uuid;
  v_serial text;
  v_luhn   text;
  v_res    jsonb;
begin
  -- 1. La serie heredada de 10 dígitos sigue siendo válida.
  if not public.bt_luhn_valido('23-1-000001-9') then
    raise exception 'el serial heredado 23-1-000001-9 dejó de validar';
  end if;
  if public.bt_luhn_valido('23-1-000001-0') then
    raise exception 'se aceptó un verificador de Luhn incorrecto';
  end if;

  -- 2. La serie nueva de 11 dígitos usa la misma regla, con otra paridad.
  v_luhn := public.bt_luhn_digito('2310000001');
  if v_luhn <> '9' then
    raise exception 'Luhn de 2310000001 = % (esperado 9)', v_luhn;
  end if;
  if not public.bt_luhn_valido('23-1-0000001-9') then
    raise exception 'el serial 23-1-0000001-9 no valida';
  end if;

  -- 3. Todo serial almacenado cumple el formato y el verificador.
  if exists (
    select 1 from public.cards
     where visible_id ~ '^\d{2}-\d-\d{6,7}-\d$'
       and not public.bt_luhn_valido(visible_id)
  ) then
    raise exception 'hay tarjetas con Luhn inválido';
  end if;

  -- 4. La tarjeta maestra del propietario.
  select cedula_digitos into v_cedula
    from public.accounts
   where rol = 'ADMIN'
   limit 1;

  if v_cedula is null then
    raise exception 'no hay una cuenta ADMIN para la prueba';
  end if;

  -- En producción la maestra ya existe: se retira dentro de esta
  -- transacción para probar la creación desde cero. El ROLLBACK la
  -- devuelve intacta junto con su bitácora.
  if exists (select 1 from public.cards where visible_id = '00-0-000000-0') then
    delete from public.cards where visible_id = '00-0-000000-0';
  end if;

  v_maestra := public.bt_crear_tarjeta_maestra(v_cedula, 'AABBCCDD', 'prueba');

  if v_maestra #>> '{tarjeta,serial}' <> '00-0-000000-0' then
    raise exception 'serial de la maestra = %', v_maestra #>> '{tarjeta,serial}';
  end if;
  if (select fare_type from public.cards where visible_id = '00-0-000000-0') <> 0 then
    raise exception 'la maestra no quedó con tarifa 0';
  end if;
  if (select state_code from public.cards where visible_id = '00-0-000000-0') <> 0 then
    raise exception 'la maestra no quedó con entidad 00';
  end if;

  begin
    perform public.bt_crear_tarjeta_maestra(v_cedula, null, 'prueba');
    raise exception 'la segunda maestra debió fallar';
  exception when others then
    if sqlerrm not like '%ya existe%' then raise; end if;
  end;

  -- 5. Un lote con inicio explícito produce seriales de 11 dígitos.
  v_lote := public.bt_generar_lote(3, 'Prueba 0009', 23, 1, 'FABRICANTE', 9000001);
  v_id := (v_lote #>> '{lote,id}')::uuid;

  if (v_lote #>> '{lote,desde}') !~ '^23-1-9000001-\d$' then
    raise exception 'primer serial del lote = %', v_lote #>> '{lote,desde}';
  end if;
  if (v_lote #>> '{lote,hasta}') !~ '^23-1-9000003-\d$' then
    raise exception 'último serial del lote = %', v_lote #>> '{lote,hasta}';
  end if;
  if jsonb_array_length(v_lote -> 'tarjetas') <> 3 then
    raise exception 'el lote no trajo 3 tarjetas';
  end if;

  -- 6. Un segundo lote que pise la serie se rechaza.
  begin
    perform public.bt_generar_lote(1, null, 23, 1, 'FABRICANTE', 9000002);
    raise exception 'el lote solapado debió fallar';
  exception when others then
    if sqlerrm not like '%ya tiene tarjetas%' then raise; end if;
  end;

  -- 7. El enrollado acepta el serial de 11 dígitos y deja la bitácora.
  v_serial := v_lote #>> '{tarjetas,0,serial}';
  v_res := public.bt_estacion_enrolar(
    v_id,
    jsonb_build_array(jsonb_build_object('serial', v_serial, 'uid', '11223344')),
    'prueba');

  if (v_res #>> '{enroladas}')::int <> 1 then
    raise exception 'el enrollado rechazó la tarjeta: %', v_res -> 'errores';
  end if;
  if (select chip_uid from public.cards where visible_id = v_serial) <> '11223344' then
    raise exception 'la tarjeta % no quedó enrolada', v_serial;
  end if;
  if not exists (
    select 1 from public.card_events e
      join public.cards c on c.id = e.card_id
     where c.visible_id = v_serial and e.evento = 'ENROLADA'
  ) then
    raise exception 'falta el evento ENROLADA de %', v_serial;
  end if;

  -- 8. La tarifa 0 no se puede producir en lote.
  begin
    perform public.bt_generar_lote(1, null, 23, 0, 'FABRICANTE');
    raise exception 'el lote con tarifa 0 debió fallar';
  exception when others then
    if sqlerrm not like '%tipo de tarifa%' then raise; end if;
  end;

  raise notice 'PRUEBAS_0009_OK';
end;
$$;

rollback;
