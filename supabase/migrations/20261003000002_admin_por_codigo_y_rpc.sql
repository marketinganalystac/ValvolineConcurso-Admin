-- Administrador por código (hash bcrypt en el servidor) + funciones RPC de lectura/escritura

create extension if not exists pgcrypto with schema extensions;
create schema if not exists privado;

create table public.admin_config (
  id int primary key default 1 check (id = 1),
  codigo_hash text not null,
  actualizado_en timestamptz not null default now()
);
create table public.admin_sesiones (
  token_hash text primary key,
  expira timestamptz not null,
  creado_en timestamptz not null default now()
);
create table public.admin_intentos (
  id bigint generated always as identity primary key,
  creado_en timestamptz not null default now()
);
create table public.codigos_descripcion (
  concurso_id uuid not null references public.concursos(id) on delete cascade,
  codigo text not null,
  descripcion text,
  primary key (concurso_id, codigo)
);
alter table public.admin_config enable row level security;
alter table public.admin_sesiones enable row level security;
alter table public.admin_intentos enable row level security;
alter table public.codigos_descripcion enable row level security;

alter table public.ventas drop constraint ventas_mes_check;
alter table public.ventas add constraint ventas_mes_check check (mes ~ '^(\d{4}-\d{2})?$');

create function privado.token_ok(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_token is not null and exists (
    select 1 from public.admin_sesiones
    where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') and expira > now());
$$;
revoke all on function privado.token_ok(text) from public, anon, authenticated;

-- Activar admin: verifica el código en el servidor; devuelve un token de 12 h (o null si es incorrecto).
-- 5 intentos fallidos en 15 min bloquean nuevos intentos.
create function public.admin_activar(p_codigo text) returns text
language plpgsql security definer set search_path = '' as $$
declare h text; fallos int; tok text;
begin
  delete from public.admin_intentos where creado_en < now() - interval '1 day';
  select count(*) into fallos from public.admin_intentos where creado_en > now() - interval '15 minutes';
  if fallos >= 5 then raise exception 'BLOQUEADO'; end if;
  select codigo_hash into h from public.admin_config where id = 1;
  if h is null or p_codigo is null or h <> extensions.crypt(p_codigo, h) then
    insert into public.admin_intentos default values;
    return null;
  end if;
  delete from public.admin_intentos where true;
  delete from public.admin_sesiones where expira < now();
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.admin_sesiones (token_hash, expira)
    values (encode(extensions.digest(tok, 'sha256'), 'hex'), now() + interval '12 hours');
  return tok;
end $$;

create function public.admin_cerrar(p_token text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.admin_sesiones where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
end $$;

create function public.admin_cambiar_codigo(p_token text, p_nuevo text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not privado.token_ok(p_token) then raise exception 'SESION_INVALIDA'; end if;
  if p_nuevo is null or char_length(p_nuevo) <> 8 then raise exception 'CODIGO_INVALIDO'; end if;
  update public.admin_config set codigo_hash = extensions.crypt(p_nuevo, extensions.gen_salt('bf', 10)), actualizado_en = now() where id = 1;
  delete from public.admin_sesiones where token_hash <> encode(extensions.digest(p_token, 'sha256'), 'hex');
end $$;

-- Lectura pública (modo viewer)
create function public.datos_concurso(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.concursos;
begin
  select * into c from public.concursos where slug = p_slug;
  if not found then return null; end if;
  return jsonb_build_object(
    'concurso', jsonb_build_object('meta_global', c.meta_global, 'meses', c.meses, 'inicio', c.inicio, 'exigir_ambos', c.exigir_ambos,
      'fecha_corte', c.fecha_corte, 'sup_n', c.supervisor_nombre, 'sup_inc', c.supervisor_incentivo, 'sup_acum', c.supervisor_acumulado),
    'vendedores', coalesce((select jsonb_agg(jsonb_build_array(v.nombre, v.zona, v.promedio_gal, v.meta_gal, v.meta_clientes, v.incentivo, v.acumulado) order by v.orden, v.nombre)
      from public.vendedores v where v.concurso_id = c.id), '[]'::jsonb),
    'mercados', coalesce((select jsonb_object_agg(m.mercado, m.elegible) from public.mercados_elegibles m where m.concurso_id = c.id), '{}'::jsonb),
    'familias', coalesce((select jsonb_object_agg(f.familia, f.activa) from public.familias f where f.concurso_id = c.id), '{}'::jsonb),
    'conversion', coalesce((select jsonb_agg(jsonb_build_array(x.codigo, coalesce(x.descripcion, ''), x.multiplicador))
      from public.conversion x where x.concurso_id = c.id), '[]'::jsonb),
    'desc', coalesce((select jsonb_object_agg(d.codigo, coalesce(d.descripcion, '')) from public.codigos_descripcion d where d.concurso_id = c.id), '{}'::jsonb),
    'clientes', coalesce((select jsonb_agg(jsonb_build_array(k.id_cliente, coalesce(k.empresa, ''), coalesce(k.vendedor, ''), coalesce(k.tipo_socio, ''), coalesce(k.mercado, '')))
      from public.clientes k), '[]'::jsonb),
    'ventas', coalesce((select jsonb_agg(jsonb_build_array(s.mes, coalesce(s.id_cliente, ''), coalesce(s.empresa, ''), s.codigo, s.vendedor, s.cantidad, s.venta_usd))
      from public.ventas s where s.concurso_id = c.id), '[]'::jsonb)
  );
end $$;

-- Escritura: todas exigen token de admin vigente
create function public.guardar_config(p_token text, p_slug text, p_cfg jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare cid uuid;
begin
  if not privado.token_ok(p_token) then raise exception 'SESION_INVALIDA'; end if;
  select id into cid from public.concursos where slug = p_slug;
  if cid is null then raise exception 'CONCURSO_NO_EXISTE'; end if;
  update public.concursos set
    inicio = coalesce(p_cfg->>'inicio', inicio),
    meses = coalesce((p_cfg->>'meses')::int, meses),
    meta_global = coalesce((p_cfg->>'meta_global')::numeric, meta_global),
    exigir_ambos = coalesce((p_cfg->>'exigir_ambos')::boolean, exigir_ambos),
    fecha_corte = nullif(p_cfg->>'fecha_corte', '')::date,
    supervisor_nombre = coalesce(p_cfg#>>'{sup,n}', supervisor_nombre),
    supervisor_incentivo = coalesce((p_cfg#>>'{sup,inc}')::numeric, supervisor_incentivo),
    supervisor_acumulado = coalesce((p_cfg#>>'{sup,acum}')::numeric, supervisor_acumulado)
  where id = cid;

  if jsonb_typeof(p_cfg->'vendedores') = 'array' then
    delete from public.vendedores where concurso_id = cid
      and nombre not in (select e->>'n' from jsonb_array_elements(p_cfg->'vendedores') e);
    insert into public.vendedores (concurso_id, nombre, zona, promedio_gal, meta_gal, meta_clientes, incentivo, acumulado, orden)
    select cid, e.value->>'n', coalesce(e.value->>'z', ''), coalesce((e.value->>'avg')::numeric, 0), coalesce((e.value->>'tg')::numeric, 0),
           round(coalesce((e.value->>'td')::numeric, 0))::int, coalesce((e.value->>'inc')::numeric, 0), coalesce((e.value->>'acum')::numeric, 0), e.ord::int
    from jsonb_array_elements(p_cfg->'vendedores') with ordinality as e(value, ord)
    on conflict (concurso_id, nombre) do update set zona = excluded.zona, promedio_gal = excluded.promedio_gal, meta_gal = excluded.meta_gal,
      meta_clientes = excluded.meta_clientes, incentivo = excluded.incentivo, acumulado = excluded.acumulado, orden = excluded.orden;
  end if;

  if jsonb_typeof(p_cfg->'elig') = 'object' then
    delete from public.mercados_elegibles where concurso_id = cid and mercado not in (select key from jsonb_each(p_cfg->'elig'));
    insert into public.mercados_elegibles (concurso_id, mercado, elegible)
    select cid, key, (value::text)::boolean from jsonb_each(p_cfg->'elig')
    on conflict (concurso_id, mercado) do update set elegible = excluded.elegible;
  end if;

  if jsonb_typeof(p_cfg->'fam') = 'object' then
    delete from public.familias where concurso_id = cid and familia not in (select key from jsonb_each(p_cfg->'fam'));
    insert into public.familias (concurso_id, familia, activa)
    select cid, key, (value::text)::boolean from jsonb_each(p_cfg->'fam')
    on conflict (concurso_id, familia) do update set activa = excluded.activa;
  end if;
end $$;

create function public.guardar_conversion(p_token text, p_slug text, p_items jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare cid uuid;
begin
  if not privado.token_ok(p_token) then raise exception 'SESION_INVALIDA'; end if;
  if jsonb_typeof(p_items) <> 'array' then raise exception 'DATOS_INVALIDOS'; end if;
  select id into cid from public.concursos where slug = p_slug;
  if cid is null then raise exception 'CONCURSO_NO_EXISTE'; end if;
  delete from public.conversion where concurso_id = cid and codigo not in (select e->>0 from jsonb_array_elements(p_items) e);
  insert into public.conversion (concurso_id, codigo, descripcion, multiplicador)
  select cid, e->>0, nullif(e->>1, ''), (e->>2)::numeric from jsonb_array_elements(p_items) e
  on conflict (concurso_id, codigo) do update set descripcion = excluded.descripcion, multiplicador = excluded.multiplicador;
end $$;

create function public.guardar_clientes(p_token text, p_items jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not privado.token_ok(p_token) then raise exception 'SESION_INVALIDA'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'DATOS_INVALIDOS'; end if;
  delete from public.clientes where true;
  insert into public.clientes (id_cliente, empresa, vendedor, tipo_socio, mercado)
  select distinct on (e->>0) e->>0, nullif(e->>1, ''), nullif(e->>2, ''), nullif(e->>3, ''), nullif(e->>4, '')
  from jsonb_array_elements(p_items) e where coalesce(e->>0, '') <> '';
  get diagnostics n = row_count;
  return n;
end $$;

create function public.guardar_descripciones(p_token text, p_slug text, p_items jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare cid uuid;
begin
  if not privado.token_ok(p_token) then raise exception 'SESION_INVALIDA'; end if;
  select id into cid from public.concursos where slug = p_slug;
  if cid is null then raise exception 'CONCURSO_NO_EXISTE'; end if;
  insert into public.codigos_descripcion (concurso_id, codigo, descripcion)
  select cid, e->>0, e->>1 from jsonb_array_elements(p_items) e
  on conflict (concurso_id, codigo) do update set descripcion = excluded.descripcion;
end $$;

create function public.ventas_iniciar(p_token text, p_slug text, p_archivo text, p_meses text[], p_filas int) returns uuid
language plpgsql security definer set search_path = '' as $$
declare cid uuid; carga uuid;
begin
  if not privado.token_ok(p_token) then raise exception 'SESION_INVALIDA'; end if;
  select id into cid from public.concursos where slug = p_slug;
  if cid is null then raise exception 'CONCURSO_NO_EXISTE'; end if;
  insert into public.cargas (concurso_id, tipo, archivo, filas, usuario) values (cid, 'ventas', p_archivo, p_filas, null) returning id into carga;
  delete from public.ventas where concurso_id = cid and mes = any (p_meses);
  return carga;
end $$;

create function public.ventas_lote(p_token text, p_carga uuid, p_items jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare cid uuid; n int;
begin
  if not privado.token_ok(p_token) then raise exception 'SESION_INVALIDA'; end if;
  select concurso_id into cid from public.cargas where id = p_carga and tipo = 'ventas' and creado_en > now() - interval '2 hours';
  if cid is null then raise exception 'CARGA_INVALIDA'; end if;
  insert into public.ventas (concurso_id, carga_id, mes, id_cliente, empresa, codigo, vendedor, cantidad, venta_usd)
  select cid, p_carga, coalesce(e->>0, ''), nullif(e->>1, ''), nullif(e->>2, ''), e->>3, e->>4, (e->>5)::numeric, coalesce((e->>6)::numeric, 0)
  from jsonb_array_elements(p_items) e;
  get diagnostics n = row_count;
  return n;
end $$;

-- Solo estas funciones son invocables desde la API; todas validan el token internamente.
revoke all on function public.admin_activar(text), public.admin_cerrar(text), public.admin_cambiar_codigo(text, text),
  public.datos_concurso(text), public.guardar_config(text, text, jsonb), public.guardar_conversion(text, text, jsonb),
  public.guardar_clientes(text, jsonb), public.guardar_descripciones(text, text, jsonb),
  public.ventas_iniciar(text, text, text, text[], int), public.ventas_lote(text, uuid, jsonb) from public;
grant execute on function public.admin_activar(text), public.admin_cerrar(text), public.admin_cambiar_codigo(text, text),
  public.datos_concurso(text), public.guardar_config(text, text, jsonb), public.guardar_conversion(text, text, jsonb),
  public.guardar_clientes(text, jsonb), public.guardar_descripciones(text, text, jsonb),
  public.ventas_iniciar(text, text, text, text[], int), public.ventas_lote(text, uuid, jsonb) to anon, authenticated;
