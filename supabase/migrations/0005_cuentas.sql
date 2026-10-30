-- ============================================================
-- BLINK · cuentas del pasajero y billetera multi-tarjeta
-- Ejecutar después de 0004_validador_token.sql.
--
-- Cambia la identidad del portal: antes el PIN y la cédula vivían
-- en cada plástico (cards); ahora viven en una cuenta que puede
-- tener varias tarjetas. Los datos de Pago Móvil también son de la
-- cuenta, porque muchas familias recargan con la cuenta de un
-- familiar.
--
-- Las tarjetas nuevas conservan `cards.nombre` como titular visible
-- y se enlazan con `cards.account_id`. La cédula y el PIN de la
-- cuenta se validan solo en `accounts`.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Cuentas
-- ------------------------------------------------------------
create table if not exists public.accounts (
  id              uuid primary key default gen_random_uuid(),
  nombres         text not null check (nombres ~ '^[^0-9]{2,60}$'),
  apellidos       text not null check (apellidos ~ '^[^0-9]{2,60}$'),
  cedula          text not null check (cedula ~ '^[VE]-\d{6,8}$'),
  cedula_digitos  text generated always as
                  (regexp_replace(cedula, '\D', '', 'g')) stored,
  telefono        text not null check (telefono ~ '^0\d{10}$'),
  correo          text not null check (correo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  pin_hash        text not null,
  intentos        int not null default 0 check (intentos >= 0),
  bloqueado_hasta timestamptz,

  -- Fuente de pago (Pago Móvil) con la que se recarga la billetera.
  pago_propio     boolean not null default true,
  pago_banco      text not null default '',
  pago_telefono   text not null default '',
  pago_cedula     text not null default '',

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create unique index if not exists accounts_cedula_idx on public.accounts (cedula_digitos);
create unique index if not exists accounts_correo_idx on public.accounts (lower(correo));

drop trigger if exists accounts_actualizada on public.accounts;
create trigger accounts_actualizada
  before update on public.accounts
  for each row execute function public.bt_tocar_actualizada();

alter table public.accounts enable row level security;

-- ------------------------------------------------------------
-- 2. Billetera: cada plástico pertenece a una cuenta
-- ------------------------------------------------------------
alter table public.cards
  add column if not exists account_id uuid references public.accounts(id) on delete set null;

create index if not exists cards_account_idx on public.cards (account_id);

-- ------------------------------------------------------------
-- 3. Sesiones de la cuenta (una sola para todas sus tarjetas)
-- ------------------------------------------------------------
create table if not exists public.account_sessions (
  token      uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  creada     timestamptz not null default now(),
  expira     timestamptz not null default now() + interval '12 hours'
);

create index if not exists account_sessions_expira_idx on public.account_sessions (expira);

alter table public.account_sessions enable row level security;

-- ------------------------------------------------------------
-- 4. Utilidades de la cuenta
-- ------------------------------------------------------------

-- PIN de 6 dígitos, sin repeticiones ni secuencias de 6 en fila.
create or replace function public.bt_pin6_valido(p_pin text)
returns boolean language plpgsql immutable as $$
declare
  v_pin  text := coalesce(p_pin, '');
  v_asc  int := 0;
  v_desc int := 0;
  i int;
begin
  if v_pin !~ '^\d{6}$' then
    return false;
  end if;

  if v_pin ~ '^(\d)\1{5}$' then
    return false;
  end if;

  for i in 1..5 loop
    if substr(v_pin, i + 1, 1)::int = substr(v_pin, i, 1)::int + 1 then
      v_asc := v_asc + 1;
    end if;
    if substr(v_pin, i + 1, 1)::int = substr(v_pin, i, 1)::int - 1 then
      v_desc := v_desc + 1;
    end if;
  end loop;

  return v_asc < 5 and v_desc < 5;
end;
$$;

create or replace function public.bt_cuenta_json(a public.accounts)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'nombres',   a.nombres,
    'apellidos', a.apellidos,
    'cedula',    a.cedula,
    'telefono',  a.telefono,
    'correo',    a.correo,
    'datosPago', jsonb_build_object(
                   'propio',   a.pago_propio,
                   'banco',    a.pago_banco,
                   'telefono', a.pago_telefono,
                   'cedula',   a.pago_cedula)
  );
$$;

-- Tarjeta vista desde la cuenta: el titular es siempre la cuenta.
create or replace function public.bt_tarjeta_cuenta_json(t public.cards, a public.accounts)
returns jsonb language sql stable as $$
  select public.bt_tarjeta_json(t) || jsonb_build_object(
    'titular', jsonb_build_object(
      'nombre',   a.nombres || ' ' || a.apellidos,
      'cedula',   a.cedula,
      'telefono', a.telefono)
  );
$$;

create or replace function public.bt_billetera_json(a public.accounts)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'cuenta', public.bt_cuenta_json(a),
    'tarjetas', coalesce((
      select jsonb_agg(public.bt_tarjeta_cuenta_json(t, a) order by t.emitida)
        from public.cards t
       where t.account_id = a.id
         and t.status <> 'LOST'
    ), '[]'::jsonb)
  );
$$;

-- Tarjeta de la billetera o error de sesión/permiso.
create or replace function public.bt_tarjeta_de_cuenta(a public.accounts, p_serial text)
returns public.cards
language plpgsql stable set search_path = public as $$
declare
  v_tarjeta public.cards;
begin
  select * into v_tarjeta
    from public.cards
   where visible_id = trim(coalesce(p_serial, ''))
     and account_id = a.id;

  if not found then
    raise exception 'bt:sin-tarjeta:Esa tarjeta no está en tu billetera.';
  end if;

  return v_tarjeta;
end;
$$;

-- Cuenta dueña del token, o error de sesión.
create or replace function public.bt_sesion_cuenta(p_token text)
returns public.accounts
language plpgsql stable security definer set search_path = public as $$
declare
  v_cuenta public.accounts;
begin
  if p_token is null
     or p_token !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    raise exception 'bt:sesion:La sesión expiró. Vuelve a entrar con tu PIN.';
  end if;

  select a.* into v_cuenta
    from public.account_sessions s
    join public.accounts a on a.id = s.account_id
   where s.token = p_token::uuid
     and s.expira > now();

  if not found then
    raise exception 'bt:sesion:La sesión expiró. Vuelve a entrar con tu PIN.';
  end if;

  return v_cuenta;
end;
$$;

-- ------------------------------------------------------------
-- 5. Portal: contar, registrar y entrar
-- ------------------------------------------------------------
create or replace function public.bt_registrar(
  p_nombres text,
  p_apellidos text,
  p_cedula text,
  p_telefono text,
  p_correo text,
  p_pin text,
  p_pago_propio boolean default true,
  p_pago_banco text default '',
  p_pago_telefono text default '',
  p_pago_cedula text default ''
)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_nombres  text := trim(coalesce(p_nombres, ''));
  v_apellidos text := trim(coalesce(p_apellidos, ''));
  v_cedula   text := upper(trim(coalesce(p_cedula, '')));
  v_digitos  text := public.bt_solo_digitos(p_cedula);
  v_tel      text := public.bt_solo_digitos(p_telefono);
  v_correo   text := lower(trim(coalesce(p_correo, '')));
  v_propio   boolean := coalesce(p_pago_propio, true);
  v_banco    text := trim(coalesce(p_pago_banco, ''));
  v_pago_tel text := public.bt_solo_digitos(p_pago_telefono);
  v_pago_ced text := upper(trim(coalesce(p_pago_cedula, '')));
  v_cuenta   public.accounts;
  v_token    uuid;
begin
  if v_nombres !~ '^[^0-9]{2,60}$' then
    raise exception 'bt:datos:Revisa tu nombre: entre 2 y 60 letras, sin números.';
  end if;

  if v_apellidos !~ '^[^0-9]{2,60}$' then
    raise exception 'bt:datos:Revisa tus apellidos: entre 2 y 60 letras, sin números.';
  end if;

  if v_digitos !~ '^\d{6,8}$' or v_cedula !~ '^[VE]-' then
    raise exception 'bt:datos:Usa V para venezolano o E para extranjero, con 6 a 8 dígitos.';
  end if;

  if v_tel !~ '^0\d{10}$' then
    raise exception 'bt:datos:El teléfono debe tener 11 dígitos y empezar por 0 (ej. 0414-1234567).';
  end if;

  if v_correo !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'bt:datos:Escribe un correo válido (ej. nombre@correo.com).';
  end if;

  if not public.bt_pin6_valido(p_pin) then
    raise exception 'bt:pin-invalido:Elige 6 dígitos, sin repetir el mismo ni secuencias como 123456.';
  end if;

  if exists (select 1 from public.accounts where cedula_digitos = v_digitos) then
    raise exception 'bt:ya-activada:Esa cédula ya tiene una cuenta. Entra con tu PIN.';
  end if;

  if exists (select 1 from public.accounts where lower(correo) = v_correo) then
    raise exception 'bt:ya-activada:Ese correo ya está registrado. Entra con tu PIN.';
  end if;

  if v_propio then
    v_banco    := '';
    v_pago_tel := v_tel;
    v_pago_ced := v_cedula;
  else
    if length(v_banco) < 2 then
      raise exception 'bt:datos:Selecciona el banco de tu cuenta de Pago Móvil.';
    end if;

    if v_pago_tel !~ '^0\d{10}$' then
      raise exception 'bt:datos:El teléfono del Pago Móvil debe tener 11 dígitos.';
    end if;

    if v_pago_ced !~ '^[VE]-\d{6,8}$' then
      raise exception 'bt:datos:Escribe la cédula del titular de la cuenta de pago.';
    end if;
  end if;

  insert into public.accounts
    (nombres, apellidos, cedula, telefono, correo, pin_hash,
     pago_propio, pago_banco, pago_telefono, pago_cedula)
  values
    (v_nombres, v_apellidos, v_cedula, v_tel, v_correo,
     extensions.crypt(p_pin, extensions.gen_salt('bf', 10)),
     v_propio, v_banco, v_pago_tel, v_pago_ced)
  returning * into v_cuenta;

  delete from public.account_sessions where expira < now();

  insert into public.account_sessions (account_id)
  values (v_cuenta.id)
  returning token into v_token;

  return jsonb_build_object('token', v_token)
    || public.bt_billetera_json(v_cuenta);
end;
$$;

-- Entrar con cédula + PIN de la cuenta. 5 fallos dejan 5 minutos en espera.
create or replace function public.bt_entrar(p_cedula text, p_pin text)
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

  if v_cuenta.bloqueado_hasta is not null and v_cuenta.bloqueado_hasta > now() then
    raise exception 'bt:credenciales:Demasiados intentos fallidos. Espera % min o recupera tu PIN en atención al cliente.',
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

    if v_fallos >= 5 then
      return jsonb_build_object(
        'error', 'credenciales',
        'mensaje', 'Demasiados intentos fallidos. Espera 5 min o recupera tu PIN en atención al cliente.'
      );
    end if;

    return jsonb_build_object(
      'error', 'credenciales',
      'mensaje', 'El PIN no coincide. Inténtalo de nuevo.'
    );
  end if;

  update public.accounts
     set intentos = 0, bloqueado_hasta = null
   where id = v_cuenta.id;

  delete from public.account_sessions where expira < now();

  insert into public.account_sessions (account_id)
  values (v_cuenta.id)
  returning token into v_token;

  return jsonb_build_object('token', v_token)
    || public.bt_billetera_json(v_cuenta);
end;
$$;

create or replace function public.bt_sesion(p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta public.accounts := public.bt_sesion_cuenta(p_token);
begin
  return public.bt_billetera_json(v_cuenta);
end;
$$;

-- Vincular un plástico a la billetera con el serial del reverso.
create or replace function public.bt_vincular(p_token text, p_serial text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta  public.accounts := public.bt_sesion_cuenta(p_token);
  v_serial  text := trim(coalesce(p_serial, ''));
  v_tarjeta public.cards;
begin
  if v_serial !~ '^\d{2}-\d-\d{6}-\d$' or not public.bt_luhn_valido(v_serial) then
    raise exception 'bt:datos:El serial tiene 10 dígitos (ej. 23-1-000001-9).';
  end if;

  select * into v_tarjeta from public.cards where visible_id = v_serial for update;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos ese serial. Revisa el número impreso.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Esa tarjeta venció. Pasa por taquilla para renovarla.';
  end if;

  if v_tarjeta.status <> 'ACTIVE' then
    raise exception 'bt:bloqueada:Esa tarjeta está bloqueada. Comunícate con atención al cliente.';
  end if;

  if v_tarjeta.account_id = v_cuenta.id then
    raise exception 'bt:duplicada:Esa tarjeta ya está en tu billetera.';
  end if;

  if v_tarjeta.account_id is not null then
    raise exception 'bt:ya-activada:Esa tarjeta ya está vinculada a otra cuenta. Verifica el serial.';
  end if;

  update public.cards
     set account_id = v_cuenta.id,
         nombre     = v_cuenta.nombres || ' ' || v_cuenta.apellidos
   where id = v_tarjeta.id;

  return public.bt_billetera_json(v_cuenta);
end;
$$;

-- ------------------------------------------------------------
-- 6. Portal: extracto, recargas, PIN y datos de pago
-- ------------------------------------------------------------
drop function if exists public.bt_movimientos(text, int);

create or replace function public.bt_movimientos(
  p_token text, p_serial text, p_limite int default 100
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta  public.accounts := public.bt_sesion_cuenta(p_token);
  v_tarjeta public.cards := public.bt_tarjeta_de_cuenta(v_cuenta, p_serial);
  v_limite  int := least(greatest(coalesce(p_limite, 100), 1), 300);
  v_lista   jsonb;
begin
  select coalesce(jsonb_agg(
           public.bt_movimiento_json(m, v_tarjeta.visible_id) order by m.at desc
         ), '[]'::jsonb)
    into v_lista
    from (
      select *
        from public.card_movements
       where card_id = v_tarjeta.id
       order by at desc
       limit v_limite
    ) m;

  return jsonb_build_object('movimientos', v_lista);
end;
$$;

drop function if exists public.bt_recargar(text, numeric, text, text, text);

create or replace function public.bt_recargar(
  p_token text, p_serial text, p_monto numeric,
  p_telefono text, p_banco text, p_referencia text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta     public.accounts := public.bt_sesion_cuenta(p_token);
  v_tarjeta    public.cards := public.bt_tarjeta_de_cuenta(v_cuenta, p_serial);
  v_tope       numeric := public.bt_tope_recarga();
  v_monto      numeric := round(coalesce(p_monto, 0), 2);
  v_tel        text := public.bt_solo_digitos(p_telefono);
  v_banco      text := trim(coalesce(p_banco, ''));
  v_ref_dig    text := public.bt_solo_digitos(p_referencia);
  v_ref        text;
  v_movimiento public.card_movements;
  v_reportes   int;
begin
  if v_monto <= 0 then
    raise exception 'bt:pin-invalido:Escribe el monto que transferiste (mayor que 0).';
  end if;

  if v_monto <> coalesce(p_monto, 0) then
    raise exception 'bt:pin-invalido:Usa como máximo dos decimales.';
  end if;

  if v_monto < 1 then
    raise exception 'bt:pin-invalido:El monto mínimo por recarga es Bs 1,00.';
  end if;

  if v_monto > v_tope then
    raise exception 'bt:pin-invalido:El tope por recarga es % Bs. Divide el pago en varias operaciones.',
      trim(to_char(round(v_tope), 'FM999999999'));
  end if;

  if v_tel !~ '^0\d{10}$' then
    raise exception 'bt:pin-invalido:El teléfono debe tener 11 dígitos y empezar por 0 (ej. 0414-1234567).';
  end if;

  if length(v_banco) < 2 then
    raise exception 'bt:pin-invalido:Selecciona el banco emisor.';
  end if;

  if length(v_ref_dig) < 4 then
    raise exception 'bt:pin-invalido:Escribe los últimos 4 dígitos de la referencia.';
  end if;

  v_ref := right(v_ref_dig, 4);

  select count(*) into v_reportes
    from public.recharges
   where card_id = v_tarjeta.id
     and created_at > now() - interval '10 minutes';

  if v_reportes >= 6 then
    raise exception 'bt:duplicada:Demasiados reportes seguidos. Espera unos minutos antes de enviar otro.';
  end if;

  if exists (
    select 1
      from public.recharges
     where card_id = v_tarjeta.id
       and bank = v_banco
       and bank_reference = v_ref
       and status <> 'rechazado'
  ) then
    raise exception 'bt:duplicada:Ya reportaste esa referencia. Revisa Movimientos.';
  end if;

  insert into public.card_movements
    (card_id, tipo, monto, saldo_despues, detalle, estado, banco, referencia)
  values
    (v_tarjeta.id, 'recarga', v_monto, v_tarjeta.virtual_balance, 'Pago Móvil en revisión',
     'pendiente', v_banco, v_ref)
  returning * into v_movimiento;

  insert into public.recharges
    (card_id, movement_id, amount, sender_phone, bank, bank_reference, created_at)
  values
    (v_tarjeta.id, v_movimiento.id, v_monto, v_tel, v_banco, v_ref, v_movimiento.at);

  return jsonb_build_object(
    'movimiento', public.bt_movimiento_json(v_movimiento, v_tarjeta.visible_id)
  );
end;
$$;

create or replace function public.bt_cambiar_pin(p_token text, p_actual text, p_nuevo text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cuenta public.accounts := public.bt_sesion_cuenta(p_token);
begin
  if extensions.crypt(coalesce(p_actual, ''), v_cuenta.pin_hash) <> v_cuenta.pin_hash then
    raise exception 'bt:credenciales:El PIN actual no coincide.';
  end if;

  if not public.bt_pin6_valido(p_nuevo) then
    raise exception 'bt:pin-invalido:Elige 6 dígitos, sin repetir el mismo ni secuencias como 123456.';
  end if;

  if p_nuevo = p_actual then
    raise exception 'bt:pin-invalido:El PIN nuevo debe ser distinto al actual.';
  end if;

  update public.accounts
     set pin_hash = extensions.crypt(p_nuevo, extensions.gen_salt('bf', 10)),
         intentos = 0,
         bloqueado_hasta = null
   where id = v_cuenta.id;

  return jsonb_build_object('ok', true);
end;
$$;

-- La fuente de Pago Móvil puede ser la del registro o la de un familiar.
create or replace function public.bt_actualizar_pago(
  p_token text,
  p_propio boolean,
  p_banco text default '',
  p_telefono text default '',
  p_cedula text default ''
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cuenta   public.accounts := public.bt_sesion_cuenta(p_token);
  v_propio   boolean := coalesce(p_propio, true);
  v_banco    text := trim(coalesce(p_banco, ''));
  v_telefono text := public.bt_solo_digitos(p_telefono);
  v_cedula   text := upper(trim(coalesce(p_cedula, '')));
begin
  if v_propio then
    v_banco    := '';
    v_telefono := v_cuenta.telefono;
    v_cedula   := v_cuenta.cedula;
  else
    if length(v_banco) < 2 then
      raise exception 'bt:datos:Selecciona el banco de tu cuenta de Pago Móvil.';
    end if;

    if v_telefono !~ '^0\d{10}$' then
      raise exception 'bt:datos:El teléfono del Pago Móvil debe tener 11 dígitos.';
    end if;

    if v_cedula !~ '^[VE]-\d{6,8}$' then
      raise exception 'bt:datos:Escribe la cédula del titular de la cuenta de pago.';
    end if;
  end if;

  update public.accounts
     set pago_propio   = v_propio,
         pago_banco    = v_banco,
         pago_telefono = v_telefono,
         pago_cedula   = v_cedula
   where id = v_cuenta.id
  returning * into v_cuenta;

  return jsonb_build_object('cuenta', public.bt_cuenta_json(v_cuenta));
end;
$$;

create or replace function public.bt_salir(p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_token ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    delete from public.account_sessions where token = p_token::uuid;
    delete from public.card_sessions where token = p_token::uuid;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 7. Permisos
-- ------------------------------------------------------------
revoke all on table public.accounts from anon, authenticated;
revoke all on table public.account_sessions from anon, authenticated;

revoke all on function public.bt_pin6_valido(text)                     from public, anon, authenticated;
revoke all on function public.bt_cuenta_json(public.accounts)          from public, anon, authenticated;
revoke all on function public.bt_tarjeta_cuenta_json(public.cards, public.accounts) from public, anon, authenticated;
revoke all on function public.bt_billetera_json(public.accounts)       from public, anon, authenticated;
revoke all on function public.bt_tarjeta_de_cuenta(public.accounts, text) from public, anon, authenticated;
revoke all on function public.bt_sesion_cuenta(text)                   from public, anon, authenticated;

revoke all on function public.bt_registrar(text, text, text, text, text, text, boolean, text, text, text) from public, anon, authenticated;
revoke all on function public.bt_entrar(text, text)                    from public, anon, authenticated;
revoke all on function public.bt_sesion(text)                          from public, anon, authenticated;
revoke all on function public.bt_vincular(text, text)                  from public, anon, authenticated;
revoke all on function public.bt_movimientos(text, text, int)          from public, anon, authenticated;
revoke all on function public.bt_recargar(text, text, numeric, text, text, text) from public, anon, authenticated;
revoke all on function public.bt_cambiar_pin(text, text, text)         from public, anon, authenticated;
revoke all on function public.bt_actualizar_pago(text, boolean, text, text, text) from public, anon, authenticated;
revoke all on function public.bt_salir(text)                           from public, anon, authenticated;

grant execute on function public.bt_registrar(text, text, text, text, text, text, boolean, text, text, text) to anon, authenticated;
grant execute on function public.bt_entrar(text, text)                 to anon, authenticated;
grant execute on function public.bt_sesion(text)                       to anon, authenticated;
grant execute on function public.bt_vincular(text, text)               to anon, authenticated;
grant execute on function public.bt_movimientos(text, text, int)       to anon, authenticated;
grant execute on function public.bt_recargar(text, text, numeric, text, text, text) to anon, authenticated;
grant execute on function public.bt_cambiar_pin(text, text, text)      to anon, authenticated;
grant execute on function public.bt_actualizar_pago(text, boolean, text, text, text) to anon, authenticated;
grant execute on function public.bt_salir(text)                        to anon, authenticated;

-- La billetera en la nube arranca sin cuentas: cada pasajero se
-- registra desde el portal y vincula sus plásticos por serial.
