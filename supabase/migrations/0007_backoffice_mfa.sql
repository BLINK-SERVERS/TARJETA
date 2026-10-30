-- ============================================================
-- BLINK · back-office con RBAC y verificación en dos pasos
-- Ejecutar después de 0006_lotes_corporativos.sql.
--
-- Separa la operación administrativa del portal del pasajero:
--   * sesión de back-office solo para roles ADMIN y TAQUILLA,
--   * TOTP (RFC 6238) verificado en el servidor con pgcrypto,
--   * RPC de estación, lote y resumen que reciben el token de la
--     cuenta en vez de la clave de servicio, para que el navegador
--     del operador nunca lleve `service_role`.
--
-- El TOTP se verifica aquí, no en el cliente: el secreto solo sale
-- una vez al inscribir el dispositivo.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Segundo factor en la cuenta
-- ------------------------------------------------------------
alter table public.accounts
  add column if not exists totp_secret text,
  add column if not exists totp_activo boolean not null default false,
  add column if not exists totp_confirmado_at timestamptz;

-- ------------------------------------------------------------
-- 2. TOTP (RFC 6238 sobre HMAC-SHA1, 30 s, 6 dígitos)
-- ------------------------------------------------------------

-- Base32 sin relleno, que es lo que entregan las aplicaciones
-- autenticadoras al mostrar el secreto.
create or replace function public.bt_totp_base32(p_secreto text)
returns bytea
language plpgsql immutable as $$
declare
  v_alfabeto text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  v_s     text := upper(regexp_replace(coalesce(p_secreto, ''), '[^A-Za-z2-7]', '', 'g'));
  v_bits  int := 0;
  v_valor int := 0;
  v_salida bytea := ''::bytea;
  v_idx   int;
  i int;
begin
  for i in 1..length(v_s) loop
    v_idx := position(substr(v_s, i, 1) in v_alfabeto) - 1;
    if v_idx < 0 then
      continue;
    end if;

    v_valor := (v_valor << 5) | v_idx;
    v_bits := v_bits + 5;

    if v_bits >= 8 then
      v_bits := v_bits - 8;
      v_salida := v_salida || decode(lpad(to_hex((v_valor >> v_bits) & 255), 2, '0'), 'hex');
      v_valor := v_valor & ((1 << v_bits) - 1);
    end if;
  end loop;

  return v_salida;
end;
$$;

create or replace function public.bt_totp_codigo(p_secreto text, p_contador bigint)
returns text
language plpgsql immutable as $$
declare
  v_hex text;
  v_off int;
  v_bin bigint;
begin
  v_hex := encode(
    extensions.hmac(
      decode(lpad(to_hex(p_contador), 16, '0'), 'hex'),
      public.bt_totp_base32(p_secreto),
      'sha1'),
    'hex');

  v_off := ('x' || substr(v_hex, 40, 1))::bit(4)::int;
  v_bin := (('x' || substr(v_hex, v_off * 2 + 1, 8))::bit(32)::bigint) & 2147483647;

  return lpad((v_bin % 1000000)::text, 6, '0');
end;
$$;

-- Margen de un paso (±30 s) por desfase de reloj.
create or replace function public.bt_totp_valido(p_secreto text, p_codigo text)
returns boolean
language plpgsql stable as $$
declare
  v_t bigint;
  d int;
begin
  if coalesce(p_secreto, '') = '' or coalesce(p_codigo, '') !~ '^\d{6}$' then
    return false;
  end if;

  v_t := floor(extract(epoch from now()) / 30)::bigint;

  for d in -1..1 loop
    if public.bt_totp_codigo(p_secreto, v_t + d) = p_codigo then
      return true;
    end if;
  end loop;

  return false;
end;
$$;

-- ------------------------------------------------------------
-- 3. Sesión de back-office
-- ------------------------------------------------------------
create or replace function public.bt_admin_sesion(p_token text)
returns public.accounts
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts;
begin
  select a.* into v_cuenta
    from public.account_sessions s
    join public.accounts a on a.id = s.account_id
   where s.token::text = coalesce(p_token, '')
     and s.expira > now();

  if not found then
    raise exception 'bt:sesion:Tu sesión venció. Vuelve a entrar.';
  end if;

  if v_cuenta.rol not in ('ADMIN', 'TAQUILLA') then
    raise exception 'bt:permiso:Esta cuenta no tiene acceso al back-office.';
  end if;

  return v_cuenta;
end;
$$;

-- Las operaciones de inventario exigen el segundo factor ya activo.
create or replace function public.bt_admin_sesion_mfa(p_token text)
returns public.accounts
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion(p_token);
begin
  if not v_cuenta.totp_activo then
    raise exception 'bt:mfa:Activa la verificación en dos pasos antes de operar.';
  end if;

  return v_cuenta;
end;
$$;

-- ------------------------------------------------------------
-- 4. Acceso del operador
-- ------------------------------------------------------------
create or replace function public.bt_admin_entrar(
  p_cedula text,
  p_pin text,
  p_codigo text default ''
)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_cuenta  public.accounts;
  v_token   uuid;
  v_fallos  int;
begin
  if v_digitos !~ '^\d{6,8}$' then
    raise exception 'bt:sin-tarjeta:No encontramos una cuenta con esa cédula.';
  end if;

  select * into v_cuenta from public.accounts where cedula_digitos = v_digitos;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos una cuenta con esa cédula.';
  end if;

  if v_cuenta.rol not in ('ADMIN', 'TAQUILLA') then
    return jsonb_build_object(
      'error', 'permiso',
      'mensaje', 'Esta cuenta no tiene acceso al back-office.');
  end if;

  if v_cuenta.bloqueado_hasta is not null and v_cuenta.bloqueado_hasta > now() then
    raise exception 'bt:credenciales:Demasiados intentos fallidos. Espera % min.',
      greatest(1, ceil(extract(epoch from (v_cuenta.bloqueado_hasta - now())) / 60)::int);
  end if;

  if extensions.crypt(coalesce(p_pin, ''), v_cuenta.pin_hash) <> v_cuenta.pin_hash then
    v_fallos := case
      when v_cuenta.bloqueado_hasta is not null and v_cuenta.bloqueado_hasta <= now() then 1
      else v_cuenta.intentos + 1
    end;

    update public.accounts
       set intentos = v_fallos,
           bloqueado_hasta = case when v_fallos >= 5 then now() + interval '5 minutes' end
     where id = v_cuenta.id;

    return jsonb_build_object(
      'error', 'credenciales',
      'mensaje', 'El PIN no coincide. Inténtalo de nuevo.');
  end if;

  if v_cuenta.totp_activo and not public.bt_totp_valido(v_cuenta.totp_secret, p_codigo) then
    return jsonb_build_object(
      'error', 'mfa',
      'mensaje', 'El código de verificación no es válido o venció.');
  end if;

  update public.accounts
     set intentos = 0, bloqueado_hasta = null
   where id = v_cuenta.id;

  delete from public.account_sessions where expira < now();

  insert into public.account_sessions (account_id)
  values (v_cuenta.id)
  returning token into v_token;

  return jsonb_build_object(
    'token', v_token,
    'rol', v_cuenta.rol,
    'mfa', v_cuenta.totp_activo,
    'mfaPendiente', not v_cuenta.totp_activo,
    'cuenta', public.bt_cuenta_json(v_cuenta));
end;
$$;

create or replace function public.bt_admin_estado(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion(p_token);
begin
  return jsonb_build_object(
    'rol', v_cuenta.rol,
    'mfa', v_cuenta.totp_activo,
    'mfaPendiente', not v_cuenta.totp_activo,
    'cuenta', public.bt_cuenta_json(v_cuenta));
end;
$$;

-- ------------------------------------------------------------
-- 5. Inscripción y activación del segundo factor
-- ------------------------------------------------------------
create or replace function public.bt_admin_mfa_inscribir(p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_alfabeto text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  v_cuenta public.accounts := public.bt_admin_sesion(p_token);
  v_secreto text := '';
  v_uri text;
  i int;
begin
  for i in 1..32 loop
    v_secreto := v_secreto || substr(v_alfabeto, (get_byte(extensions.gen_random_bytes(1), 0) % 32) + 1, 1);
  end loop;

  update public.accounts
     set totp_secret = v_secreto,
         totp_activo = false,
         totp_confirmado_at = null
   where id = v_cuenta.id;

  v_uri := 'otpauth://totp/BLINK%20Backoffice:' || replace(v_cuenta.cedula, ' ', '')
        || '?secret=' || v_secreto
        || '&issuer=BLINK&algorithm=SHA1&digits=6&period=30';

  return jsonb_build_object('secreto', v_secreto, 'uri', v_uri);
end;
$$;

create or replace function public.bt_admin_mfa_activar(p_token text, p_codigo text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion(p_token);
begin
  if coalesce(v_cuenta.totp_secret, '') = '' then
    return jsonb_build_object(
      'error', 'mfa',
      'mensaje', 'Primero inscribe el dispositivo.');
  end if;

  if not public.bt_totp_valido(v_cuenta.totp_secret, p_codigo) then
    return jsonb_build_object(
      'error', 'mfa',
      'mensaje', 'El código no coincide. Revisa la hora del teléfono.');
  end if;

  update public.accounts
     set totp_activo = true,
         totp_confirmado_at = now()
   where id = v_cuenta.id;

  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 6. Operación: estación, lote y resumen
-- ------------------------------------------------------------
create or replace function public.bt_admin_resumen(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.bt_admin_sesion_mfa(p_token);
  return public.bt_resumen_operativo();
end;
$$;

create or replace function public.bt_admin_lote(
  p_token text,
  p_cantidad int,
  p_patrocinante text default null,
  p_estado int default 23,
  p_tarifa int default 1,
  p_origen text default 'FABRICANTE'
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
begin
  return public.bt_generar_lote(p_cantidad, p_patrocinante, p_estado, p_tarifa, p_origen)
    || jsonb_build_object('creadoPor', v_cuenta.nombres || ' ' || v_cuenta.apellidos);
end;
$$;

create or replace function public.bt_admin_catalogo(p_token text, p_lote uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.bt_admin_sesion_mfa(p_token);
  return public.bt_estacion_catalogo(p_lote);
end;
$$;

create or replace function public.bt_admin_enrolar(
  p_token text,
  p_lote uuid,
  p_items jsonb,
  p_operador text default ''
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_operador text := coalesce(
    nullif(trim(coalesce(p_operador, '')), ''),
    v_cuenta.nombres || ' ' || v_cuenta.apellidos);
begin
  return public.bt_estacion_enrolar(p_lote, p_items, v_operador);
end;
$$;

create or replace function public.bt_admin_asignar(
  p_token text,
  p_serial text,
  p_cedula text,
  p_operador text default ''
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_admin_sesion_mfa(p_token);
  v_operador text := coalesce(
    nullif(trim(coalesce(p_operador, '')), ''),
    v_cuenta.nombres || ' ' || v_cuenta.apellidos);
begin
  return public.bt_estacion_asignar(p_serial, p_cedula, v_operador);
end;
$$;

-- ------------------------------------------------------------
-- 7. Permisos
-- ------------------------------------------------------------
revoke all on function public.bt_totp_base32(text) from public, anon, authenticated;
revoke all on function public.bt_totp_codigo(text, bigint) from public, anon, authenticated;
revoke all on function public.bt_totp_valido(text, text) from public, anon, authenticated;
revoke all on function public.bt_admin_sesion(text) from public, anon, authenticated;
revoke all on function public.bt_admin_sesion_mfa(text) from public, anon, authenticated;

revoke all on function public.bt_admin_entrar(text, text, text) from public, anon, authenticated;
revoke all on function public.bt_admin_estado(text) from public, anon, authenticated;
revoke all on function public.bt_admin_mfa_inscribir(text) from public, anon, authenticated;
revoke all on function public.bt_admin_mfa_activar(text, text) from public, anon, authenticated;
revoke all on function public.bt_admin_resumen(text) from public, anon, authenticated;
revoke all on function public.bt_admin_lote(text, int, text, int, int, text) from public, anon, authenticated;
revoke all on function public.bt_admin_catalogo(text, uuid) from public, anon, authenticated;
revoke all on function public.bt_admin_enrolar(text, uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.bt_admin_asignar(text, text, text, text) from public, anon, authenticated;

grant execute on function public.bt_admin_entrar(text, text, text) to anon;
grant execute on function public.bt_admin_estado(text) to anon;
grant execute on function public.bt_admin_mfa_inscribir(text) to anon;
grant execute on function public.bt_admin_mfa_activar(text, text) to anon;
grant execute on function public.bt_admin_resumen(text) to anon;
grant execute on function public.bt_admin_lote(text, int, text, int, int, text) to anon;
grant execute on function public.bt_admin_catalogo(text, uuid) to anon;
grant execute on function public.bt_admin_enrolar(text, uuid, jsonb, text) to anon;
grant execute on function public.bt_admin_asignar(text, text, text, text) to anon;
