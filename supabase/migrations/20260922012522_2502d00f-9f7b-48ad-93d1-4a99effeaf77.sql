-- ============ STOCK ADJUSTMENT ============
CREATE OR REPLACE FUNCTION public.apply_stock_adjustment(_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.stock_adjustments; it RECORD; v_value NUMERIC(18,2) := 0; v_cost NUMERIC(18,4); v_lines JSONB;
BEGIN
  PERFORM public.assert_can('inventory','edit');
  SELECT * INTO v FROM public.stock_adjustments WHERE id = _id FOR UPDATE;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Dokumen penyesuaian tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Penyesuaian ini sudah diproses.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stock_adjustment_items WHERE adjustment_id = _id) THEN
    RAISE EXCEPTION 'Minimal satu item penyesuaian.'; END IF;

  FOR it IN SELECT * FROM public.stock_adjustment_items WHERE adjustment_id = _id LOOP
    SELECT average_cost INTO v_cost FROM public.products WHERE id = it.product_id;
    PERFORM private.apply_movement(it.product_id, v.warehouse_id, 'stock_adjustment', 'stock_adjustment',
      v.id, it.id, v.doc_number, GREATEST(it.qty_change,0), GREATEST(-it.qty_change,0), COALESCE(v_cost,0), v.doc_date, v.reason);
    v_value := v_value + round(it.qty_change * COALESCE(v_cost,0), 2);
  END LOOP;

  IF v_value <> 0 THEN
    IF v_value > 0 THEN
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', private.account_id('1300'), 'debit', v_value, 'credit', 0, 'description','Penambahan persediaan'),
        jsonb_build_object('account_id', private.account_id('5200'), 'debit', 0, 'credit', v_value, 'description','Selisih persediaan'));
    ELSE
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', private.account_id('5200'), 'debit', -v_value, 'credit', 0, 'description','Selisih persediaan'),
        jsonb_build_object('account_id', private.account_id('1300'), 'debit', 0, 'credit', -v_value, 'description','Pengurangan persediaan'));
    END IF;
    PERFORM private.create_journal(v.doc_date, 'Penyesuaian stok ' || v.doc_number, 'stock_adjustment', v.id, v_lines, true);
  END IF;

  UPDATE public.stock_adjustments SET status = 'approved', approved_by = auth.uid(), approved_at = now() WHERE id = _id;
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'approve', 'stock_adjustment', _id, v.doc_number);
END; $$;

-- ============ WAREHOUSE TRANSFER ============
CREATE OR REPLACE FUNCTION public.apply_stock_transfer(_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.stock_transfers; it RECORD; v_cost NUMERIC(18,4);
BEGIN
  PERFORM public.assert_can('inventory','edit');
  SELECT * INTO v FROM public.stock_transfers WHERE id = _id FOR UPDATE;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Dokumen transfer tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Transfer ini sudah diproses.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.stock_transfer_items WHERE transfer_id = _id) THEN
    RAISE EXCEPTION 'Minimal satu item transfer.'; END IF;

  FOR it IN SELECT * FROM public.stock_transfer_items WHERE transfer_id = _id LOOP
    SELECT average_cost INTO v_cost FROM public.products WHERE id = it.product_id;
    PERFORM private.apply_movement(it.product_id, v.from_warehouse_id, 'warehouse_transfer_out', 'stock_transfer',
      v.id, it.id, v.doc_number, 0, it.qty, COALESCE(v_cost,0), v.doc_date, 'Transfer keluar ' || v.doc_number);
    PERFORM private.apply_movement(it.product_id, v.to_warehouse_id, 'warehouse_transfer_in', 'stock_transfer',
      v.id, it.id, v.doc_number, it.qty, 0, COALESCE(v_cost,0), v.doc_date, 'Transfer masuk ' || v.doc_number);
  END LOOP;

  UPDATE public.stock_transfers SET status = 'completed' WHERE id = _id;
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'post', 'stock_transfer', _id, v.doc_number);
END; $$;

-- ============ STOCK OPNAME ============
CREATE OR REPLACE FUNCTION public.apply_stock_opname(_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.stock_opnames; it RECORD; v_cost NUMERIC(18,4); v_value NUMERIC(18,2) := 0; v_lines JSONB;
BEGIN
  PERFORM public.assert_can('inventory','edit');
  SELECT * INTO v FROM public.stock_opnames WHERE id = _id FOR UPDATE;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Dokumen opname tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Opname ini sudah diproses.'; END IF;

  FOR it IN SELECT * FROM public.stock_opname_items WHERE opname_id = _id AND physical_qty <> system_qty LOOP
    SELECT average_cost INTO v_cost FROM public.products WHERE id = it.product_id;
    PERFORM private.apply_movement(it.product_id, v.warehouse_id, 'opname_adjustment', 'stock_opname',
      v.id, it.id, v.doc_number, GREATEST(it.difference,0), GREATEST(-it.difference,0), COALESCE(v_cost,0), v.doc_date, it.reason);
    v_value := v_value + round(it.difference * COALESCE(v_cost,0), 2);
  END LOOP;

  IF v_value <> 0 THEN
    IF v_value > 0 THEN
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', private.account_id('1300'), 'debit', v_value, 'credit', 0, 'description','Koreksi opname'),
        jsonb_build_object('account_id', private.account_id('5200'), 'debit', 0, 'credit', v_value, 'description','Selisih persediaan'));
    ELSE
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', private.account_id('5200'), 'debit', -v_value, 'credit', 0, 'description','Selisih persediaan'),
        jsonb_build_object('account_id', private.account_id('1300'), 'debit', 0, 'credit', -v_value, 'description','Koreksi opname'));
    END IF;
    PERFORM private.create_journal(v.doc_date, 'Stock opname ' || v.doc_number, 'stock_opname', v.id, v_lines, true);
  END IF;

  UPDATE public.stock_opnames SET status = 'approved', approved_by = auth.uid(), approved_at = now() WHERE id = _id;
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'approve', 'stock_opname', _id, v.doc_number);
END; $$;

-- ============ MANUAL JOURNAL ============
CREATE OR REPLACE FUNCTION public.create_manual_journal(_date DATE, _description TEXT, _lines JSONB, _post BOOLEAN DEFAULT true)
RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  PERFORM public.assert_can('accounting', CASE WHEN _post THEN 'post'::public.perm_action ELSE 'create'::public.perm_action END);
  IF jsonb_array_length(COALESCE(_lines,'[]'::jsonb)) < 2 THEN RAISE EXCEPTION 'Jurnal memerlukan minimal dua baris.'; END IF;
  v_id := private.create_journal(_date, _description, NULL, NULL, _lines, COALESCE(_post,true));
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id)
  VALUES (auth.uid(), CASE WHEN _post THEN 'post' ELSE 'create' END, 'journal_entry', v_id);
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.post_journal_entry(_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.journal_entries; d NUMERIC(18,2); c NUMERIC(18,2);
BEGIN
  PERFORM public.assert_can('accounting','post');
  SELECT * INTO v FROM public.journal_entries WHERE id = _id FOR UPDATE;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Jurnal tidak ditemukan.'; END IF;
  IF v.status <> 'draft' THEN RAISE EXCEPTION 'Jurnal ini sudah diposting atau dibatalkan.'; END IF;
  PERFORM private.assert_period_open(v.entry_date);
  SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0) INTO d, c FROM public.journal_entry_lines WHERE entry_id = _id;
  IF round(d,2) <> round(c,2) THEN RAISE EXCEPTION 'Jurnal tidak seimbang: debit % vs kredit %', d, c; END IF;
  IF round(d,2) = 0 THEN RAISE EXCEPTION 'Jurnal tidak boleh bernilai nol.'; END IF;
  UPDATE public.journal_entries SET status = 'posted', total_debit = round(d,2), total_credit = round(c,2),
    posted_by = auth.uid(), posted_at = now() WHERE id = _id;
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number)
  VALUES (auth.uid(), 'post', 'journal_entry', _id, v.entry_number);
END; $$;

-- reverse a posted journal with a correcting entry
CREATE OR REPLACE FUNCTION public.reverse_journal_entry(_id UUID, _date DATE DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v public.journal_entries; v_lines JSONB; v_new UUID; v_date DATE;
BEGIN
  PERFORM public.assert_can('accounting','cancel');
  SELECT * INTO v FROM public.journal_entries WHERE id = _id FOR UPDATE;
  IF v.id IS NULL THEN RAISE EXCEPTION 'Jurnal tidak ditemukan.'; END IF;
  IF v.status <> 'posted' THEN RAISE EXCEPTION 'Hanya jurnal yang sudah diposting dapat dikoreksi.'; END IF;
  v_date := COALESCE(_date, current_date);
  SELECT jsonb_agg(jsonb_build_object('account_id', account_id, 'debit', credit, 'credit', debit,
                                      'description', 'Koreksi: ' || COALESCE(description,'')))
  INTO v_lines FROM public.journal_entry_lines WHERE entry_id = _id;
  v_new := private.create_journal(v_date, 'Jurnal koreksi untuk ' || v.entry_number, 'journal_reversal', v.id, v_lines, true);
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id, document_number, notes)
  VALUES (auth.uid(), 'cancel', 'journal_entry', _id, v.entry_number, 'Dikoreksi melalui jurnal balik');
  RETURN v_new;
END; $$;

-- ============ PERIOD CONTROL ============
CREATE OR REPLACE FUNCTION public.set_period_closed(_id UUID, _closed BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  PERFORM public.assert_can('accounting','approve');
  UPDATE public.accounting_periods SET is_closed = _closed,
    closed_at = CASE WHEN _closed THEN now() END, closed_by = CASE WHEN _closed THEN auth.uid() END
  WHERE id = _id;
  INSERT INTO public.audit_logs (user_id, action, document_type, document_id)
  VALUES (auth.uid(), CASE WHEN _closed THEN 'close_period' ELSE 'open_period' END, 'accounting_period', _id);
END; $$;

-- ============ REPORTING VIEWS ============
CREATE VIEW public.v_stock_balances WITH (security_invoker = true) AS
SELECT b.id, b.product_id, p.sku, p.name AS product_name, p.min_stock, p.average_cost, u.code AS unit_code,
       c.name AS category_name, b.warehouse_id, w.code AS warehouse_code, w.name AS warehouse_name,
       b.qty_on_hand, round(b.qty_on_hand * p.average_cost, 2) AS stock_value,
       CASE WHEN b.qty_on_hand <= 0 THEN 'habis'
            WHEN b.qty_on_hand <= p.min_stock THEN 'minimum' ELSE 'aman' END AS stock_status,
       b.updated_at
FROM public.inventory_balances b
JOIN public.products p ON p.id = b.product_id
JOIN public.units u ON u.id = p.unit_id
LEFT JOIN public.product_categories c ON c.id = p.category_id
JOIN public.warehouses w ON w.id = b.warehouse_id;

CREATE VIEW public.v_trial_balance WITH (security_invoker = true) AS
SELECT a.id AS account_id, a.code, a.name, a.account_type, a.normal_balance,
       COALESCE(SUM(l.debit),0) AS total_debit, COALESCE(SUM(l.credit),0) AS total_credit,
       CASE WHEN a.normal_balance = 'debit' THEN COALESCE(SUM(l.debit),0) - COALESCE(SUM(l.credit),0)
            ELSE COALESCE(SUM(l.credit),0) - COALESCE(SUM(l.debit),0) END AS balance
FROM public.accounts a
LEFT JOIN public.journal_entry_lines l ON l.account_id = a.id
LEFT JOIN public.journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
WHERE a.is_active
GROUP BY a.id, a.code, a.name, a.account_type, a.normal_balance;

CREATE VIEW public.v_general_ledger WITH (security_invoker = true) AS
SELECT l.id, e.entry_number, e.entry_date, e.description, e.source_type, e.status,
       a.id AS account_id, a.code AS account_code, a.name AS account_name, a.account_type,
       l.debit, l.credit, l.description AS line_description
FROM public.journal_entry_lines l
JOIN public.journal_entries e ON e.id = l.entry_id
JOIN public.accounts a ON a.id = l.account_id
WHERE e.status = 'posted';

CREATE VIEW public.v_ar_aging WITH (security_invoker = true) AS
SELECT i.id AS invoice_id, i.doc_number, i.doc_date, i.due_date, i.customer_id, c.name AS customer_name,
       i.grand_total, i.paid_amount, (i.grand_total - i.paid_amount) AS outstanding,
       GREATEST(0, current_date - COALESCE(i.due_date, i.doc_date)) AS days_overdue,
       CASE WHEN current_date <= COALESCE(i.due_date, i.doc_date) THEN 'belum jatuh tempo'
            WHEN current_date - COALESCE(i.due_date, i.doc_date) <= 30 THEN '1-30 hari'
            WHEN current_date - COALESCE(i.due_date, i.doc_date) <= 60 THEN '31-60 hari'
            WHEN current_date - COALESCE(i.due_date, i.doc_date) <= 90 THEN '61-90 hari'
            ELSE '> 90 hari' END AS aging_bucket
FROM public.sales_invoices i
JOIN public.customers c ON c.id = i.customer_id
WHERE i.status = 'posted' AND i.grand_total > i.paid_amount;

CREATE VIEW public.v_ap_aging WITH (security_invoker = true) AS
SELECT i.id AS invoice_id, i.doc_number, i.doc_date, i.due_date, i.supplier_id, s.name AS supplier_name,
       i.grand_total, i.paid_amount, (i.grand_total - i.paid_amount) AS outstanding,
       GREATEST(0, current_date - COALESCE(i.due_date, i.doc_date)) AS days_overdue,
       CASE WHEN current_date <= COALESCE(i.due_date, i.doc_date) THEN 'belum jatuh tempo'
            WHEN current_date - COALESCE(i.due_date, i.doc_date) <= 30 THEN '1-30 hari'
            WHEN current_date - COALESCE(i.due_date, i.doc_date) <= 60 THEN '31-60 hari'
            WHEN current_date - COALESCE(i.due_date, i.doc_date) <= 90 THEN '61-90 hari'
            ELSE '> 90 hari' END AS aging_bucket
FROM public.purchase_invoices i
JOIN public.suppliers s ON s.id = i.supplier_id
WHERE i.status = 'posted' AND i.grand_total > i.paid_amount;

CREATE VIEW public.v_sales_report WITH (security_invoker = true) AS
SELECT i.id AS invoice_id, i.doc_number, i.doc_date, i.customer_id, c.name AS customer_name,
       it.product_id, p.sku, p.name AS product_name, it.qty, it.unit_price, it.discount, it.line_total,
       i.payment_status, i.status
FROM public.sales_invoices i
JOIN public.sales_invoice_items it ON it.invoice_id = i.id
JOIN public.customers c ON c.id = i.customer_id
JOIN public.products p ON p.id = it.product_id
WHERE i.status = 'posted';

CREATE VIEW public.v_purchase_report WITH (security_invoker = true) AS
SELECT i.id AS invoice_id, i.doc_number, i.doc_date, i.supplier_id, s.name AS supplier_name,
       it.product_id, p.sku, p.name AS product_name, it.qty, it.unit_price, it.discount, it.line_total,
       i.payment_status, i.status
FROM public.purchase_invoices i
JOIN public.purchase_invoice_items it ON it.invoice_id = i.id
JOIN public.suppliers s ON s.id = i.supplier_id
JOIN public.products p ON p.id = it.product_id
WHERE i.status = 'posted';

GRANT SELECT ON public.v_stock_balances, public.v_trial_balance, public.v_general_ledger,
  public.v_ar_aging, public.v_ap_aging, public.v_sales_report, public.v_purchase_report TO authenticated;