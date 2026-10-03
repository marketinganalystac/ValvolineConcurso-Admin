-- La API de Supabase (PostgREST) exige WHERE en todo DELETE/UPDATE: se agrega "where true".
-- (Si ya aplicaste la migración 2 corregida, esta es idempotente.)
create or replace function public.admin_activar(p_codigo text) returns text
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
