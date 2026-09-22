-- ============ SALES ORDER ============
CREATE TABLE public.sales_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  customer_id UUID NOT NULL REFERENCES public.customers(id),
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
CREATE TABLE public.sales_order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.sales_orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  description TEXT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0,
  qty_delivered NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_delivered >= 0),
  line_no INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_soi_order ON public.sales_order_items (order_id);

-- ============ DELIVERY ============
CREATE TABLE public.deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  order_id UUID REFERENCES public.sales_orders(id),
  customer_id UUID NOT NULL REFERENCES public.customers(id),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  status public.doc_status NOT NULL DEFAULT 'completed',
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.delivery_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE CASCADE,
  order_item_id UUID REFERENCES public.sales_order_items(id),
  product_id UUID NOT NULL REFERENCES public.products(id),
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0
);
CREATE INDEX idx_di_delivery ON public.delivery_items (delivery_id);

-- ============ SALES INVOICE ============
CREATE TABLE public.sales_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  due_date DATE,
  customer_id UUID NOT NULL REFERENCES public.customers(id),
  order_id UUID REFERENCES public.sales_orders(id),
  delivery_id UUID REFERENCES public.deliveries(id),
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
CREATE UNIQUE INDEX uq_si_delivery ON public.sales_invoices (delivery_id) WHERE delivery_id IS NOT NULL AND status <> 'cancelled';
CREATE TABLE public.sales_invoice_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id UUID NOT NULL REFERENCES public.sales_invoices(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  description TEXT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0,
  line_no INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_sii_invoice ON public.sales_invoice_items (invoice_id);

-- ============ CUSTOMER PAYMENT ============
CREATE TABLE public.customer_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  customer_id UUID NOT NULL REFERENCES public.customers(id),
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
CREATE TABLE public.customer_payment_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id UUID NOT NULL REFERENCES public.customer_payments(id) ON DELETE CASCADE,
  invoice_id UUID NOT NULL REFERENCES public.sales_invoices(id),
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0)
);
CREATE INDEX idx_cpa_payment ON public.customer_payment_allocations (payment_id);

-- ============ SALES RETURN ============
CREATE TABLE public.sales_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_number TEXT NOT NULL UNIQUE,
  doc_date DATE NOT NULL DEFAULT current_date,
  customer_id UUID NOT NULL REFERENCES public.customers(id),
  invoice_id UUID REFERENCES public.sales_invoices(id),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id),
  reason TEXT,
  restock BOOLEAN NOT NULL DEFAULT true,
  status public.doc_status NOT NULL DEFAULT 'posted',
  total_amount NUMERIC(18,2) NOT NULL DEFAULT 0,
  created_by UUID REFERENCES auth.users(id),
  approved_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.sales_return_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id UUID NOT NULL REFERENCES public.sales_returns(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_price NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0
);

-- ============ TOTALS TRIGGERS ============
CREATE OR REPLACE FUNCTION private.recalc_so_totals() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
  UPDATE public.sales_order_items SET line_total = round(qty * unit_price - discount, 2) WHERE order_id = v_id;
  UPDATE public.sales_orders o SET subtotal = COALESCE(s.total,0),
    grand_total = round(COALESCE(s.total,0) - o.discount_total + o.tax_total, 2)
  FROM (SELECT SUM(round(qty*unit_price-discount,2)) total FROM public.sales_order_items WHERE order_id = v_id) s
  WHERE o.id = v_id;
  RETURN NULL;
END; $$;
CREATE TRIGGER trg_soi_totals AFTER INSERT OR UPDATE OR DELETE ON public.sales_order_items
FOR EACH ROW EXECUTE FUNCTION private.recalc_so_totals();

CREATE OR REPLACE FUNCTION private.recalc_si_totals() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID := COALESCE(NEW.invoice_id, OLD.invoice_id);
BEGIN
  UPDATE public.sales_invoice_items SET line_total = round(qty * unit_price - discount, 2) WHERE invoice_id = v_id;
  UPDATE public.sales_invoices i SET subtotal = COALESCE(s.total,0),
    grand_total = round(COALESCE(s.total,0) - i.discount_total + i.tax_total, 2)
  FROM (SELECT SUM(round(qty*unit_price-discount,2)) total FROM public.sales_invoice_items WHERE invoice_id = v_id) s
  WHERE i.id = v_id AND i.status = 'draft';
  RETURN NULL;
END; $$;
CREATE TRIGGER trg_sii_totals AFTER INSERT OR UPDATE OR DELETE ON public.sales_invoice_items
FOR EACH ROW EXECUTE FUNCTION private.recalc_si_totals();

-- ============ BUSINESS LOGIC ============
CREATE OR REPLACE FUNCTION public.confirm_sales_order(_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.sales_orders;
BEGIN
  PERFORM public.assert_can('sales','edit');
  SELECT * INTO v FROM public.sales_orders WHERE id = _id;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Pesanan penjualan tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Hanya pesanan berstatus draft yang dapat dikonfirmasi.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales_order_items WHERE order_id = _id) THEN
    RAISE EXCEPTION 'Pesanan harus memiliki minimal satu item.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.sales_order_items i JOIN public.products p ON p.id = i.product_id
             WHERE i.order_id = _id AND NOT p.is_active) THEN
    RAISE EXCEPTION 'Terdapat produk nonaktif pada pesanan.';
  END IF;
  UPDATE public.sales_orders SET status = 'confirmed' WHERE id = _id;
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'confirm', 'sales_order', _id, v.doc_number);
END; $$;

-- delivery: _items = [{order_item_id, product_id, qty}]
CREATE OR REPLACE FUNCTION public.create_delivery(
  _order_id UUID, _customer_id UUID, _warehouse_id UUID, _date DATE, _items JSONB, _notes TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_id UUID; v_no TEXT; it JSONB; v_item public.sales_order_items; v_line UUID; v_cost NUMERIC(18,4); v_cogs NUMERIC(18,2) := 0;
BEGIN
  PERFORM public.assert_can('sales','create');
  IF jsonb_array_length(COALESCE(_items,'[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Minimal satu item harus dikirim.'; END IF;
  v_no := private.next_number('DO', _date);
  INSERT INTO public.deliveries (doc_number, doc_date, order_id, customer_id, warehouse_id, status, notes, created_by)
  VALUES (v_no, _date, _order_id, _customer_id, _warehouse_id, 'completed', _notes, auth.uid()) RETURNING id INTO v_id;

  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    IF (it->>'qty')::NUMERIC <= 0 THEN RAISE EXCEPTION 'Kuantitas harus lebih besar dari 0.'; END IF;
    IF NULLIF(it->>'order_item_id','') IS NOT NULL THEN
      SELECT * INTO v_item FROM public.sales_order_items WHERE id = (it->>'order_item_id')::UUID FOR UPDATE;
      IF v_item.id IS NULL THEN RAISE EXCEPTION 'Item pesanan tidak ditemukan.'; END IF;
      IF v_item.qty_delivered + (it->>'qty')::NUMERIC > v_item.qty THEN
        RAISE EXCEPTION 'Kuantitas kirim melebihi sisa pesanan (sisa %).', v_item.qty - v_item.qty_delivered;
      END IF;
      UPDATE public.sales_order_items SET qty_delivered = qty_delivered + (it->>'qty')::NUMERIC WHERE id = v_item.id;
    END IF;
    SELECT average_cost INTO v_cost FROM public.products WHERE id = (it->>'product_id')::UUID;
    INSERT INTO public.delivery_items (delivery_id, order_item_id, product_id, qty, unit_cost)
    VALUES (v_id, NULLIF(it->>'order_item_id','')::UUID, (it->>'product_id')::UUID, (it->>'qty')::NUMERIC, COALESCE(v_cost,0))
    RETURNING id INTO v_line;
    PERFORM private.apply_movement((it->>'product_id')::UUID, _warehouse_id, 'sales_delivery', 'delivery',
      v_id, v_line, v_no, 0, (it->>'qty')::NUMERIC, COALESCE(v_cost,0), _date, 'Pengiriman ' || v_no);
    v_cogs := v_cogs + round((it->>'qty')::NUMERIC * COALESCE(v_cost,0), 2);
  END LOOP;

  IF _order_id IS NOT NULL THEN
    UPDATE public.sales_orders SET status = CASE
      WHEN NOT EXISTS (SELECT 1 FROM public.sales_order_items WHERE order_id = _order_id AND qty_delivered < qty) THEN 'completed'
      ELSE 'partial' END
    WHERE id = _order_id;
  END IF;

  IF v_cogs > 0 THEN
    PERFORM private.create_journal(_date, 'Harga pokok pengiriman ' || v_no, 'delivery', v_id,
      jsonb_build_array(
        jsonb_build_object('account_id', private.account_id('5000'), 'debit', v_cogs, 'credit', 0, 'description', 'Harga pokok penjualan'),
        jsonb_build_object('account_id', private.account_id('1300'), 'debit', 0, 'credit', v_cogs, 'description', 'Persediaan keluar')
      ), true);
  END IF;

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'create', 'delivery', v_id, v_no);
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.post_sales_invoice(_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.sales_invoices; v_lines JSONB; v_journal UUID; v_debit UUID;
BEGIN
  PERFORM public.assert_can('sales','post');
  SELECT * INTO v FROM public.sales_invoices WHERE id = _id FOR UPDATE;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Faktur penjualan tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Faktur ini sudah diposting atau dibatalkan.'; END IF;
  IF v.grand_total <= 0 THEN RAISE EXCEPTION 'Nilai faktur harus lebih besar dari 0.'; END IF;
  IF v.payment_term = 'credit' AND v.due_date IS NULL THEN RAISE EXCEPTION 'Faktur kredit wajib memiliki tanggal jatuh tempo.'; END IF;

  v_debit := CASE WHEN v.payment_term = 'cash' THEN COALESCE(v.cash_account_id, private.account_id('1000'))
                  ELSE private.account_id('1200') END;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_debit, 'debit', v.grand_total, 'credit', 0, 'description',
      CASE WHEN v.payment_term = 'cash' THEN 'Penerimaan tunai' ELSE 'Piutang usaha' END),
    jsonb_build_object('account_id', private.account_id('4000'), 'debit', 0, 'credit', v.subtotal - v.discount_total, 'description', 'Penjualan'),
    jsonb_build_object('account_id', private.account_id('2100'), 'debit', 0, 'credit', v.tax_total, 'description', 'PPN Keluaran')
  );
  IF v.tax_total = 0 THEN v_lines := v_lines - 2; END IF;

  v_journal := private.create_journal(v.doc_date, 'Faktur penjualan ' || v.doc_number, 'sales_invoice', v.id, v_lines, true);

  UPDATE public.sales_invoices SET status = 'posted', posted_by = auth.uid(), posted_at = now(),
    paid_amount = CASE WHEN v.payment_term = 'cash' THEN v.grand_total ELSE paid_amount END,
    payment_status = CASE WHEN v.payment_term = 'cash' THEN 'paid'::public.payment_status ELSE payment_status END
  WHERE id = _id;

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'post', 'sales_invoice', _id, v.doc_number);
  RETURN v_journal;
END; $$;

CREATE OR REPLACE FUNCTION public.create_customer_payment(
  _customer_id UUID, _cash_account_id UUID, _date DATE, _method TEXT, _reference_no TEXT,
  _allocations JSONB, _notes TEXT DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_id UUID; v_no TEXT; al JSONB; v_inv public.sales_invoices; v_total NUMERIC(18,2) := 0; v_amt NUMERIC(18,2);
BEGIN
  PERFORM public.assert_can('sales','create');
  IF jsonb_array_length(COALESCE(_allocations,'[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Pilih minimal satu faktur.'; END IF;
  FOR al IN SELECT * FROM jsonb_array_elements(_allocations) LOOP
    v_total := v_total + (al->>'amount')::NUMERIC;
  END LOOP;
  IF v_total <= 0 THEN RAISE EXCEPTION 'Jumlah pembayaran harus lebih besar dari 0.'; END IF;

  v_no := private.next_number('TR', _date);
  INSERT INTO public.customer_payments (doc_number, doc_date, customer_id, cash_account_id, method, reference_no, amount, notes, created_by)
  VALUES (v_no, _date, _customer_id, _cash_account_id, COALESCE(_method,'transfer'), _reference_no, v_total, _notes, auth.uid())
  RETURNING id INTO v_id;

  FOR al IN SELECT * FROM jsonb_array_elements(_allocations) LOOP
    v_amt := round((al->>'amount')::NUMERIC, 2);
    SELECT * INTO v_inv FROM public.sales_invoices WHERE id = (al->>'invoice_id')::UUID FOR UPDATE;
    IF v_inv.id IS NULL THEN RAISE EXCEPTION 'Faktur tidak ditemukan.'; END IF;
    IF v_inv.status <> 'posted' THEN RAISE EXCEPTION 'Faktur % belum diposting.', v_inv.doc_number; END IF;
    IF v_amt > (v_inv.grand_total - v_inv.paid_amount) THEN
      RAISE EXCEPTION 'Pembayaran melebihi sisa piutang faktur % (sisa %).', v_inv.doc_number, v_inv.grand_total - v_inv.paid_amount;
    END IF;
    INSERT INTO public.customer_payment_allocations (payment_id, invoice_id, amount) VALUES (v_id, v_inv.id, v_amt);
    UPDATE public.sales_invoices SET paid_amount = paid_amount + v_amt,
      payment_status = CASE WHEN paid_amount + v_amt >= grand_total THEN 'paid'::public.payment_status ELSE 'partial'::public.payment_status END
    WHERE id = v_inv.id;
  END LOOP;

  PERFORM private.create_journal(_date, 'Penerimaan pembayaran ' || v_no, 'customer_payment', v_id,
    jsonb_build_array(
      jsonb_build_object('account_id', _cash_account_id, 'debit', v_total, 'credit', 0, 'description', 'Kas/Bank masuk'),
      jsonb_build_object('account_id', private.account_id('1200'), 'debit', 0, 'credit', v_total, 'description', 'Pelunasan piutang usaha')
    ), true);

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'payment', 'customer_payment', v_id, v_no);
  RETURN v_id;
END; $$;

-- sales return: _items = [{product_id, qty, unit_price}]
CREATE OR REPLACE FUNCTION public.create_sales_return(
  _customer_id UUID, _invoice_id UUID, _warehouse_id UUID, _date DATE, _reason TEXT, _restock BOOLEAN, _items JSONB
) RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_id UUID; v_no TEXT; it JSONB; v_line UUID; v_total NUMERIC(18,2) := 0; v_amt NUMERIC(18,2);
        v_cogs NUMERIC(18,2) := 0; v_cost NUMERIC(18,4); v_inv public.sales_invoices; v_credit UUID; v_lines JSONB;
BEGIN
  PERFORM public.assert_can('sales','create');
  IF jsonb_array_length(COALESCE(_items,'[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Minimal satu item retur.'; END IF;
  v_no := private.next_number('RJ', _date);
  INSERT INTO public.sales_returns (doc_number, doc_date, customer_id, invoice_id, warehouse_id, reason, restock, created_by)
  VALUES (v_no, _date, _customer_id, _invoice_id, _warehouse_id, _reason, COALESCE(_restock,true), auth.uid())
  RETURNING id INTO v_id;

  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    v_amt := round((it->>'qty')::NUMERIC * COALESCE((it->>'unit_price')::NUMERIC,0), 2);
    v_total := v_total + v_amt;
    SELECT average_cost INTO v_cost FROM public.products WHERE id = (it->>'product_id')::UUID;
    INSERT INTO public.sales_return_items (return_id, product_id, qty, unit_price, line_total)
    VALUES (v_id, (it->>'product_id')::UUID, (it->>'qty')::NUMERIC, COALESCE((it->>'unit_price')::NUMERIC,0), v_amt)
    RETURNING id INTO v_line;
    IF COALESCE(_restock,true) THEN
      PERFORM private.apply_movement((it->>'product_id')::UUID, _warehouse_id, 'sales_return', 'sales_return',
        v_id, v_line, v_no, (it->>'qty')::NUMERIC, 0, COALESCE(v_cost,0), _date, 'Retur penjualan ' || v_no);
      v_cogs := v_cogs + round((it->>'qty')::NUMERIC * COALESCE(v_cost,0), 2);
    END IF;
  END LOOP;

  UPDATE public.sales_returns SET total_amount = v_total WHERE id = v_id;

  SELECT * INTO v_inv FROM public.sales_invoices WHERE id = _invoice_id;
  v_credit := CASE WHEN v_inv.id IS NOT NULL AND v_inv.payment_term = 'cash'
                   THEN COALESCE(v_inv.cash_account_id, private.account_id('1000'))
                   ELSE private.account_id('1200') END;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', private.account_id('4200'), 'debit', v_total, 'credit', 0, 'description', 'Retur penjualan'),
    jsonb_build_object('account_id', v_credit, 'debit', 0, 'credit', v_total, 'description', 'Pengurangan piutang/kas')
  );
  IF v_cogs > 0 THEN
    v_lines := v_lines
      || jsonb_build_array(jsonb_build_object('account_id', private.account_id('1300'), 'debit', v_cogs, 'credit', 0, 'description', 'Persediaan masuk kembali'))
      || jsonb_build_array(jsonb_build_object('account_id', private.account_id('5000'), 'debit', 0, 'credit', v_cogs, 'description', 'Koreksi harga pokok'));
  END IF;
  PERFORM private.create_journal(_date, 'Retur penjualan ' || v_no, 'sales_return', v_id, v_lines, true);

  IF _invoice_id IS NOT NULL THEN
    UPDATE public.sales_invoices SET paid_amount = LEAST(grand_total, paid_amount + v_total),
      payment_status = CASE WHEN LEAST(grand_total, paid_amount + v_total) >= grand_total THEN 'paid'::public.payment_status ELSE 'partial'::public.payment_status END
    WHERE id = _invoice_id;
  END IF;

  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'create', 'sales_return', v_id, v_no);
  RETURN v_id;
END; $$;

-- grants + RLS
DO $do$
DECLARE t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY['sales_orders','sales_order_items','deliveries','delivery_items',
      'sales_invoices','sales_invoice_items','customer_payments','customer_payment_allocations',
      'sales_returns','sales_return_items'])
  LOOP
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.can(''sales'',''view''))', t||'_view', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (public.can(''sales'',''create''))', t||'_insert', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (public.can(''sales'',''edit'')) WITH CHECK (public.can(''sales'',''edit''))', t||'_update', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (public.can(''sales'',''delete''))', t||'_delete', t);
  END LOOP;
END $do$;

CREATE TRIGGER trg_so_updated BEFORE UPDATE ON public.sales_orders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_do_updated BEFORE UPDATE ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_si_updated BEFORE UPDATE ON public.sales_invoices FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_cp_updated BEFORE UPDATE ON public.customer_payments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_sr_updated BEFORE UPDATE ON public.sales_returns FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();