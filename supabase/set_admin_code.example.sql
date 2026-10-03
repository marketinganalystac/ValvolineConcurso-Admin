-- Define (o redefine) el código de administrador de 8 caracteres.
-- Ejecútalo UNA vez en el SQL Editor de Supabase con tu código real.
-- NO guardes el código real en el repositorio: copia este archivo, edítalo y no lo subas.
-- Solo se almacena el hash bcrypt; el código en claro no queda en la base.

insert into public.admin_config (id, codigo_hash)
values (1, extensions.crypt('CAMBIAME8', extensions.gen_salt('bf', 10)))
on conflict (id) do update set codigo_hash = excluded.codigo_hash, actualizado_en = now();

-- Cierra las sesiones de admin abiertas y limpia intentos fallidos
delete from public.admin_sesiones where true;
delete from public.admin_intentos where true;
