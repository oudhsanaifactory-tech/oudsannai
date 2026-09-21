CREATE TYPE public.payment_term AS ENUM ('cash','credit');
CREATE TYPE public.payment_status AS ENUM ('unpaid','partial','paid');

-- ============ PURCHASE ORDER ============
CREATE TABLE public.purchase_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  status public.doc_status NOT NULL DEFAULT 'draft',
  notes TEXT,
  subtotal NUMERIC(18,2) NOT NULL DEFAULT 0,
  discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  tax_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  grand_total NUMERIC(18,2) NOT NULL DEFAULT 0,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.purchase_order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  description TEXT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0,
  qty_received NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_received >= 0),
  line_no INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_poi_order ON public.purchase_order_items (order_id);

-- ============ GOODS RECEIPT ============
CREATE TABLE public.goods_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  order_id UUID REFERENCES public.purchase_orders(id),
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  status public.doc_status NOT NULL DEFAULT 'completed',
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.goods_receipt_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id UUID NOT NULL REFERENCES public.goods_receipts(id) ON DELETE CASCADE,
  order_item_id UUID REFERENCES public.purchase_order_items(id),
  product_id UUID NOT NULL REFERENCES public.products(id),
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_cost NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0)
);
CREATE INDEX idx_gri_receipt ON public.goods_receipt_items (receipt_id);

-- ============ PURCHASE INVOICE ============
CREATE TABLE public.purchase_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  due_date DATE,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id),
  order_id UUID REFERENCES public.purchase_orders(id),
  receipt_id UUID REFERENCES public.goods_receipts(id),
  payment_term public.payment_term NOT NULL DEFAULT 'credit',
  cash_account_id UUID REFERENCES public.accounts(id),
  status public.doc_status NOT NULL DEFAULT 'draft',
  payment_status public.payment_status NOT NULL DEFAULT 'unpaid',
  subtotal NUMERIC(18,2) NOT NULL DEFAULT 0,
  discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  tax_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  grand_total NUMERIC(18,2) NOT NULL DEFAULT 0,
  paid_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  posted_by UUID REFERENCES auth.users(id),
  posted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_pi_receipt ON public.purchase_invoices (receipt_id) WHERE receipt_id IS NOT NULL AND status <> 'cancelled';
CREATE TABLE public.purchase_invoice_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id UUID NOT NULL REFERENCES public.purchase_invoices(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  description TEXT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0,
  line_no INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_pii_invoice ON public.purchase_invoice_items (invoice_id);

-- ============ SUPPLIER PAYMENT ============
CREATE TABLE public.supplier_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id),
  cash_account_id UUID NOT NULL REFERENCES public.accounts(id),
  method TEXT NOT NULL DEFAULT 'transfer',
  reference_no TEXT,
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  status public.doc_status NOT NULL DEFAULT 'posted',
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.supplier_payment_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id UUID NOT NULL REFERENCES public.supplier_payments(id) ON DELETE CASCADE,
  invoice_id UUID NOT NULL REFERENCES public.purchase_invoices(id),
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0)
);
CREATE INDEX idx_spa_payment ON public.supplier_payment_allocations (payment_id);

-- ============ PURCHASE RETURN ============
CREATE TABLE public.purchase_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id),
  invoice_id UUID REFERENCES public.purchase_invoices(id),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  reason TEXT,
  status public.doc_status NOT NULL DEFAULT 'posted',
  total_amount NUMERIC(18,2) NOT NULL DEFAULT 0,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.purchase_return_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id UUID NOT NULL REFERENCES public.purchase_returns(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_price NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0
);

-- ============ TOTALS TRIGGERS ============
CREATE OR REPLACE FUNCTION private.recalc_po_totals() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
  UPDATE public.purchase_order_items SET line_total = round(qty * unit_price - discount, 2) WHERE order_id = v_id;
  UPDATE public.purchase_orders o SET
    subtotal = COALESCE(s.total,0),
    grand_total = round(COALESCE(s.total,0) - o.discount_total + o.tax_total, 2)
  FROM (SELECT SUM(round(qty*unit_price-discount,2)) total FROM public.purchase_order_items WHERE order_id = v_id) s
  WHERE o.id = v_id;
  RETURN NULL;
END; $$;
CREATE TRIGGER trg_poi_totals AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_items
FOR EACH ROW EXECUTE FUNCTION private.recalc_po_totals();

CREATE OR REPLACE FUNCTION private.recalc_pi_totals() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID := COALESCE(NEW.invoice_id, OLD.invoice_id);
BEGIN
  UPDATE public.purchase_invoice_items SET line_total = round(qty * unit_price - discount, 2) WHERE invoice_id = v_id;
  UPDATE public.purchase_invoices i SET
    subtotal = COALESCE(s.total,0),
    grand_total = round(COALESCE(s.total,0) - i.discount_total + i.tax_total, 2)
  FROM (SELECT SUM(round(qty*unit_price-discount,2)) total FROM public.purchase_invoice_items WHERE invoice_id = v_id) s
  WHERE i.id = v_id AND i.status = 'draft';
  RETURN NULL;
END; $$;
CREATE TRIGGER trg_pii_totals AFTER INSERT OR UPDATE OR DELETE ON public.purchase_invoice_items
FOR EACH ROW EXECUTE FUNCTION private.recalc_pi_totals();

-- ============ BUSINESS LOGIC (public API, RLS-enforced via permission checks) ============
CREATE OR REPLACE FUNCTION public.assert_can(_module TEXT, _action public.perm_action)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF NOT public.can(_module, _action) THEN
    RAISE EXCEPTION 'Anda tidak memiliki izin % pada modul %', _action, _module;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.next_doc_number(_prefix TEXT, _date DATE)
RETURNS TEXT LANGUAGE sql SECURITY INVOKER SET search_path = public AS $$ SELECT private.next_number(_prefix, _date); $$;

-- confirm PO
CREATE OR REPLACE FUNCTION public.confirm_purchase_order(_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.purchase_orders;
BEGIN
  PERFORM public.assert_can('purchase','edit');
  SELECT * INTO v FROM public.purchase_orders WHERE id = _id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Pesanan pembelian tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Hanya pesanan berstatus draft yang dapat dikonfirmasi.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.purchase_order_items WHERE order_id = _id) THEN
    RAISE EXCEPTION 'Pesanan harus memiliki minimal satu item.';
  END IF;
  UPDATE public.purchase_orders SET status = 'confirmed' WHERE id = _id;
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'confirm', 'purchase_order', _id, v.doc_number);
END; $$;

-- goods receipt: _items = [{order_item_id, product_id, qty, unit_cost}]
CREATE OR REPLACE FUNCTION public.create_goods_receipt(
  _order_id UUID, _supplier_id UUID, _warehouse_id UUID, _date DATE, _items JSONB, _notes TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_id UUID; v_no TEXT; it JSONB; v_item public.purchase_order_items; v_line UUID; v_cost NUMERIC;
BEGIN
  PERFORM public.assert_can('purchase','create');
  IF jsonb_array_length(COALESCE(_items,'[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Minimal satu item harus diterima.'; END IF;
  v_no := private.next_number('GR', _date);
  INSERT INTO public.goods_receipts (doc_number, doc_date, order_id, supplier_id, warehouse_id, status, notes, created_by)
  VALUES (v_no, _date, _order_id, _supplier_id, _warehouse_id, 'completed', _notes, auth.uid())
  RETURNING id INTO v_id;

  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    IF (it->>'qty')::NUMERIC <= 0 THEN RAISE EXCEPTION 'Kuantitas harus lebih besar dari 0.'; END IF;
    IF it->>'order_item_id' IS NOT NULL THEN
      SELECT * INTO v_item FROM public.purchase_order_items WHERE id = (it->>'order_item_id')::UUID FOR UPDATE;
      IF v_item.id IS NULL THEN RAISE EXCEPTION 'Item pesanan tidak ditemukan.'; END IF;
      IF v_item.qty_received + (it->>'qty')::NUMERIC > v_item.qty THEN
        RAISE EXCEPTION 'Kuantitas diterima melebihi sisa pesanan (sisa %).', v_item.qty - v_item.qty_received;
      END IF;
      UPDATE public.purchase_order_items SET qty_received = qty_received + (it->>'qty')::NUMERIC WHERE id = v_item.id;
      v_cost := COALESCE(NULLIF((it->>'unit_cost')::NUMERIC,0), v_item.unit_price);
    ELSE
      v_cost := COALESCE((it->>'unit_cost')::NUMERIC, 0);
    END IF;

    INSERT INTO public.goods_receipt_items (receipt_id, order_item_id, product_id, qty, unit_cost)
    VALUES (v_id, NULLIF(it->>'order_item_id','')::UUID, (it->>'product_id')::UUID, (it->>'qty')::NUMERIC, v_cost)
    RETURNING id INTO v_line;

    PERFORM private.apply_movement((it->>'product_id')::UUID, _warehouse_id, 'purchase_receipt', 'goods_receipt',
      v_id, v_line, v_no, (it->>'qty')::NUMERIC, 0, v_cost, _date, 'Penerimaan barang ' || v_no);
  END LOOP;

  IF _order_id IS NOT NULL THEN
    UPDATE public.purchase_orders SET status = CASE
      WHEN NOT EXISTS (SELECT 1 FROM public.purchase_order_items WHERE order_id = _order_id AND qty_received < qty) THEN 'completed'
      ELSE 'partial' END
    WHERE id = _order_id;
  END IF;

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'create', 'goods_receipt', v_id, v_no);
  RETURN v_id;
END; $$;

-- post purchase invoice -> journal + AP
CREATE OR REPLACE FUNCTION public.post_purchase_invoice(_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.purchase_invoices; v_lines JSONB; v_journal UUID; v_credit UUID;
BEGIN
  PERFORM public.assert_can('purchase','post');
  SELECT * INTO v FROM public.purchase_invoices WHERE id = _id FOR UPDATE;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Faktur pembelian tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Faktur ini sudah diposting atau dibatalkan.'; END IF;
  IF v.grand_total <= 0 THEN RAISE EXCEPTION 'Nilai faktur harus lebih besar dari 0.'; END IF;
  IF v.payment_term = 'credit' AND v.due_date IS NULL THEN RAISE EXCEPTION 'Faktur kredit wajib memiliki tanggal jatuh tempo.'; END IF;

  IF v.payment_term = 'cash' THEN
    v_credit := COALESCE(v.cash_account_id, private.account_id('1000'));
  ELSE
    v_credit := private.account_id('2000');
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', private.account_id('1300'), 'debit', v.subtotal - v.discount_total, 'credit', 0, 'description', 'Persediaan'),
    jsonb_build_object('account_id', private.account_id('1400'), 'debit', v.tax_total, 'credit', 0, 'description', 'PPN Masukan'),
    jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', v.grand_total, 'description',
      CASE WHEN v.payment_term = 'cash' THEN 'Pembayaran tunai' ELSE 'Hutang usaha' END)
  );
  IF v.tax_total = 0 THEN v_lines := v_lines - 1; END IF;

  v_journal := private.create_journal(v.doc_date, 'Faktur pembelian ' || v.doc_number, 'purchase_invoice', v.id, v_lines, true);

  UPDATE public.purchase_invoices SET status = 'posted', posted_by = auth.uid(), posted_at = now(),
    paid_amount = CASE WHEN v.payment_term = 'cash' THEN v.grand_total ELSE paid_amount END,
    payment_status = CASE WHEN v.payment_term = 'cash' THEN 'paid'::public.payment_status ELSE payment_status END
  WHERE id = _id;

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'post', 'purchase_invoice', _id, v.doc_number);
  RETURN v_journal;
END; $$;

-- supplier payment: _allocations = [{invoice_id, amount}]
CREATE OR REPLACE FUNCTION public.create_supplier_payment(
  _supplier_id UUID, _cash_account_id UUID, _date DATE, _method TEXT, _reference_no TEXT,
  _allocations JSONB, _notes TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_id UUID; v_no TEXT; al JSONB; v_inv public.purchase_invoices; v_total NUMERIC(18,2) := 0; v_amt NUMERIC(18,2);
BEGIN
  PERFORM public.assert_can('purchase','create');
  IF jsonb_array_length(COALESCE(_allocations,'[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Pilih minimal satu faktur untuk dibayar.'; END IF;
  FOR al IN SELECT * FROM jsonb_array_elements(_allocations) LOOP
    v_total := v_total + (al->>'amount')::NUMERIC;
  END LOOP;
  IF v_total <= 0 THEN RAISE EXCEPTION 'Jumlah pembayaran harus lebih besar dari 0.'; END IF;

  v_no := private.next_number('BY', _date);
  INSERT INTO public.supplier_payments (doc_number, doc_date, supplier_id, cash_account_id, method, reference_no, amount, notes, created_by)
  VALUES (v_no, _date, _supplier_id, _cash_account_id, COALESCE(_method,'transfer'), _reference_no, v_total, _notes, auth.uid())
  RETURNING id INTO v_id;

  FOR al IN SELECT * FROM jsonb_array_elements(_allocations) LOOP
    v_amt := round((al->>'amount')::NUMERIC, 2);
    SELECT * INTO v_inv FROM public.purchase_invoices WHERE id = (al->>'invoice_id')::UUID FOR UPDATE;
    IF v_inv.id IS NULL THEN RAISE EXCEPTION 'Faktur tidak ditemukan.'; END IF;
    IF v_inv.status <> 'posted' THEN RAISE EXCEPTION 'Faktur % belum diposting.', v_inv.doc_number; END IF;
    IF v_amt > (v_inv.grand_total - v_inv.paid_amount) THEN
      RAISE EXCEPTION 'Pembayaran melebihi sisa hutang faktur % (sisa %).', v_inv.doc_number, v_inv.grand_total - v_inv.paid_amount;
    END IF;
    INSERT INTO public.supplier_payment_allocations (payment_id, invoice_id, amount) VALUES (v_id, v_inv.id, v_amt);
    UPDATE public.purchase_invoices SET paid_amount = paid_amount + v_amt,
      payment_status = CASE WHEN paid_amount + v_amt >= grand_total THEN 'paid'::public.payment_status ELSE 'partial'::public.payment_status END
    WHERE id = v_inv.id;
  END LOOP;

  PERFORM private.create_journal(_date, 'Pembayaran supplier ' || v_no, 'supplier_payment', v_id,
    jsonb_build_array(
      jsonb_build_object('account_id', private.account_id('2000'), 'debit', v_total, 'credit', 0, 'description', 'Pelunasan hutang usaha'),
      jsonb_build_object('account_id', _cash_account_id, 'debit', 0, 'credit', v_total, 'description', 'Kas/Bank keluar')
    ), true);

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'payment', 'supplier_payment', v_id, v_no);
  RETURN v_id;
END; $$;

-- purchase return: _items = [{product_id, qty, unit_price}]
CREATE OR REPLACE FUNCTION public.create_purchase_return(
  _supplier_id UUID, _invoice_id UUID, _warehouse_id UUID, _date DATE, _reason TEXT, _items JSONB
) RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_id UUID; v_no TEXT; it JSONB; v_line UUID; v_total NUMERIC(18,2) := 0; v_amt NUMERIC(18,2); v_inv public.purchase_invoices;
BEGIN
  PERFORM public.assert_can('purchase','create');
  IF jsonb_array_length(COALESCE(_items,'[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Minimal satu item retur.'; END IF;
  v_no := private.next_number('RP', _date);
  INSERT INTO public.purchase_returns (doc_number, doc_date, supplier_id, invoice_id, warehouse_id, reason, created_by)
  VALUES (v_no, _date, _supplier_id, _invoice_id, _warehouse_id, _reason, auth.uid()) RETURNING id INTO v_id;

  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    v_amt := round((it->>'qty')::NUMERIC * COALESCE((it->>'unit_price')::NUMERIC,0), 2);
    v_total := v_total + v_amt;
    INSERT INTO public.purchase_return_items (return_id, product_id, qty, unit_price, line_total)
    VALUES (v_id, (it->>'product_id')::UUID, (it->>'qty')::NUMERIC, COALESCE((it->>'unit_price')::NUMERIC,0), v_amt)
    RETURNING id INTO v_line;
    PERFORM private.apply_movement((it->>'product_id')::UUID, _warehouse_id, 'purchase_return', 'purchase_return',
      v_id, v_line, v_no, 0, (it->>'qty')::NUMERIC, COALESCE((it->>'unit_price')::NUMERIC,0), _date, 'Retur pembelian ' || v_no);
  END LOOP;

  UPDATE public.purchase_returns SET total_amount = v_total WHERE id = v_id;

  PERFORM private.create_journal(_date, 'Retur pembelian ' || v_no, 'purchase_return', v_id,
    jsonb_build_array(
      jsonb_build_object('account_id', private.account_id('2000'), 'debit', v_total, 'credit', 0, 'description', 'Pengurangan hutang usaha'),
      jsonb_build_object('account_id', private.account_id('1300'), 'debit', 0, 'credit', v_total, 'description', 'Persediaan keluar')
    ), true);

  IF _invoice_id IS NOT NULL THEN
    SELECT * INTO v_inv FROM public.purchase_invoices WHERE id = _invoice_id FOR UPDATE;
    UPDATE public.purchase_invoices SET paid_amount = LEAST(grand_total, paid_amount + v_total),
      payment_status = CASE WHEN LEAST(grand_total, paid_amount + v_total) >= grand_total THEN 'paid'::public.payment_status ELSE 'partial'::public.payment_status END
    WHERE id = _invoice_id;
  END IF;

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'create', 'purchase_return', v_id, v_no);
  RETURN v_id;
END; $$;

-- grants + RLS
DO $do$
DECLARE t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY['purchase_orders','purchase_order_items','goods_receipts','goods_receipt_items',
      'purchase_invoices','purchase_invoice_items','supplier_payments','supplier_payment_allocations',
      'purchase_returns','purchase_return_items'])
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.can(''purchase'',''view''))', t||'_view', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (public.can(''purchase'',''create''))', t||'_insert', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (public.can(''purchase'',''edit'')) WITH CHECK (public.can(''purchase'',''edit''))', t||'_update', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (public.can(''purchase'',''delete''))', t||'_delete', t);
  END LOOP;
END $do$;

CREATE TRIGGER trg_po_updated BEFORE UPDATE ON public.purchase_orders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_gr_updated BEFORE UPDATE ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_pi_updated BEFORE UPDATE ON public.purchase_invoices FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_sp_updated BEFORE UPDATE ON public.supplier_payments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_pr_updated BEFORE UPDATE ON public.purchase_returns FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();