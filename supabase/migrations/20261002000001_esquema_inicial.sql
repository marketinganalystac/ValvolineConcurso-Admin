-- Esquema inicial del concurso Cliente Manía - Valvoline

create table public.usuarios (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  rol text not null default 'lector' check (rol in ('admin','lector')),
  creado_en timestamptz not null default now()
);

create table public.concursos (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  nombre text not null,
  inicio text not null check (inicio ~ '^\d{4}-\d{2}$'),
  meses int not null default 3,
  meta_global numeric not null default 0,
  exigir_ambos boolean not null default true,
  fecha_corte date,
  supervisor_nombre text,
  supervisor_incentivo numeric not null default 0,
  supervisor_acumulado numeric not null default 0,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

create table public.vendedores (
  id uuid primary key default gen_random_uuid(),
  concurso_id uuid not null references public.concursos(id) on delete cascade,
  nombre text not null,
  zona text not null,
  promedio_gal numeric not null default 0,
  meta_gal numeric not null default 0,
  meta_clientes int not null default 0,
  incentivo numeric not null default 0,
  acumulado numeric not null default 0,
  orden int not null default 0,
  unique (concurso_id, nombre)
);

create table public.mercados_elegibles (
  concurso_id uuid not null references public.concursos(id) on delete cascade,
  mercado text not null,
  elegible boolean not null default false,
  primary key (concurso_id, mercado)
);

create table public.familias (
  concurso_id uuid not null references public.concursos(id) on delete cascade,
  familia text not null,
  activa boolean not null default true,
  primary key (concurso_id, familia)
);

create table public.conversion (
  concurso_id uuid not null references public.concursos(id) on delete cascade,
  codigo text not null,
  descripcion text,
  multiplicador numeric not null,
  primary key (concurso_id, codigo)
);

create table public.clientes (
  id_cliente text primary key,
  empresa text,
  vendedor text,
  tipo_socio text,
  mercado text,
  actualizado_en timestamptz not null default now()
);

create table public.cargas (
  id uuid primary key default gen_random_uuid(),
  concurso_id uuid not null references public.concursos(id) on delete cascade,
  tipo text not null check (tipo in ('ventas','maestro','multiplicador')),
  archivo text,
  filas int,
  usuario uuid references auth.users(id) on delete set null default auth.uid(),
  creado_en timestamptz not null default now()
);

create table public.ventas (
  id bigint generated always as identity primary key,
  concurso_id uuid not null references public.concursos(id) on delete cascade,
  carga_id uuid references public.cargas(id) on delete set null,
  mes text not null check (mes ~ '^\d{4}-\d{2}$'),
  id_cliente text,
  empresa text,
  codigo text not null,
  vendedor text not null,
  cantidad numeric not null,
  venta_usd numeric not null default 0
);

create index cargas_concurso_idx on public.cargas (concurso_id);
create index cargas_usuario_idx on public.cargas (usuario);
create index ventas_concurso_mes_idx on public.ventas (concurso_id, mes);
create index ventas_carga_idx on public.ventas (carga_id);
create index ventas_cliente_idx on public.ventas (id_cliente);

create function public.tocar_actualizado() returns trigger
language plpgsql set search_path = '' as $$
begin new.actualizado_en = now(); return new; end $$;
revoke execute on function public.tocar_actualizado() from public, anon, authenticated;
create trigger concursos_tocar before update on public.concursos for each row execute function public.tocar_actualizado();
create trigger clientes_tocar before update on public.clientes for each row execute function public.tocar_actualizado();

-- Seguridad: RLS en todo. Sin acceso anónimo directo a las tablas.
alter table public.usuarios enable row level security;
create policy "ver_mi_fila" on public.usuarios for select to authenticated using (user_id = (select auth.uid()));

do $$
declare t text;
begin
  foreach t in array array['concursos','vendedores','mercados_elegibles','familias','conversion','clientes','cargas','ventas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format($p$create policy "leer_autorizados" on public.%I for select to authenticated
      using (exists (select 1 from public.usuarios u where u.user_id = (select auth.uid())))$p$, t);
    execute format($p$create policy "insertar_admin" on public.%I for insert to authenticated
      with check (exists (select 1 from public.usuarios u where u.user_id = (select auth.uid()) and u.rol = 'admin'))$p$, t);
    execute format($p$create policy "actualizar_admin" on public.%I for update to authenticated
      using (exists (select 1 from public.usuarios u where u.user_id = (select auth.uid()) and u.rol = 'admin'))
      with check (exists (select 1 from public.usuarios u where u.user_id = (select auth.uid()) and u.rol = 'admin'))$p$, t);
    execute format($p$create policy "borrar_admin" on public.%I for delete to authenticated
      using (exists (select 1 from public.usuarios u where u.user_id = (select auth.uid()) and u.rol = 'admin'))$p$, t);
  end loop;
end $$;

-- Datos iniciales: parámetros por defecto del dashboard
insert into public.concursos (slug, nombre, inicio, meses, meta_global, exigir_ambos, supervisor_nombre, supervisor_incentivo, supervisor_acumulado)
values ('valvoline', 'Cliente Manía - Valvoline', '2026-10', 3, 51000, true, 'Blas Palma', 1300, 3900);

insert into public.vendedores (concurso_id, nombre, zona, promedio_gal, meta_gal, meta_clientes, incentivo, acumulado, orden)
select c.id, v.n, v.z, v.avg, v.tg, v.td, v.inc, v.acum, v.o
from public.concursos c,
(values
 ('Miguel Angel Cedeño','Chitré',3219,5000,35,1000,3000,1),
 ('Felix Barrios','Chitré',3583,5000,25,1000,3000,2),
 ('Clarissa Sierra','Panamá',3164,5000,30,1000,3000,3),
 ('Pablo Rodriguez','Chorrera',3233,4500,35,900,2700,4),
 ('Eduardo Rodriguez','Panamá',3407,5000,35,1000,3000,5),
 ('Ismael Pimentel','Santiago',1770,2500,18,500,1500,6),
 ('Rene Camargo','Panamá',2521,3500,25,700,2100,7),
 ('Alexander Arauz','Chiriquí',2069,3000,25,600,1800,8),
 ('Jairo Cabrera','Colón',2153,3000,18,600,1800,9),
 ('Eliecer Salazar','Chiriquí',1817,2500,25,500,1500,10),
 ('Luis Perez','Coronado',1556,2500,15,500,1500,11),
 ('Anthony Alonso','Chorrera',1173,1600,15,320,960,12),
 ('Patrick Aparicio','Chiriquí',1104,1500,15,300,900,13),
 ('Juan Casasola','Bocas',4903,6400,15,1280,3840,14)
) as v(n,z,avg,tg,td,inc,acum,o)
where c.slug = 'valvoline';

insert into public.mercados_elegibles (concurso_id, mercado, elegible)
select c.id, m.n, m.e
from public.concursos c,
(values
 ('Distribuidor - repuestero',true),('Distribuidor - grandes superficies',true),('Distribuidor de llantas/lub centers',true),
 ('Distribuidores',true),('Distribuidor - taller',true),('Cliente final - taller',true),
 ('Cliente Auto Centro - Tienda',false),('Cliente final - flota',false),('Cliente Final - Industria',false),
 ('Distribuidor - agencias',false),('Cliente final - Constructora',false),('Constructoras',false),
 ('Subcontratistas',false),('Gobierno',false),('Promotoras / Proyectos',false),
 ('Sin Asignación',false),('Sin mercado',false)
) as m(n,e)
where c.slug = 'valvoline';
