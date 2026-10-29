-- ============================================================
-- BLINK TARJETA · esquema de la tarjeta recargable
-- Pegar completo en el SQL Editor del proyecto Supabase
-- (gakkfzqcrapxeierfdhk) y ejecutar una sola vez.
--
-- Todo el acceso pasa por funciones RPC `bt_*` con SECURITY DEFINER:
-- las tablas tienen RLS activado y sin políticas, así que la llave
-- pública del navegador no puede leer ni escribir nada por su cuenta.
-- ============================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------
-- 1. Ajustes públicos (datos de Pago Móvil, topes, atención)
-- ------------------------------------------------------------
create table if not exists public.bt_ajustes (
  clave      text primary key,
  valor      jsonb not null,
  actualizada timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. Tarjetas
-- ------------------------------------------------------------
create table if not exists public.bt_tarjetas (
  id              uuid primary key default gen_random_uuid(),
  serial          text not null unique check (serial ~ '^\d{2}-\d-\d{7}-\d$'),
  uid             text unique,
  nombre          text not null default 'Titular',
  cedula          text not null,
  cedula_digitos  text generated always as (regexp_replace(cedula, '\D', '', 'g')) stored,
  telefono        text not null default '',
  saldo           numeric(12,2) not null default 0 check (saldo >= 0),
  tarifa          numeric(12,2) not null default 15 check (tarifa > 0),
  estado          text not null default 'activa' check (estado in ('activa', 'bloqueada')),
  emitida         timestamptz not null default now(),
  vence           timestamptz not null default now() + interval '5 years',
  pin_hash        text,
  intentos        int not null default 0,
  bloqueado_hasta timestamptz,
  creada          timestamptz not null default now(),
  actualizada     timestamptz not null default now()
);

create unique index if not exists bt_tarjetas_cedula_idx
  on public.bt_tarjetas (cedula_digitos);

-- Un plástico vencido no se puede usar, aunque siga en la base.
create or replace function public.bt_tarjeta_vigente(t public.bt_tarjetas)
returns boolean language sql stable as $$
  select t.vence > now();
$$;

-- ------------------------------------------------------------
-- 3. Movimientos (el extracto que ve el pasajero)
-- ------------------------------------------------------------
create table if not exists public.bt_movimientos (
  id            uuid primary key default gen_random_uuid(),
  tarjeta_id    uuid not null references public.bt_tarjetas(id) on delete cascade,
  tipo          text not null check (tipo in ('recarga', 'viaje', 'devolucion', 'ajuste')),
  monto         numeric(12,2) not null,
  saldo_despues numeric(12,2) not null,
  detalle       text not null,
  estado        text not null default 'aprobado'
                check (estado in ('aprobado', 'pendiente', 'rechazado')),
  unidad        text,
  banco         text,
  referencia    text,
  at            timestamptz not null default now()
);

create index if not exists bt_movimientos_tarjeta_idx
  on public.bt_movimientos (tarjeta_id, at desc);

-- ------------------------------------------------------------
-- 4. Recargas reportadas por Pago Móvil
-- ------------------------------------------------------------
create table if not exists public.bt_recargas (
  id            uuid primary key default gen_random_uuid(),
  tarjeta_id    uuid not null references public.bt_tarjetas(id) on delete cascade,
  movimiento_id uuid not null references public.bt_movimientos(id) on delete cascade,
  monto         numeric(12,2) not null check (monto > 0),
  telefono      text not null,
  banco         text not null,
  referencia    text not null check (referencia ~ '^\d{4}$'),
  estado        text not null default 'pendiente'
                check (estado in ('pendiente', 'aprobado', 'rechazado')),
  reportada     timestamptz not null default now(),
  resuelta      timestamptz,
  resuelta_por  text
);

-- La misma referencia del mismo banco no puede estar dos veces vigente.
create unique index if not exists bt_recargas_unica_idx
  on public.bt_recargas (tarjeta_id, banco, referencia)
  where estado <> 'rechazado';

create index if not exists bt_recargas_pendientes_idx
  on public.bt_recargas (estado, reportada desc);

-- ------------------------------------------------------------
-- 5. Sesiones (token que guarda la app por 12 horas)
-- ------------------------------------------------------------
create table if not exists public.bt_sesiones (
  token      uuid primary key default gen_random_uuid(),
  tarjeta_id uuid not null references public.bt_tarjetas(id) on delete cascade,
  creada     timestamptz not null default now(),
  expira     timestamptz not null default now() + interval '12 hours'
);

create index if not exists bt_sesiones_expira_idx on public.bt_sesiones (expira);

-- ------------------------------------------------------------
-- 6. Utilidades internas
-- ------------------------------------------------------------
create or replace function public.bt_solo_digitos(p_texto text)
returns text language sql immutable as $$
  select regexp_replace(coalesce(p_texto, ''), '\D', '', 'g');
$$;

-- Mismo criterio que la app: 4 dígitos, sin repeticiones ni secuencias.
create or replace function public.bt_pin_valido(p_pin text)
returns boolean language sql immutable as $$
  select p_pin ~ '^\d{4}$'
     and p_pin !~ '^(\d)\1{3}$'
     and p_pin not in (
       '0123', '1234', '2345', '3456', '4567', '5678', '6789',
       '9876', '8765', '7654', '6543', '5432', '4321', '3210'
     );
$$;

create or replace function public.bt_tarjeta_json(t public.bt_tarjetas)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'serial',  t.serial,
    'uid',     coalesce(t.uid, ''),
    'titular', jsonb_build_object(
                 'nombre',   t.nombre,
                 'cedula',   t.cedula,
                 'telefono', t.telefono),
    'saldo',   t.saldo,
    'estado',  t.estado,
    'emitida', t.emitida,
    'vence',   t.vence,
    'tarifa',  t.tarifa
  );
$$;

create or replace function public.bt_movimiento_json(m public.bt_movimientos, p_serial text)
returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id',           m.id,
    'serial',       p_serial,
    'tipo',         m.tipo,
    'monto',        m.monto,
    'saldoDespues', m.saldo_despues,
    'at',           m.at,
    'detalle',      m.detalle,
    'estado',       m.estado,
    'unidad',       m.unidad,
    'banco',        m.banco,
    'referencia',   m.referencia
  ));
$$;

-- Devuelve la tarjeta de una sesión válida o lanza el error del dominio.
create or replace function public.bt_sesion_tarjeta(p_token text)
returns public.bt_tarjetas
language plpgsql stable security definer set search_path = public as $$
declare
  v_tarjeta public.bt_tarjetas;
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    raise exception 'bt:sesion:La sesión expiró. Vuelve a entrar con tu PIN.';
  end if;

  select t.* into v_tarjeta
    from public.bt_sesiones s
    join public.bt_tarjetas t on t.id = s.tarjeta_id
   where s.token = p_token::uuid
     and s.expira > now();

  if not found then
    raise exception 'bt:sesion:La sesión expiró. Vuelve a entrar con tu PIN.';
  end if;

  if v_tarjeta.estado = 'bloqueada' then
    raise exception 'bt:bloqueada:Tu tarjeta está bloqueada. Comunícate con atención al cliente.';
  end if;

  return v_tarjeta;
end;
$$;

-- Tope de recarga por operación, publicado por Admin.
create or replace function public.bt_tope_recarga()
returns numeric language sql stable as $$
  select coalesce(
    (select (valor ->> 'topeRecarga')::numeric
       from public.bt_ajustes where clave = 'publico'),
    5000
  );
$$;

create or replace function public.bt_tocar_actualizada()
returns trigger language plpgsql as $$
begin
  new.actualizada := now();
  return new;
end;
$$;

drop trigger if exists bt_tarjetas_actualizada on public.bt_tarjetas;
create trigger bt_tarjetas_actualizada
  before update on public.bt_tarjetas
  for each row execute function public.bt_tocar_actualizada();

-- ------------------------------------------------------------
-- 7. RPC públicas (las llama la app del pasajero)
-- ------------------------------------------------------------

-- Entrar con cédula + PIN. 5 fallos dejan la tarjeta 5 minutos en espera.
--
-- Ojo: el fallo de PIN se devuelve como {'error','mensaje'} y no con RAISE.
-- RAISE revierte la transacción y con ella el contador de intentos, así que
-- el bloqueo nunca se guardaría. El resto de errores sí abortan la llamada.
create or replace function public.bt_entrar(p_cedula text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_tarjeta public.bt_tarjetas;
  v_token   uuid;
  v_fallos  int;
begin
  if length(v_digitos) < 6 or length(v_digitos) > 8 then
    raise exception 'bt:sin-tarjeta:No encontramos una tarjeta con esa cédula.';
  end if;

  select * into v_tarjeta
    from public.bt_tarjetas
   where cedula_digitos = v_digitos;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos una tarjeta con esa cédula.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Tu tarjeta venció. Pasa por taquilla para renovarla.';
  end if;

  if v_tarjeta.bloqueado_hasta is not null and v_tarjeta.bloqueado_hasta > now() then
    raise exception 'bt:credenciales:Demasiados intentos fallidos. Espera % min o recupera tu PIN en atención al cliente.',
      greatest(1, ceil(extract(epoch from (v_tarjeta.bloqueado_hasta - now())) / 60)::int);
  end if;

  if v_tarjeta.pin_hash is null then
    raise exception 'bt:sin-tarjeta:Tu tarjeta todavía no tiene PIN. Actívala primero.';
  end if;

  if v_tarjeta.estado = 'bloqueada' then
    raise exception 'bt:bloqueada:Tu tarjeta está bloqueada. Comunícate con atención al cliente.';
  end if;

  if crypt(coalesce(p_pin, ''), v_tarjeta.pin_hash) <> v_tarjeta.pin_hash then
    v_fallos := case
      when v_tarjeta.bloqueado_hasta is not null and v_tarjeta.bloqueado_hasta <= now() then 1
      else v_tarjeta.intentos + 1
    end;

    update public.bt_tarjetas
       set intentos = v_fallos,
           bloqueado_hasta = case when v_fallos >= 5 then now() + interval '5 minutes' end
     where id = v_tarjeta.id;

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

  update public.bt_tarjetas
     set intentos = 0, bloqueado_hasta = null
   where id = v_tarjeta.id;

  delete from public.bt_sesiones where expira < now();

  insert into public.bt_sesiones (tarjeta_id, expira)
  values (v_tarjeta.id, now() + interval '12 hours')
  returning token into v_token;

  return jsonb_build_object(
    'token', v_token,
    'tarjeta', public.bt_tarjeta_json(v_tarjeta)
  );
end;
$$;

-- Activar el plástico: vincula cédula, teléfono y PIN a un serial emitido.
create or replace function public.bt_activar(
  p_cedula text, p_serial text, p_telefono text, p_pin text
)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_digitos text := public.bt_solo_digitos(p_cedula);
  v_serial  text := trim(coalesce(p_serial, ''));
  v_tel     text := public.bt_solo_digitos(p_telefono);
  v_tarjeta public.bt_tarjetas;
  v_token   uuid;
begin
  if length(v_digitos) < 6 or length(v_digitos) > 8 then
    raise exception 'bt:sin-tarjeta:Revisa la cédula: debe tener entre 6 y 8 dígitos.';
  end if;

  if not public.bt_pin_valido(p_pin) then
    raise exception 'bt:pin-invalido:Usa 4 dígitos, sin repeticiones ni secuencias como 1234.';
  end if;

  if v_tel !~ '^0\d{10}$' then
    raise exception 'bt:pin-invalido:El teléfono debe tener 11 dígitos y empezar por 0 (ej. 0414-1234567).';
  end if;

  if exists (
    select 1
      from public.bt_tarjetas
     where cedula_digitos = v_digitos
       and serial <> v_serial
  ) then
    raise exception 'bt:ya-activada:Esa cédula ya tiene una tarjeta activa. Entra con tu PIN.';
  end if;

  select * into v_tarjeta from public.bt_tarjetas where serial = v_serial;

  if not found then
    raise exception 'bt:sin-tarjeta:No encontramos ese serial. Revisa el número impreso en la tarjeta.';
  end if;

  if v_tarjeta.pin_hash is not null then
    raise exception 'bt:ya-activada:Esa tarjeta ya fue activada. Si no reconoces el cobro, llama a atención al cliente.';
  end if;

  if not public.bt_tarjeta_vigente(v_tarjeta) then
    raise exception 'bt:sin-tarjeta:Esa tarjeta venció. Pasa por taquilla para renovarla.';
  end if;

  update public.bt_tarjetas
     set cedula   = upper(trim(p_cedula)),
         telefono = v_tel,
         pin_hash = crypt(p_pin, gen_salt('bf', 10)),
         estado   = 'activa',
         intentos = 0,
         bloqueado_hasta = null
   where id = v_tarjeta.id
  returning * into v_tarjeta;

  insert into public.bt_sesiones (tarjeta_id, expira)
  values (v_tarjeta.id, now() + interval '12 hours')
  returning token into v_token;

  return jsonb_build_object(
    'token', v_token,
    'tarjeta', public.bt_tarjeta_json(v_tarjeta)
  );
end;
$$;

create or replace function public.bt_tarjeta(p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.bt_tarjetas := public.bt_sesion_tarjeta(p_token);
begin
  return jsonb_build_object('tarjeta', public.bt_tarjeta_json(v_tarjeta));
end;
$$;

create or replace function public.bt_movimientos(p_token text, p_limite int default 100)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.bt_tarjetas := public.bt_sesion_tarjeta(p_token);
  v_limite  int := least(greatest(coalesce(p_limite, 100), 1), 300);
  v_lista   jsonb;
begin
  select coalesce(jsonb_agg(
           public.bt_movimiento_json(m, v_tarjeta.serial) order by m.at desc
         ), '[]'::jsonb)
    into v_lista
    from (
      select *
        from public.bt_movimientos
       where tarjeta_id = v_tarjeta.id
       order by at desc
       limit v_limite
    ) m;

  return jsonb_build_object('movimientos', v_lista);
end;
$$;

-- Reportar un Pago Móvil: queda pendiente hasta que Admin confirme.
create or replace function public.bt_recargar(
  p_token text, p_monto numeric, p_telefono text, p_banco text, p_referencia text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta    public.bt_tarjetas := public.bt_sesion_tarjeta(p_token);
  v_tope       numeric := public.bt_tope_recarga();
  v_monto      numeric := round(coalesce(p_monto, 0), 2);
  v_tel        text := public.bt_solo_digitos(p_telefono);
  v_banco      text := trim(coalesce(p_banco, ''));
  v_ref_dig    text := public.bt_solo_digitos(p_referencia);
  v_ref        text;
  v_movimiento public.bt_movimientos;
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
    from public.bt_recargas
   where tarjeta_id = v_tarjeta.id
     and reportada > now() - interval '10 minutes';

  if v_reportes >= 6 then
    raise exception 'bt:duplicada:Demasiados reportes seguidos. Espera unos minutos antes de enviar otro.';
  end if;

  if exists (
    select 1
      from public.bt_recargas
     where tarjeta_id = v_tarjeta.id
       and banco = v_banco
       and referencia = v_ref
       and estado <> 'rechazado'
  ) then
    raise exception 'bt:duplicada:Ya reportaste esa referencia. Revisa Movimientos.';
  end if;

  insert into public.bt_movimientos
    (tarjeta_id, tipo, monto, saldo_despues, detalle, estado, banco, referencia)
  values
    (v_tarjeta.id, 'recarga', v_monto, v_tarjeta.saldo, 'Pago Móvil en revisión', 'pendiente', v_banco, v_ref)
  returning * into v_movimiento;

  insert into public.bt_recargas
    (tarjeta_id, movimiento_id, monto, telefono, banco, referencia)
  values
    (v_tarjeta.id, v_movimiento.id, v_monto, v_tel, v_banco, v_ref);

  return jsonb_build_object(
    'movimiento', public.bt_movimiento_json(v_movimiento, v_tarjeta.serial)
  );
end;
$$;

create or replace function public.bt_cambiar_pin(p_token text, p_actual text, p_nuevo text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tarjeta public.bt_tarjetas := public.bt_sesion_tarjeta(p_token);
begin
  if v_tarjeta.pin_hash is null
     or crypt(coalesce(p_actual, ''), v_tarjeta.pin_hash) <> v_tarjeta.pin_hash then
    raise exception 'bt:credenciales:El PIN actual no coincide.';
  end if;

  if not public.bt_pin_valido(p_nuevo) then
    raise exception 'bt:pin-invalido:Usa 4 dígitos, sin repeticiones ni secuencias como 1234.';
  end if;

  if p_nuevo = p_actual then
    raise exception 'bt:pin-invalido:El PIN nuevo debe ser distinto al actual.';
  end if;

  update public.bt_tarjetas
     set pin_hash = crypt(p_nuevo, gen_salt('bf', 10)),
         intentos = 0,
         bloqueado_hasta = null
   where id = v_tarjeta.id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bt_salir(p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_token ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    delete from public.bt_sesiones where token = p_token::uuid;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bt_ajustes()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_valor jsonb;
begin
  select valor into v_valor from public.bt_ajustes where clave = 'publico';

  return coalesce(v_valor, jsonb_build_object(
    'pagoMovil', jsonb_build_object(
      'banco', 'Banesco',
      'rif', 'J-00000000-0',
      'telefono', '0414-0000000',
      'titular', 'BLINK PASAJES, C.A.'),
    'topeRecarga', 5000,
    'atencion', '0800-BLINK-00'
  ));
end;
$$;

-- ------------------------------------------------------------
-- 8. RPC de operación (solo service_role: taquilla, lector y admin)
-- ------------------------------------------------------------

-- Emite un plástico sin PIN: queda listo para que el pasajero lo active.
create or replace function public.bt_emitir_tarjeta(
  p_serial text, p_nombre text, p_cedula text,
  p_telefono text default '', p_tarifa numeric default 15
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta public.bt_tarjetas;
begin
  if coalesce(trim(p_serial), '') !~ '^\d{2}-\d-\d{7}-\d$' then
    raise exception 'El serial debe tener el formato 23-1-0000001-0.';
  end if;

  insert into public.bt_tarjetas (serial, nombre, cedula, telefono, tarifa, pin_hash)
  values (trim(p_serial), coalesce(nullif(trim(p_nombre), ''), 'Titular'),
          trim(p_cedula), public.bt_solo_digitos(p_telefono), p_tarifa, null)
  returning * into v_tarjeta;

  return public.bt_tarjeta_json(v_tarjeta);
end;
$$;

-- Cobra un pasaje. Lo llama el lector (POS) al validar el chip.
create or replace function public.bt_cobrar_viaje(
  p_serial text, p_unidad text default null, p_monto numeric default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tarjeta    public.bt_tarjetas;
  v_monto      numeric;
  v_saldo      numeric;
  v_movimiento public.bt_movimientos;
begin
  select * into v_tarjeta
    from public.bt_tarjetas
   where serial = trim(coalesce(p_serial, ''))
     for update;

  if not found then
    raise exception 'Tarjeta desconocida.';
  end if;

  if v_tarjeta.estado <> 'activa' then
    raise exception 'Tarjeta bloqueada.';
  end if;

  v_monto := coalesce(p_monto, v_tarjeta.tarifa);

  if v_monto <= 0 then
    raise exception 'Monto inválido.';
  end if;

  if v_tarjeta.saldo < v_monto then
    raise exception 'Saldo insuficiente.';
  end if;

  v_saldo := v_tarjeta.saldo - v_monto;

  update public.bt_tarjetas set saldo = v_saldo where id = v_tarjeta.id;

  insert into public.bt_movimientos
    (tarjeta_id, tipo, monto, saldo_despues, detalle, estado, unidad)
  values
    (v_tarjeta.id, 'viaje', -v_monto, v_saldo, 'Pasaje en la línea', 'aprobado',
     nullif(trim(coalesce(p_unidad, '')), ''))
  returning * into v_movimiento;

  return jsonb_build_object(
    'movimiento', public.bt_movimiento_json(v_movimiento, v_tarjeta.serial),
    'saldo', v_saldo,
    'titular', v_tarjeta.nombre
  );
end;
$$;

create or replace function public.bt_aprobar_recarga(p_recarga uuid, p_admin text default 'admin')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_recarga  public.bt_recargas;
  v_saldo    numeric;
begin
  select * into v_recarga from public.bt_recargas where id = p_recarga for update;

  if not found then
    raise exception 'Recarga no encontrada.';
  end if;

  if v_recarga.estado <> 'pendiente' then
    raise exception 'Esa recarga ya fue %.', v_recarga.estado;
  end if;

  update public.bt_tarjetas
     set saldo = saldo + v_recarga.monto
   where id = v_recarga.tarjeta_id
  returning saldo into v_saldo;

  update public.bt_movimientos
     set estado = 'aprobado',
         saldo_despues = v_saldo,
         detalle = 'Pago Móvil aprobado'
   where id = v_recarga.movimiento_id;

  update public.bt_recargas
     set estado = 'aprobado', resuelta = now(), resuelta_por = p_admin
   where id = v_recarga.id;

  return jsonb_build_object('ok', true, 'saldo', v_saldo);
end;
$$;

create or replace function public.bt_rechazar_recarga(
  p_recarga uuid, p_admin text default 'admin', p_motivo text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_recarga public.bt_recargas;
begin
  select * into v_recarga from public.bt_recargas where id = p_recarga for update;

  if not found then
    raise exception 'Recarga no encontrada.';
  end if;

  if v_recarga.estado <> 'pendiente' then
    raise exception 'Esa recarga ya fue %.', v_recarga.estado;
  end if;

  update public.bt_movimientos
     set estado = 'rechazado',
         detalle = coalesce(nullif(trim(p_motivo), ''), 'Pago Móvil rechazado')
   where id = v_recarga.movimiento_id;

  update public.bt_recargas
     set estado = 'rechazado', resuelta = now(), resuelta_por = p_admin
   where id = v_recarga.id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bt_bloquear_tarjeta(p_serial text, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.bt_tarjetas
     set estado = 'bloqueada'
   where serial = trim(coalesce(p_serial, ''));

  if not found then
    raise exception 'Tarjeta desconocida.';
  end if;

  delete from public.bt_sesiones
   where tarjeta_id = (select id from public.bt_tarjetas where serial = trim(p_serial));

  return jsonb_build_object('ok', true, 'motivo', p_motivo);
end;
$$;

create or replace function public.bt_desbloquear_tarjeta(p_serial text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.bt_tarjetas
     set estado = 'activa', intentos = 0, bloqueado_hasta = null
   where serial = trim(coalesce(p_serial, ''));

  if not found then
    raise exception 'Tarjeta desconocida.';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Bandeja de recargas para el panel de Admin.
create or replace function public.bt_recargas_pendientes(p_limite int default 100)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_lista jsonb;
begin
  select coalesce(jsonb_agg(fila order by fila ->> 'reportada' desc), '[]'::jsonb)
    into v_lista
    from (
      select jsonb_build_object(
               'recarga', r.id,
               'movimiento', r.movimiento_id,
               'serial', t.serial,
               'titular', t.nombre,
               'cedula', t.cedula,
               'monto', r.monto,
               'telefono', r.telefono,
               'banco', r.banco,
               'referencia', r.referencia,
               'estado', r.estado,
               'reportada', r.reportada
             ) as fila
        from public.bt_recargas r
        join public.bt_tarjetas t on t.id = r.tarjeta_id
       where r.estado = 'pendiente'
       order by r.reportada asc
       limit least(greatest(coalesce(p_limite, 100), 1), 500)
    ) pendientes;

  return jsonb_build_object('recargas', v_lista);
end;
$$;

-- ------------------------------------------------------------
-- 9. Seguridad: RLS cerrado, sin políticas directas
-- ------------------------------------------------------------
alter table public.bt_tarjetas    enable row level security;
alter table public.bt_movimientos enable row level security;
alter table public.bt_recargas    enable row level security;
alter table public.bt_sesiones    enable row level security;
alter table public.bt_ajustes     enable row level security;

revoke all on public.bt_tarjetas    from anon, authenticated;
revoke all on public.bt_movimientos from anon, authenticated;
revoke all on public.bt_recargas    from anon, authenticated;
revoke all on public.bt_sesiones    from anon, authenticated;
revoke all on public.bt_ajustes     from anon, authenticated;

revoke all on function public.bt_solo_digitos(text)               from public;
revoke all on function public.bt_pin_valido(text)                 from public;
revoke all on function public.bt_tarjeta_vigente(public.bt_tarjetas) from public;
revoke all on function public.bt_tarjeta_json(public.bt_tarjetas) from public;
revoke all on function public.bt_movimiento_json(public.bt_movimientos, text) from public;
revoke all on function public.bt_sesion_tarjeta(text)             from public;
revoke all on function public.bt_tope_recarga()                   from public;
revoke all on function public.bt_tocar_actualizada()              from public;

-- Las que usa el navegador con la llave pública.
grant execute on function public.bt_entrar(text, text)                              to anon, authenticated;
grant execute on function public.bt_activar(text, text, text, text)                 to anon, authenticated;
grant execute on function public.bt_tarjeta(text)                                   to anon, authenticated;
grant execute on function public.bt_movimientos(text, int)                          to anon, authenticated;
grant execute on function public.bt_recargar(text, numeric, text, text, text)       to anon, authenticated;
grant execute on function public.bt_cambiar_pin(text, text, text)                   to anon, authenticated;
grant execute on function public.bt_salir(text)                                     to anon, authenticated;
grant execute on function public.bt_ajustes()                                       to anon, authenticated;

-- Solo el backend (service_role): taquilla, lector y panel.
revoke all on function public.bt_emitir_tarjeta(text, text, text, text, numeric) from public;
revoke all on function public.bt_cobrar_viaje(text, text, numeric)               from public;
revoke all on function public.bt_aprobar_recarga(uuid, text)                     from public;
revoke all on function public.bt_rechazar_recarga(uuid, text, text)              from public;
revoke all on function public.bt_bloquear_tarjeta(text, text)                    from public;
revoke all on function public.bt_desbloquear_tarjeta(text)                       from public;
revoke all on function public.bt_recargas_pendientes(int)                        from public;

grant execute on function public.bt_emitir_tarjeta(text, text, text, text, numeric) to service_role;
grant execute on function public.bt_cobrar_viaje(text, text, numeric)               to service_role;
grant execute on function public.bt_aprobar_recarga(uuid, text)                     to service_role;
grant execute on function public.bt_rechazar_recarga(uuid, text, text)              to service_role;
grant execute on function public.bt_bloquear_tarjeta(text, text)                    to service_role;
grant execute on function public.bt_desbloquear_tarjeta(text)                       to service_role;
grant execute on function public.bt_recargas_pendientes(int)                        to service_role;

-- ------------------------------------------------------------
-- 10. Ajustes iniciales (Admin los edita en la tabla bt_ajustes)
-- ------------------------------------------------------------
insert into public.bt_ajustes (clave, valor)
values ('publico', jsonb_build_object(
  'pagoMovil', jsonb_build_object(
    'banco', 'Banesco',
    'rif', 'J-00000000-0',
    'telefono', '0414-0000000',
    'titular', 'BLINK PASAJES, C.A.'),
  'topeRecarga', 5000,
  'atencion', '0800-BLINK-00'
))
on conflict (clave) do nothing;
