-- ============ ENUMS ============
CREATE TYPE public.app_role AS ENUM ('super_admin','admin','sales','purchasing','warehouse','finance','accounting','manager','auditor');
CREATE TYPE public.perm_action AS ENUM ('view','create','edit','delete','approve','post','cancel','export');
CREATE TYPE public.account_type AS ENUM ('asset','liability','equity','revenue','expense');
CREATE TYPE public.normal_balance AS ENUM ('debit','credit');
CREATE TYPE public.product_type AS ENUM ('inventory','service');

-- ============ COMMON ============
CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- ============ PROFILES ============
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT,
  full_name TEXT NOT NULL DEFAULT '',
  job_title TEXT,
  phone TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============ ROLES & PERMISSIONS ============
CREATE TABLE public.roles (
  role public.app_role PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT
);
GRANT SELECT ON public.roles TO authenticated;
GRANT ALL ON public.roles TO service_role;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.permissions (
  code TEXT PRIMARY KEY,
  module TEXT NOT NULL,
  action public.perm_action NOT NULL,
  description TEXT,
  UNIQUE (module, action)
);
GRANT SELECT ON public.permissions TO authenticated;
GRANT ALL ON public.permissions TO service_role;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);
GRANT SELECT, INSERT, DELETE ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.role_permissions (
  role public.app_role NOT NULL,
  permission_code TEXT NOT NULL REFERENCES public.permissions(code) ON DELETE CASCADE,
  PRIMARY KEY (role, permission_code)
);
GRANT SELECT, INSERT, DELETE ON public.role_permissions TO authenticated;
GRANT ALL ON public.role_permissions TO service_role;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

-- ============ SECURITY HELPERS ============
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role);
$$;

CREATE OR REPLACE FUNCTION public.can(_module TEXT, _action public.perm_action)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles ur
    JOIN public.profiles p ON p.id = ur.user_id AND p.is_active
    WHERE ur.user_id = auth.uid()
      AND (ur.role = 'super_admin' OR EXISTS (
        SELECT 1 FROM public.role_permissions rp
        JOIN public.permissions pm ON pm.code = rp.permission_code
        WHERE rp.role = ur.role AND pm.module = _module AND pm.action = _action
      ))
  );
$$;

CREATE OR REPLACE FUNCTION public.my_permissions()
RETURNS TABLE (module TEXT, action public.perm_action)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT DISTINCT pm.module, pm.action
  FROM public.permissions pm
  WHERE EXISTS (SELECT 1 FROM public.user_roles ur JOIN public.profiles p ON p.id = ur.user_id AND p.is_active
                WHERE ur.user_id = auth.uid() AND ur.role = 'super_admin')
     OR EXISTS (SELECT 1 FROM public.user_roles ur JOIN public.profiles p ON p.id = ur.user_id AND p.is_active
                JOIN public.role_permissions rp ON rp.role = ur.role
                WHERE ur.user_id = auth.uid() AND rp.permission_code = pm.code);
$$;

-- profile/role policies
CREATE POLICY "read own or with users.view" ON public.profiles FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.can('users','view'));
CREATE POLICY "update own or users.edit" ON public.profiles FOR UPDATE TO authenticated
  USING (id = auth.uid() OR public.can('users','edit'))
  WITH CHECK (id = auth.uid() OR public.can('users','edit'));
CREATE POLICY "insert own profile" ON public.profiles FOR INSERT TO authenticated WITH CHECK (id = auth.uid());

CREATE POLICY "roles readable" ON public.roles FOR SELECT TO authenticated USING (true);
CREATE POLICY "permissions readable" ON public.permissions FOR SELECT TO authenticated USING (true);
CREATE POLICY "read own roles or users.view" ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.can('users','view'));
CREATE POLICY "manage roles" ON public.user_roles FOR INSERT TO authenticated WITH CHECK (public.can('users','edit'));
CREATE POLICY "remove roles" ON public.user_roles FOR DELETE TO authenticated USING (public.can('users','edit'));
CREATE POLICY "role_perms readable" ON public.role_permissions FOR SELECT TO authenticated USING (true);
CREATE POLICY "role_perms insert" ON public.role_permissions FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'super_admin'));
CREATE POLICY "role_perms delete" ON public.role_permissions FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'super_admin'));

-- new user trigger: profile + bootstrap super admin
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE has_any BOOLEAN;
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email,'@',1)))
  ON CONFLICT (id) DO NOTHING;
  SELECT EXISTS (SELECT 1 FROM public.user_roles) INTO has_any;
  IF NOT has_any THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'super_admin');
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============ COMPANY ============
CREATE TABLE public.companies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  legal_name TEXT,
  address TEXT,
  phone TEXT,
  email TEXT,
  npwp TEXT,
  currency TEXT NOT NULL DEFAULT 'IDR',
  inventory_valuation TEXT NOT NULL DEFAULT 'average' CHECK (inventory_valuation IN ('average','fifo')),
  allow_negative_stock BOOLEAN NOT NULL DEFAULT false,
  default_tax_rate NUMERIC(6,3) NOT NULL DEFAULT 0 CHECK (default_tax_rate >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.companies TO authenticated;
GRANT ALL ON public.companies TO service_role;
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "company view" ON public.companies FOR SELECT TO authenticated USING (public.can('company','view'));
CREATE POLICY "company insert" ON public.companies FOR INSERT TO authenticated WITH CHECK (public.can('company','edit'));
CREATE POLICY "company edit" ON public.companies FOR UPDATE TO authenticated USING (public.can('company','edit')) WITH CHECK (public.can('company','edit'));
CREATE TRIGGER trg_companies_updated BEFORE UPDATE ON public.companies FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============ MASTER DATA ============
CREATE TABLE public.units (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.product_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sku TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL CHECK (length(btrim(name)) > 0),
  category_id UUID REFERENCES public.product_categories(id) ON DELETE SET NULL,
  unit_id UUID NOT NULL REFERENCES public.units(id),
  product_type public.product_type NOT NULL DEFAULT 'inventory',
  purchase_price NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (purchase_price >= 0),
  selling_price NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (selling_price >= 0),
  min_stock NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (min_stock >= 0),
  average_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (average_cost >= 0),
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);
CREATE INDEX idx_products_name ON public.products (lower(name));
CREATE INDEX idx_products_category ON public.products (category_id);

CREATE TABLE public.customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL CHECK (length(btrim(name)) > 0),
  phone TEXT, email TEXT, address TEXT, npwp TEXT,
  credit_limit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);
CREATE INDEX idx_customers_name ON public.customers (lower(name));

CREATE TABLE public.suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL CHECK (length(btrim(name)) > 0),
  phone TEXT, email TEXT, address TEXT, npwp TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);
CREATE INDEX idx_suppliers_name ON public.suppliers (lower(name));

CREATE TABLE public.warehouses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL CHECK (length(btrim(name)) > 0),
  address TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  account_type public.account_type NOT NULL,
  normal_balance public.normal_balance NOT NULL,
  parent_id UUID REFERENCES public.accounts(id) ON DELETE SET NULL,
  is_cash_account BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- grants + RLS for master tables
DO $do$
DECLARE t TEXT; m TEXT;
BEGIN
  FOR t, m IN SELECT * FROM (VALUES
      ('units','master'),('product_categories','master'),('products','master'),
      ('customers','master'),('suppliers','master'),('warehouses','master'),('accounts','accounting')
    ) AS v(t,m)
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.can(%L,''view''))', t||'_view', t, m);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (public.can(%L,''create''))', t||'_insert', t, m);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (public.can(%L,''edit'')) WITH CHECK (public.can(%L,''edit''))', t||'_update', t, m, m);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (public.can(%L,''delete''))', t||'_delete', t, m);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()', 'trg_'||t||'_updated', t);
  END LOOP;
END $do$;

-- ============ AUDIT LOG ============
CREATE TABLE public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id),
  action TEXT NOT NULL,
  document_type TEXT NOT NULL,
  document_id UUID,
  document_number TEXT,
  old_values JSONB,
  new_values JSONB,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_doc ON public.audit_logs (document_type, document_id);
CREATE INDEX idx_audit_created ON public.audit_logs (created_at DESC);
GRANT SELECT, INSERT ON public.audit_logs TO authenticated;
GRANT ALL ON public.audit_logs TO service_role;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "audit view" ON public.audit_logs FOR SELECT TO authenticated USING (public.can('audit','view'));
CREATE POLICY "audit insert" ON public.audit_logs FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- ============ SEED: roles, permissions, mappings ============
INSERT INTO public.roles (role, name, description) VALUES
 ('super_admin','Super Admin','Akses penuh ke seluruh sistem'),
 ('admin','Admin','Mengelola pengguna dan data master'),
 ('sales','Sales','Penjualan dan pelanggan'),
 ('purchasing','Purchasing','Pembelian dan supplier'),
 ('warehouse','Gudang','Persediaan, penerimaan, dan pengiriman barang'),
 ('finance','Finance','Kas, bank, piutang, dan hutang'),
 ('accounting','Accounting','Jurnal, buku besar, dan periode akuntansi'),
 ('manager','Manager','Persetujuan transaksi dan laporan'),
 ('auditor','Auditor','Akses baca dan jejak audit');

INSERT INTO public.permissions (code, module, action, description)
SELECT m.module || '.' || a.action, m.module, a.action::public.perm_action,
       'Izin ' || a.action || ' pada modul ' || m.module
FROM (VALUES ('company'),('users'),('master'),('inventory'),('sales'),('purchase'),('accounting'),('reports'),('audit')) AS m(module)
CROSS JOIN (VALUES ('view'),('create'),('edit'),('delete'),('approve'),('post'),('cancel'),('export')) AS a(action);

-- role -> permission mapping
INSERT INTO public.role_permissions (role, permission_code)
SELECT 'admin'::public.app_role, code FROM public.permissions WHERE module IN ('company','users','master','reports','audit')
UNION SELECT 'admin'::public.app_role, code FROM public.permissions WHERE action = 'view'
UNION SELECT 'sales'::public.app_role, code FROM public.permissions WHERE module = 'sales' AND action IN ('view','create','edit','cancel','export')
UNION SELECT 'sales'::public.app_role, code FROM public.permissions WHERE module IN ('master','inventory','reports') AND action IN ('view','export')
UNION SELECT 'purchasing'::public.app_role, code FROM public.permissions WHERE module = 'purchase' AND action IN ('view','create','edit','cancel','export')
UNION SELECT 'purchasing'::public.app_role, code FROM public.permissions WHERE module IN ('master','inventory','reports') AND action IN ('view','export')
UNION SELECT 'warehouse'::public.app_role, code FROM public.permissions WHERE module = 'inventory' AND action IN ('view','create','edit','export')
UNION SELECT 'warehouse'::public.app_role, code FROM public.permissions WHERE module IN ('sales','purchase','master','reports') AND action IN ('view','export')
UNION SELECT 'finance'::public.app_role, code FROM public.permissions WHERE module IN ('sales','purchase') AND action IN ('view','create','post','export')
UNION SELECT 'finance'::public.app_role, code FROM public.permissions WHERE module IN ('accounting','reports') AND action IN ('view','create','post','export')
UNION SELECT 'accounting'::public.app_role, code FROM public.permissions WHERE module = 'accounting'
UNION SELECT 'accounting'::public.app_role, code FROM public.permissions WHERE module IN ('sales','purchase','inventory','reports','master') AND action IN ('view','post','export')
UNION SELECT 'manager'::public.app_role, code FROM public.permissions WHERE action IN ('view','approve','export','post')
UNION SELECT 'auditor'::public.app_role, code FROM public.permissions WHERE action IN ('view','export')
ON CONFLICT DO NOTHING;

-- ============ SEED: company, units, categories, warehouse, COA ============
INSERT INTO public.companies (name, legal_name, currency) VALUES ('Oudh Sannai','PT Oudh Sannai Indonesia','IDR');

INSERT INTO public.units (code, name) VALUES ('PCS','Pieces'),('BOX','Box'),('ML','Mililiter'),('GR','Gram'),('SET','Set');
INSERT INTO public.product_categories (code, name) VALUES ('UMUM','Umum'),('PARFUM','Parfum'),('BAHAN','Bahan Baku'),('KEMASAN','Kemasan');
INSERT INTO public.warehouses (code, name, address) VALUES ('GD-UTAMA','Gudang Utama','Kantor Pusat');

INSERT INTO public.accounts (code, name, account_type, normal_balance, is_cash_account) VALUES
 ('1000','Kas','asset','debit',true),
 ('1100','Bank','asset','debit',true),
 ('1200','Piutang Usaha','asset','debit',false),
 ('1300','Persediaan','asset','debit',false),
 ('1400','PPN Masukan','asset','debit',false),
 ('2000','Hutang Usaha','liability','credit',false),
 ('2100','PPN Keluaran','liability','credit',false),
 ('3000','Modal','equity','credit',false),
 ('3900','Laba Ditahan','equity','credit',false),
 ('4000','Penjualan','revenue','credit',false),
 ('4100','Diskon Penjualan','revenue','debit',false),
 ('4200','Retur Penjualan','revenue','debit',false),
 ('5000','Harga Pokok Penjualan','expense','debit',false),
 ('5100','Beban Operasional','expense','debit',false),
 ('5200','Selisih Persediaan','expense','debit',false);