-- Oudh Sannai internal authentication hardening.
-- This migration extends the existing Lovable RBAC schema instead of creating duplicate tables.

insert into public.roles (role, name, description) values
  ('super_admin', 'Super Admin', 'Akses penuh ke seluruh sistem dan pengaturan'),
  ('admin', 'Admin', 'Administrasi operasional dan user management'),
  ('sales', 'Sales', 'Operasional penjualan dan pelanggan'),
  ('purchasing', 'Purchasing', 'Operasional pembelian dan pemasok'),
  ('warehouse', 'Warehouse', 'Persediaan, gudang, dan mutasi stok'),
  ('finance', 'Finance', 'Kas, bank, piutang, dan pembayaran'),
  ('accounting', 'Accounting', 'Jurnal, akun, dan tutup buku'),
  ('manager', 'Manager', 'Persetujuan dan laporan lintas modul'),
  ('auditor', 'Auditor', 'Akses baca dan export untuk audit')
on conflict (role) do update set name = excluded.name, description = excluded.description;

insert into public.permissions (code, module, action, description)
select concat(module_key, '.', action_key), module_key, action_key::public.perm_action, initcap(action_key) || ' ' || module_key
from (values
  ('dashboard'), ('sales'), ('purchase'), ('inventory'), ('finance'), ('accounting'), ('reports'), ('users')
) as modules(module_key)
cross join (values
  ('view'), ('create'), ('edit'), ('delete'), ('approve'), ('post'), ('cancel'), ('export')
) as actions(action_key)
on conflict (code) do update set module = excluded.module, action = excluded.action, description = excluded.description;

-- Super Admin has every module/action. Other roles receive least-privilege access.
insert into public.role_permissions (role, permission_code)
select 'super_admin'::public.app_role, p.code from public.permissions p
on conflict do nothing;

insert into public.role_permissions (role, permission_code)
select r.role, concat(m.module_key, '.', a.action_key)
from (values
  ('admin', 'dashboard'), ('admin', 'reports'), ('admin', 'users'),
  ('sales', 'dashboard'), ('sales', 'sales'),
  ('purchasing', 'dashboard'), ('purchasing', 'purchase'),
  ('warehouse', 'dashboard'), ('warehouse', 'inventory'),
  ('finance', 'dashboard'), ('finance', 'finance'),
  ('accounting', 'dashboard'), ('accounting', 'accounting'),
  ('manager', 'dashboard'), ('manager', 'sales'), ('manager', 'purchase'),
  ('manager', 'inventory'), ('manager', 'finance'), ('manager', 'accounting'), ('manager', 'reports'),
  ('auditor', 'dashboard'), ('auditor', 'reports')
) as modules(role_key, module_key)
join public.roles r on r.role::text = modules.role_key
cross join (values
  ('view'), ('create'), ('edit'), ('delete'), ('approve'), ('post'), ('cancel'), ('export')
) as actions(action_key)
where (modules.role_key = 'admin' and actions.action_key in ('view', 'create', 'edit', 'delete', 'export'))
   or (modules.role_key in ('sales', 'purchasing', 'warehouse') and actions.action_key in ('view', 'create', 'edit', 'export'))
   or (modules.role_key = 'finance' and actions.action_key in ('view', 'create', 'edit', 'approve', 'export'))
   or (modules.role_key = 'accounting' and actions.action_key in ('view', 'create', 'edit', 'post', 'cancel', 'export'))
   or (modules.role_key = 'manager' and actions.action_key in ('view', 'approve', 'export'))
   or (modules.role_key = 'auditor' and actions.action_key in ('view', 'export'))
on conflict do nothing;

-- Keep the public helper used by the application compatible with the existing enum-based RBAC.
create or replace function public.has_permission(requested_permission text, requested_module text default null)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select case
    when requested_module is null then exists (
      select 1 from public.user_roles ur
      join public.profiles p on p.id = ur.user_id and p.is_active
      join public.permissions pm on pm.module = requested_permission
      join public.role_permissions rp on rp.role = ur.role and rp.permission_code = pm.code
      where ur.user_id = (select auth.uid())
    )
    else public.can(requested_module, requested_permission::public.perm_action)
  end
$$;

-- Allow exactly one internal account at the Auth boundary. The service role remains
-- the only actor that can create or update Auth users through the admin API.
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

-- Replace the original first-user super-admin bootstrap with least privilege.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(new.email) <> 'oudhsannaifactory@gmail.com' then
    raise exception 'Only the configured internal company account may access this application';
  end if;

  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', new.email))
  on conflict (id) do update set email = excluded.email;

  insert into public.user_roles (user_id, role)
  values (new.id, 'auditor'::public.app_role)
  on conflict (user_id, role) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- RLS remains the enforcement boundary for direct CRUD. These policies only add
-- authenticated read access to master data; writes continue to use existing can().
alter table public.customers enable row level security;
alter table public.suppliers enable row level security;
alter table public.products enable row level security;

 drop policy if exists "authenticated can read customers" on public.customers;
create policy "authenticated can read customers" on public.customers
for select to authenticated using (public.can('sales', 'view'));

 drop policy if exists "authenticated can read suppliers" on public.suppliers;
create policy "authenticated can read suppliers" on public.suppliers
for select to authenticated using (public.can('purchase', 'view'));

 drop policy if exists "authenticated can read products" on public.products;
create policy "authenticated can read products" on public.products
for select to authenticated using (public.can('inventory', 'view') or public.can('sales', 'view') or public.can('purchase', 'view'));
