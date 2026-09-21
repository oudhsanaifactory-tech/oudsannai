CREATE TYPE public.doc_status AS ENUM ('draft','confirmed','partial','completed','posted','cancelled','approved');
CREATE TYPE public.movement_type AS ENUM ('opening_balance','purchase_receipt','sales_delivery','sales_return','purchase_return','stock_adjustment','warehouse_transfer_in','warehouse_transfer_out','opname_adjustment');
CREATE TYPE public.journal_status AS ENUM ('draft','posted','cancelled');

-- ============ DOCUMENT NUMBERING ============
CREATE TABLE public.doc_sequences (
  prefix TEXT NOT NULL,
  period TEXT NOT NULL,
  last_number INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (prefix, period)
);
GRANT ALL ON public.doc_sequences TO service_role;
ALTER TABLE public.doc_sequences ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.next_number(_prefix TEXT, _date DATE)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p TEXT := to_char(_date,'YYYYMM'); n INTEGER;
BEGIN
  INSERT INTO public.doc_sequences (prefix, period, last_number) VALUES (_prefix, p, 1)
  ON CONFLICT (prefix, period) DO UPDATE SET last_number = public.doc_sequences.last_number + 1
  RETURNING last_number INTO n;
  RETURN _prefix || '/' || p || '/' || lpad(n::TEXT, 4, '0');
END; $$;
REVOKE ALL ON FUNCTION private.next_number(TEXT, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.next_number(TEXT, DATE) TO authenticated, service_role;

-- ============ ACCOUNTING PERIODS ============
CREATE TABLE public.accounting_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fiscal_year INTEGER NOT NULL,
  period_month INTEGER NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  is_closed BOOLEAN NOT NULL DEFAULT false,
  closed_at TIMESTAMPTZ,
  closed_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (fiscal_year, period_month)
);

CREATE OR REPLACE FUNCTION private.assert_period_open(_date DATE)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.accounting_periods WHERE _date BETWEEN start_date AND end_date AND is_closed) THEN
    RAISE EXCEPTION 'Periode akuntansi untuk tanggal % sudah ditutup', to_char(_date,'DD/MM/YYYY');
  END IF;
END; $$;
REVOKE ALL ON FUNCTION private.assert_period_open(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.assert_period_open(DATE) TO authenticated, service_role;

-- ============ JOURNALS ============
CREATE TABLE public.journal_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_number TEXT NOT NULL UNIQUE,
  entry_date DATE NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  source_type TEXT,
  source_id UUID,
  status public.journal_status NOT NULL DEFAULT 'draft',
  total_debit NUMERIC(18,2) NOT NULL DEFAULT 0,
  total_credit NUMERIC(18,2) NOT NULL DEFAULT 0,
  created_by UUID REFERENCES auth.users(id),
  posted_by UUID REFERENCES auth.users(id),
  posted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_journal_source ON public.journal_entries (source_type, source_id)
  WHERE source_id IS NOT NULL AND status <> 'cancelled';
CREATE INDEX idx_journal_date ON public.journal_entries (entry_date);

CREATE TABLE public.journal_entry_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id UUID NOT NULL REFERENCES public.journal_entries(id) ON DELETE CASCADE,
  account_id UUID NOT NULL REFERENCES public.accounts(id),
  description TEXT,
  debit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  line_no INTEGER NOT NULL DEFAULT 1,
  CHECK (NOT (debit > 0 AND credit > 0))
);
CREATE INDEX idx_jel_entry ON public.journal_entry_lines (entry_id);
CREATE INDEX idx_jel_account ON public.journal_entry_lines (account_id);

-- block edits on posted journals
CREATE OR REPLACE FUNCTION private.guard_posted_journal() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE st public.journal_status;
BEGIN
  IF TG_TABLE_NAME = 'journal_entries' THEN
    IF OLD.status = 'posted' AND NEW.status = 'posted'
       AND (NEW.entry_date <> OLD.entry_date OR NEW.total_debit <> OLD.total_debit OR NEW.total_credit <> OLD.total_credit) THEN
      RAISE EXCEPTION 'Jurnal yang sudah diposting tidak dapat diubah. Gunakan jurnal koreksi.';
    END IF;
    RETURN NEW;
  END IF;
  SELECT status INTO st FROM public.journal_entries WHERE id = COALESCE(NEW.entry_id, OLD.entry_id);
  IF st = 'posted' THEN
    RAISE EXCEPTION 'Baris jurnal yang sudah diposting tidak dapat diubah.';
  END IF;
  RETURN COALESCE(NEW, OLD);
END; $$;
CREATE TRIGGER trg_guard_journal BEFORE UPDATE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION private.guard_posted_journal();
CREATE TRIGGER trg_guard_journal_lines BEFORE INSERT OR UPDATE OR DELETE ON public.journal_entry_lines FOR EACH ROW EXECUTE FUNCTION private.guard_posted_journal();

-- create + post a balanced journal from JSON lines
CREATE OR REPLACE FUNCTION private.create_journal(
  _date DATE, _description TEXT, _source_type TEXT, _source_id UUID, _lines JSONB, _post BOOLEAN DEFAULT true
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID; v_no TEXT; v_debit NUMERIC(18,2) := 0; v_credit NUMERIC(18,2) := 0; v_line JSONB; v_i INTEGER := 0; v_uid UUID := auth.uid();
BEGIN
  PERFORM private.assert_period_open(_date);
  IF _source_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.journal_entries WHERE source_type = _source_type AND source_id = _source_id AND status <> 'cancelled'
  ) THEN
    RAISE EXCEPTION 'Jurnal untuk dokumen ini sudah pernah dibuat.';
  END IF;
  FOR v_line IN SELECT * FROM jsonb_array_elements(_lines) LOOP
    v_debit := v_debit + COALESCE((v_line->>'debit')::NUMERIC, 0);
    v_credit := v_credit + COALESCE((v_line->>'credit')::NUMERIC, 0);
  END LOOP;
  IF round(v_debit,2) <> round(v_credit,2) THEN
    RAISE EXCEPTION 'Jurnal tidak seimbang: debit % vs kredit %', v_debit, v_credit;
  END IF;
  IF round(v_debit,2) = 0 THEN RAISE EXCEPTION 'Jurnal tidak boleh bernilai nol.'; END IF;
  v_no := private.next_number('JV', _date);
  INSERT INTO public.journal_entries (entry_number, entry_date, description, source_type, source_id, status,
    total_debit, total_credit, created_by, posted_by, posted_at)
  VALUES (v_no, _date, COALESCE(_description,''), _source_type, _source_id,
    CASE WHEN _post THEN 'posted'::public.journal_status ELSE 'draft'::public.journal_status END,
    round(v_debit,2), round(v_credit,2), v_uid,
    CASE WHEN _post THEN v_uid END, CASE WHEN _post THEN now() END)
  RETURNING id INTO v_id;
  FOR v_line IN SELECT * FROM jsonb_array_elements(_lines) LOOP
    v_i := v_i + 1;
    INSERT INTO public.journal_entry_lines (entry_id, account_id, description, debit, credit, line_no)
    VALUES (v_id, (v_line->>'account_id')::UUID, v_line->>'description',
            round(COALESCE((v_line->>'debit')::NUMERIC,0),2), round(COALESCE((v_line->>'credit')::NUMERIC,0),2), v_i);
  END LOOP;
  RETURN v_id;
END; $$;
REVOKE ALL ON FUNCTION private.create_journal(DATE,TEXT,TEXT,UUID,JSONB,BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.create_journal(DATE,TEXT,TEXT,UUID,JSONB,BOOLEAN) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION private.account_id(_code TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v UUID;
BEGIN
  SELECT id INTO v FROM public.accounts WHERE code = _code AND is_active;
  IF v IS NULL THEN RAISE EXCEPTION 'Akun % belum tersedia di daftar akun', _code; END IF;
  RETURN v;
END; $$;
REVOKE ALL ON FUNCTION private.account_id(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.account_id(TEXT) TO authenticated, service_role;

-- ============ INVENTORY ============
CREATE TABLE public.inventory_balances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  qty_on_hand NUMERIC(18,4) NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (product_id, warehouse_id)
);

CREATE TABLE public.inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  movement_type public.movement_type NOT NULL,
  reference_type TEXT NOT NULL,
  reference_id UUID,
  reference_line_id UUID,
  reference_number TEXT,
  qty_in NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_in >= 0),
  qty_out NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_out >= 0),
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0,
  balance_after NUMERIC(18,4) NOT NULL DEFAULT 0,
  movement_date DATE NOT NULL DEFAULT current_date,
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_movement_source ON public.inventory_movements (reference_type, reference_line_id, movement_type)
  WHERE reference_line_id IS NOT NULL;
CREATE INDEX idx_movement_product ON public.inventory_movements (product_id, warehouse_id, movement_date);

CREATE OR REPLACE FUNCTION private.apply_movement(
  _product UUID, _warehouse UUID, _type public.movement_type, _ref_type TEXT, _ref_id UUID,
  _ref_line UUID, _ref_no TEXT, _qty_in NUMERIC, _qty_out NUMERIC, _unit_cost NUMERIC,
  _date DATE, _notes TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bal NUMERIC(18,4); v_new NUMERIC(18,4); v_allow BOOLEAN; v_avg NUMERIC(18,4); v_id UUID; v_type public.product_type;
BEGIN
  SELECT product_type INTO v_type FROM public.products WHERE id = _product;
  IF v_type IS DISTINCT FROM 'inventory' THEN RETURN NULL; END IF;
  PERFORM private.assert_period_open(_date);
  SELECT COALESCE(allow_negative_stock,false) INTO v_allow FROM public.companies ORDER BY created_at LIMIT 1;

  INSERT INTO public.inventory_balances (product_id, warehouse_id, qty_on_hand)
  VALUES (_product, _warehouse, 0)
  ON CONFLICT (product_id, warehouse_id) DO NOTHING;

  SELECT qty_on_hand INTO v_bal FROM public.inventory_balances
    WHERE product_id = _product AND warehouse_id = _warehouse FOR UPDATE;

  v_new := v_bal + COALESCE(_qty_in,0) - COALESCE(_qty_out,0);
  IF v_new < 0 AND NOT COALESCE(v_allow,false) THEN
    RAISE EXCEPTION 'Stok tidak mencukupi untuk produk % di gudang ini (tersedia %, diminta %)',
      (SELECT name FROM public.products WHERE id = _product), v_bal, _qty_out;
  END IF;

  UPDATE public.inventory_balances SET qty_on_hand = v_new, updated_at = now()
    WHERE product_id = _product AND warehouse_id = _warehouse;

  -- moving average cost on inbound
  IF COALESCE(_qty_in,0) > 0 AND COALESCE(_unit_cost,0) > 0 THEN
    SELECT average_cost INTO v_avg FROM public.products WHERE id = _product FOR UPDATE;
    UPDATE public.products SET average_cost = CASE
        WHEN (v_bal + _qty_in) <= 0 THEN _unit_cost
        ELSE ((GREATEST(v_bal,0) * COALESCE(v_avg,0)) + (_qty_in * _unit_cost)) / (GREATEST(v_bal,0) + _qty_in)
      END
      WHERE id = _product;
  END IF;

  INSERT INTO public.inventory_movements (product_id, warehouse_id, movement_type, reference_type, reference_id,
    reference_line_id, reference_number, qty_in, qty_out, unit_cost, balance_after, movement_date, notes, created_by)
  VALUES (_product, _warehouse, _type, _ref_type, _ref_id, _ref_line, _ref_no,
    COALESCE(_qty_in,0), COALESCE(_qty_out,0),
    COALESCE(NULLIF(_unit_cost,0), (SELECT average_cost FROM public.products WHERE id = _product)),
    v_new, _date, _notes, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
REVOKE ALL ON FUNCTION private.apply_movement(UUID,UUID,public.movement_type,TEXT,UUID,UUID,TEXT,NUMERIC,NUMERIC,NUMERIC,DATE,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.apply_movement(UUID,UUID,public.movement_type,TEXT,UUID,UUID,TEXT,NUMERIC,NUMERIC,NUMERIC,DATE,TEXT) TO authenticated, service_role;

-- ============ STOCK ADJUSTMENT / TRANSFER / OPNAME ============
CREATE TABLE public.stock_adjustments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  reason TEXT NOT NULL DEFAULT '',
  status public.doc_status NOT NULL DEFAULT 'draft',
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  approved_by UUID REFERENCES auth.users(id),
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.stock_adjustment_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  adjustment_id UUID NOT NULL REFERENCES public.stock_adjustments(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  qty_change NUMERIC(18,4) NOT NULL CHECK (qty_change <> 0),
  notes TEXT
);

CREATE TABLE public.stock_transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  from_warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  to_warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  status public.doc_status NOT NULL DEFAULT 'draft',
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_warehouse_id <> to_warehouse_id)
);
CREATE TABLE public.stock_transfer_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id UUID NOT NULL REFERENCES public.stock_transfers(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0)
);

CREATE TABLE public.stock_opnames (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  status public.doc_status NOT NULL DEFAULT 'draft',
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  approved_by UUID REFERENCES auth.users(id),
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.stock_opname_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  opname_id UUID NOT NULL REFERENCES public.stock_opnames(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  system_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
  physical_qty NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (physical_qty >= 0),
  difference NUMERIC(18,4) GENERATED ALWAYS AS (physical_qty - system_qty) STORED,
  reason TEXT
);

-- grants + RLS
DO $do$
DECLARE t TEXT; m TEXT;
BEGIN
  FOR t, m IN SELECT * FROM (VALUES
      ('accounting_periods','accounting'),('journal_entries','accounting'),('journal_entry_lines','accounting'),
      ('inventory_balances','inventory'),('inventory_movements','inventory'),
      ('stock_adjustments','inventory'),('stock_adjustment_items','inventory'),
      ('stock_transfers','inventory'),('stock_transfer_items','inventory'),
      ('stock_opnames','inventory'),('stock_opname_items','inventory')
    ) AS v(t,m)
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.can(%L,''view''))', t||'_view', t, m);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (public.can(%L,''create''))', t||'_insert', t, m);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (public.can(%L,''edit'')) WITH CHECK (public.can(%L,''edit''))', t||'_update', t, m, m);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (public.can(%L,''delete''))', t||'_delete', t, m);
  END LOOP;
END $do$;

CREATE TRIGGER trg_ap_updated BEFORE UPDATE ON public.accounting_periods FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_je_updated BEFORE UPDATE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_sa_updated BEFORE UPDATE ON public.stock_adjustments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_st_updated BEFORE UPDATE ON public.stock_transfers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_so_updated BEFORE UPDATE ON public.stock_opnames FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- seed periods for current and next year
INSERT INTO public.accounting_periods (fiscal_year, period_month, start_date, end_date)
SELECT y, m, make_date(y,m,1), (make_date(y,m,1) + INTERVAL '1 month - 1 day')::DATE
FROM generate_series(EXTRACT(YEAR FROM current_date)::INT, EXTRACT(YEAR FROM current_date)::INT + 1) y
CROSS JOIN generate_series(1,12) m
ON CONFLICT DO NOTHING;