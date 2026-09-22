-- Oudh Sannai authentication, profiles, roles, permissions, and RLS.
-- Supabase Auth remains the source of truth for credentials and sessions.

create table if not exists public.roles (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (key = lower(key)),
  name text not null unique,
  description text,
  is_system boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.permissions (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (key = lower(key)),
  name text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  module_key text not null,
  created_at timestamptz not null default now(),
  primary key (role_id, permission_id, module_key)
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  role_id uuid not null references public.roles(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.roles (key, name, description) values
  ('super_admin', 'Super Admin', 'Akses penuh ke seluruh sistem dan pengaturan'),
  ('admin', 'Admin', 'Administrasi operasional dan user management'),
  ('sales', 'Sales', 'Operasional penjualan dan pelanggan'),
  ('purchasing', 'Purchasing', 'Operasional pembelian dan pemasok'),
  ('warehouse', 'Warehouse', 'Persediaan, gudang, dan mutasi stok'),
  ('finance', 'Finance', 'Kas, bank, piutang, dan pembayaran'),
  ('accounting', 'Accounting', 'Jurnal, akun, dan tutup buku'),
  ('manager', 'Manager', 'Persetujuan dan laporan lintas modul'),
  ('auditor', 'Auditor', 'Akses baca dan export untuk audit')
on conflict (key) do update set name = excluded.name, description = excluded.description;

insert into public.permissions (key, name) values
  ('view', 'View'), ('create', 'Create'), ('edit', 'Edit'), ('delete', 'Delete'),
  ('approve', 'Approve'), ('post', 'Post'), ('cancel', 'Cancel'), ('export', 'Export')
on conflict (key) do nothing;

-- Default role is Auditor so newly registered users cannot mutate business data.
create or replace function public.default_role_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$ select id from public.roles where key = 'auditor' limit 1 $$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, role_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    public.default_role_id()
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.enforce_internal_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(new.email) <> 'oudhsannaifactory@gmail.com' then
    raise exception 'Only the configured internal company account may access this application';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_internal_user on auth.users;
create trigger enforce_internal_user
before insert or update of email on auth.users
for each row execute procedure public.enforce_internal_user();

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.current_role_key()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select r.key
  from public.profiles p
  join public.roles r on r.id = p.role_id
  where p.id = (select auth.uid()) and p.is_active = true
  limit 1
$$;

create or replace function public.has_permission(requested_permission text, requested_module text default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.role_permissions rp on rp.role_id = p.role_id
    join public.permissions permission on permission.id = rp.permission_id
    where p.id = (select auth.uid())
      and p.is_active = true
      and permission.key = lower(requested_permission)
      and (requested_module is null or rp.module_key = requested_module)
  ) or public.current_role_key() = 'super_admin';
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.current_role_key() in ('super_admin', 'admin') $$;

-- Seed module permissions. Super Admin is handled by has_permission; other roles
-- receive only the operations appropriate to their responsibility.
insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('sales'), ('purchasing'), ('inventory'), ('finance'), ('accounting'), ('reports'), ('users')) as m(module_key)
where r.key = 'super_admin'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('reports'), ('users')) as m(module_key)
where r.key = 'admin' and p.key in ('view', 'create', 'edit', 'delete', 'export')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('sales')) as m(module_key)
where r.key = 'sales' and p.key in ('view', 'create', 'edit', 'export')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('purchasing')) as m(module_key)
where r.key = 'purchasing' and p.key in ('view', 'create', 'edit', 'export')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('inventory')) as m(module_key)
where r.key = 'warehouse' and p.key in ('view', 'create', 'edit', 'export')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('finance')) as m(module_key)
where r.key = 'finance' and p.key in ('view', 'create', 'edit', 'approve', 'export')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('accounting')) as m(module_key)
where r.key = 'accounting' and p.key in ('view', 'create', 'edit', 'post', 'cancel', 'export')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('sales'), ('purchasing'), ('inventory'), ('finance'), ('accounting'), ('reports')) as m(module_key)
where r.key = 'manager' and p.key in ('view', 'approve', 'export')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id, module_key)
select r.id, p.id, m.module_key
from public.roles r
cross join public.permissions p
cross join (values ('dashboard'), ('reports')) as m(module_key)
where r.key = 'auditor' and p.key in ('view', 'export')
on conflict do nothing;

alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.profiles enable row level security;

drop policy if exists "Authenticated users can view roles" on public.roles;
create policy "Authenticated users can view roles" on public.roles
for select to authenticated using (true);

drop policy if exists "Authenticated users can view permissions" on public.permissions;
create policy "Authenticated users can view permissions" on public.permissions
for select to authenticated using (true);

drop policy if exists "Authenticated users can view role permissions" on public.role_permissions;
create policy "Authenticated users can view role permissions" on public.role_permissions
for select to authenticated using (true);

drop policy if exists "Users can view their own profile" on public.profiles;
create policy "Users can view their own profile" on public.profiles
for select to authenticated using (id = (select auth.uid()) or public.is_admin());

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile" on public.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

drop policy if exists "Admins can manage profiles" on public.profiles;
create policy "Admins can manage profiles" on public.profiles
for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.protect_profile_security_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() and (new.role_id <> old.role_id or new.is_active <> old.is_active) then
    raise exception 'Only an administrator can change profile role or active status';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_profile_security_fields on public.profiles;
create trigger protect_profile_security_fields before update on public.profiles
for each row execute procedure public.protect_profile_security_fields();

-- Keep profile timestamps consistent for profile edits.
create or replace function public.touch_profile_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles
for each row execute procedure public.touch_profile_updated_at();
