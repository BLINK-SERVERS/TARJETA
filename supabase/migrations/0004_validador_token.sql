-- ============================================================
-- 0004 · Credencial de sincronización por validador
--
-- El ESP32 no puede guardar la llave secreta de Supabase: cualquiera con
-- acceso físico al equipo la leería. En su lugar cada unidad recibe un
-- token aleatorio de 32 bytes que se muestra una sola vez al provisionarla;
-- la base guarda solo su SHA-256. El token identifica la unidad, así que el
-- validador no puede declarar una MAC ajena ni sincronizar por otra.
--
-- Flujo:
--   1. Admin ejecuta bt_validador_emitir_token('<MAC>') con service_role.
--   2. Se copia el token al equipo (comando serie TOKEN,... o NVS).
--   3. El equipo llama bt_validador_sincronizar_token(token, taps, recargas)
--      con la llave publishable; la función resuelve la MAC y delega en
--      bt_validador_sincronizar, que sigue siendo service_role.
-- ============================================================

alter table public.vehicles
  add column if not exists sync_token_hash text;

comment on column public.vehicles.sync_token_hash is
  'SHA-256 hex del token de sincronización del validador; null = sin token.';

-- ------------------------------------------------------------
-- Emisión y revocación (solo service_role)
-- ------------------------------------------------------------

create or replace function public.bt_validador_emitir_token(p_mac text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_mac   text := public.bt_normalizar_mac(p_mac);
  v_token text;
begin
  if not exists (select 1 from public.vehicles where validator_mac = v_mac) then
    raise exception 'Validador no registrado: %.', v_mac;
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  update public.vehicles
     set sync_token_hash = encode(digest(v_token, 'sha256'), 'hex')
   where validator_mac = v_mac;

  -- Única vez que el token viaja en claro.
  return jsonb_build_object('mac', v_mac, 'token', v_token);
end;
$$;

create or replace function public.bt_validador_revocar_token(p_mac text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_mac text := public.bt_normalizar_mac(p_mac);
begin
  update public.vehicles set sync_token_hash = null where validator_mac = v_mac;
  return jsonb_build_object('mac', v_mac, 'revocado', found);
end;
$$;

-- ------------------------------------------------------------
-- Sincronización autenticada por token (publishable / anon)
-- ------------------------------------------------------------

create or replace function public.bt_validador_sincronizar_token(
  p_token text default null,
  p_taps jsonb default '[]'::jsonb,
  p_recargas jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_mac text;
begin
  if p_token is null or length(trim(p_token)) < 32 then
    raise exception 'Token de validador requerido' using errcode = '28000';
  end if;

  select v.validator_mac
    into v_mac
    from public.vehicles v
   where v.sync_token_hash = encode(digest(trim(p_token), 'sha256'), 'hex')
     and v.active;

  if v_mac is null then
    raise exception 'Token de validador inválido' using errcode = '28000';
  end if;

  return public.bt_validador_sincronizar(v_mac, p_taps, p_recargas);
end;
$$;

-- ------------------------------------------------------------
-- Permisos: se cierra todo y se abre solo la superficie necesaria
-- ------------------------------------------------------------

alter default privileges in schema public
  revoke execute on functions from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant execute on function public.bt_validador_emitir_token(text)              to service_role;
grant execute on function public.bt_validador_revocar_token(text)            to service_role;
grant execute on function public.bt_validador_sincronizar_token(text, jsonb, jsonb)
  to anon, authenticated;

-- El resto de la superficie del portal vuelve a abrirse (idempotente con 0001).
grant execute on function public.bt_entrar(text, text)                to anon, authenticated;
grant execute on function public.bt_activar(text, text, text, text)   to anon, authenticated;
grant execute on function public.bt_tarjeta(text)                     to anon, authenticated;
grant execute on function public.bt_movimientos(text, int)            to anon, authenticated;
grant execute on function public.bt_recargar(text, numeric, text, text, text) to anon, authenticated;
grant execute on function public.bt_cambiar_pin(text, text, text)     to anon, authenticated;
grant execute on function public.bt_salir(text)                       to anon, authenticated;
grant execute on function public.bt_ajustes()                         to anon, authenticated;
