-- ============================================================
-- Prueba de aceptación de 0006_lotes_corporativos.sql
-- Requiere una base recién migrada con 0001→0006 y el PIN
-- administrador cargado en la sesión (blink.admin_pin), o bien
-- haber aplicado 0006 con PGOPTIONS="-c blink.admin_pin=…".
--
--   psql "$CADENA" -v ON_ERROR_STOP=1 -f supabase/pruebas/0006_lotes.sql
--
-- Todo ocurre en una transacción que termina en ROLLBACK: no deja
-- cuentas, tarjetas ni eventos de prueba.
-- ============================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

do $$
declare
  v_admin    jsonb;
  v_token    text;
  v_tarjeta  public.cards;
  v_lote     uuid;
  v_res      jsonb;
  v_cuenta2  jsonb;
begin
  v_admin := public.bt_entrar('V-34201580', current_setting('blink.admin_pin'));

  if v_admin ? 'error' then
    raise exception 'login administrador falló: %', v_admin;
  end if;

  if v_admin #>> '{cuenta,rol}' <> 'ADMIN' then
    raise exception 'rol administrador incorrecto';
  end if;

  if jsonb_array_length(v_admin -> 'tarjetas') <> 0 then
    raise exception 'la billetera del administrador no está vacía';
  end if;

  v_token := v_admin ->> 'token';

  v_res := public.bt_vincular(v_token, '23-1-000001-9');

  if jsonb_array_length(v_res -> 'tarjetas') <> 1 then
    raise exception 'el reclamo no devolvió la tarjeta';
  end if;

  select * into v_tarjeta from public.cards where visible_id = '23-1-000001-9';

  if v_tarjeta.status <> 'ACTIVE'
     or v_tarjeta.asignada_at is null
     or v_tarjeta.asignada_por <> 'portal' then
    raise exception 'estado tras el reclamo incorrecto: %', v_tarjeta.status;
  end if;

  begin
    perform public.bt_vincular(v_token, '23-1-000001-9');
    raise exception 'el reclamo duplicado debió fallar';
  exception when others then
    if sqlerrm not like 'bt:duplicada:%' then raise; end if;
  end;

  select id into v_lote from public.card_batches order by batch_number limit 1;

  v_res := public.bt_estacion_enrolar(v_lote, jsonb_build_array(
    jsonb_build_object('serial', '23-1-000002-7', 'uid', '04:84:cc:62'),
    jsonb_build_object('serial', '23-1-000003-5', 'uid', 'ZZZ')
  ), 'operador-01');

  if (v_res ->> 'enroladas')::int <> 1 or (v_res ->> 'rechazadas')::int <> 1 then
    raise exception 'resultado de enrolamiento inesperado: %', v_res;
  end if;

  select * into v_tarjeta from public.cards where visible_id = '23-1-000002-7';

  if v_tarjeta.chip_uid <> '0484CC62' or v_tarjeta.enrolada_por <> 'operador-01' then
    raise exception 'el enrolamiento no se aplicó';
  end if;

  v_res := public.bt_estacion_enrolar(v_lote, jsonb_build_array(
    jsonb_build_object('serial', '23-1-000003-5', 'uid', '0484CC62')
  ), 'operador-02');

  if (v_res ->> 'enroladas')::int <> 0 then
    raise exception 'se aceptó un UID duplicado';
  end if;

  v_res := public.bt_estacion_catalogo(v_lote);

  if jsonb_array_length(v_res -> 'tarjetas') <> 20 then
    raise exception 'catálogo incompleto';
  end if;

  v_cuenta2 := public.bt_registrar(
    'Ana', 'Pérez', 'V-12345678', '04141234567', 'ana@ejemplo.com', '135790'
  );

  if v_cuenta2 ? 'error' then
    raise exception 'registro de prueba falló: %', v_cuenta2;
  end if;

  v_res := public.bt_estacion_asignar('23-1-000004-3', 'V-12345678', 'taquilla-01');

  if jsonb_array_length(v_res -> 'tarjetas') <> 1 then
    raise exception 'la asignación en taquilla falló';
  end if;

  begin
    perform public.bt_vincular(v_token, '23-1-000004-3');
    raise exception 'el reclamo de una tarjeta ajena debió fallar';
  exception when others then
    if sqlerrm not like 'bt:ya-activada:%' then raise; end if;
  end;

  v_res := public.bt_resumen_operativo();

  if (v_res #>> '{tarjetas,fabricadas}')::int <> 18 then
    raise exception 'fabricadas=% (esperado 18)', v_res #>> '{tarjetas,fabricadas}';
  end if;

  if (v_res #>> '{tarjetas,asignadas}')::int <> 2 then
    raise exception 'asignadas=% (esperado 2)', v_res #>> '{tarjetas,asignadas}';
  end if;

  begin
    perform public.bt_reportar_perdida('23-1-000005-0');
    raise exception 'la pérdida de una tarjeta sin dueño debió fallar';
  exception when others then
    if sqlerrm not like '%aún no está asignada%' then raise; end if;
  end;

  if (select count(*) from public.card_events) <> 3 then
    raise exception 'eventos=% (esperado 3)', (select count(*) from public.card_events);
  end if;

  raise notice 'TODAS LAS PRUEBAS DE 0006 PASARON';
end;
$$;

rollback;
