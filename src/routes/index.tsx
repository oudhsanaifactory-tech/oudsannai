import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import {
  ArrowDownRight,
  ArrowUpRight,
  BarChart3,
  Bell,
  Boxes,
  ChevronDown,
  CircleDollarSign,
  FileText,
  LayoutDashboard,
  Menu,
  PackageSearch,
  Plus,
  Search,
  Settings,
  ShoppingCart,
  Store,
  Truck,
  Users,
  X,
} from "lucide-react";
import { supabase } from "@/integrations/supabase/client";

const INTERNAL_LOGIN_EMAIL = "oudhsannaifactory@gmail.com";
const DASHBOARD_MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "Mei",
  "Jun",
  "Jul",
  "Agu",
  "Sep",
  "Okt",
  "Nov",
  "Des",
] as const;

// No head() here: the home route inherits title/description/og/twitter from
// __root.tsx, and ships no og:image so serve-time hosting can inject the
// project's social preview (explicit og:image or latest screenshot).
export const Route = createFileRoute("/")({
  component: Index,
});

function Index() {
  return <AuthGate />;
}

function AuthGate() {
  const [session, setSession] =
    useState<Awaited<ReturnType<typeof supabase.auth.getSession>>["data"]["session"]>(null);
  const [roleName, setRoleName] = useState("Auditor");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let mounted = true;
    void supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      setSession(data.session);
      setLoading(false);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      if (mounted) setSession(nextSession);
    });
    return () => {
      mounted = false;
      listener.subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (!session?.user.id) return;
    void supabase
      .from("user_roles")
      .select("role")
      .eq("user_id", session.user.id)
      .order("created_at", { ascending: true })
      .limit(1)
      .maybeSingle()
      .then(({ data }) => {
        if (data?.role) {
          setRoleName(
            data.role.replace("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()),
          );
        }
      });
  }, [session?.user.id]);

  if (loading) return <div className="auth-loading">Memuat sesi Anda...</div>;
  if (!session) return <LoginPanel />;
  return (
    <Dashboard
      email={session.user.email ?? ""}
      roleName={roleName}
      onSignOut={() => supabase.auth.signOut()}
    />
  );
}

function LoginPanel() {
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    const result = await supabase.auth.signInWithPassword({
      email: INTERNAL_LOGIN_EMAIL,
      password,
    });
    setMessage(result.error ? "Email atau password tidak valid." : "Login berhasil.");
    setBusy(false);
  }

  return (
    <main className="auth-page">
      <section className="auth-card">
        <div className="auth-brand">
          <div className="erp-brand-mark">
            <Store size={20} />
          </div>
          <span>
            Oudh Sannai <small>Business System</small>
          </span>
        </div>
        <div className="auth-heading">
          <small>SECURE WORKSPACE</small>
          <h1>Masuk ke workspace Anda</h1>
          <p>Akses internal untuk mengelola operasi bisnis Oudh Sannai.</p>
        </div>
        <form onSubmit={submit} className="auth-form">
          <label>
            Akun internal
            <input type="email" value={INTERNAL_LOGIN_EMAIL} readOnly aria-readonly="true" />
          </label>
          <label>
            Password
            <input
              type="password"
              required
              autoComplete="current-password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              placeholder="Masukkan password"
            />
          </label>
          {message && <p className="auth-message">{message}</p>}
          <button className="erp-primary auth-submit" disabled={busy}>
            {busy ? "Memproses..." : "Masuk"}
          </button>
        </form>
      </section>
    </main>
  );
}

function Dashboard({
  email,
  roleName,
  onSignOut,
}: {
  email: string;
  roleName: string;
  onSignOut: () => void;
}) {
  const [activePage, setActivePage] = useState("Overview");
  const [period, setPeriod] = useState("Tahun ini");
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [masterEntity, setMasterEntity] = useState<MasterEntity | null>(null);
  const [inventoryTransactionOpen, setInventoryTransactionOpen] = useState(false);
  const [dashboardData, setDashboardData] = useState<DashboardData>(emptyDashboardData);
  const [dashboardLoading, setDashboardLoading] = useState(true);
  const [dashboardError, setDashboardError] = useState("");

  const navigation = [
    ["Overview", LayoutDashboard],
    ["Penjualan", ShoppingCart],
    ["Pembelian", Truck],
    ["Persediaan", Boxes],
    ["Keuangan", CircleDollarSign],
    ["Laporan", BarChart3],
  ] as const;

  const months = DASHBOARD_MONTHS;

  const loadDashboardData = useCallback(async () => {
    setDashboardLoading(true);
    setDashboardError("");
    const yearStart = `${new Date().getFullYear()}-01-01`;
    const [invoiceResult, receivableResult, stockResult, productResult] = await Promise.all([
      supabase
        .from("sales_invoices")
        .select(
          "doc_number, doc_date, grand_total, paid_amount, payment_status, status, customers(name)",
        )
        .eq("status", "posted")
        .gte("doc_date", yearStart)
        .order("doc_date", { ascending: false }),
      supabase.from("v_ar_aging").select("outstanding").order("days_overdue", { ascending: false }),
      supabase
        .from("v_stock_balances")
        .select("product_name, sku, qty_on_hand, min_stock, stock_status, stock_value, unit_code")
        .order("stock_status")
        .order("qty_on_hand"),
      supabase.from("products").select("id", { count: "exact", head: true }).eq("is_active", true),
    ]);

    const firstError =
      invoiceResult.error ?? receivableResult.error ?? stockResult.error ?? productResult.error;
    if (firstError) {
      setDashboardError(firstError.message);
      setDashboardLoading(false);
      return;
    }

    const invoices = (invoiceResult.data ?? []) as unknown as DashboardInvoice[];
    const receivables = (receivableResult.data ?? []) as unknown as DashboardReceivable[];
    const stock = (stockResult.data ?? []) as unknown as DashboardStock[];
    const monthlySales = months.map((month, index) =>
      invoices
        .filter((invoice) => new Date(invoice.doc_date).getMonth() === index)
        .reduce((total, invoice) => total + Number(invoice.grand_total || 0), 0),
    );
    const maxMonthlySales = Math.max(...monthlySales, 1);

    setDashboardData({
      salesTotal: invoices.reduce((total, invoice) => total + Number(invoice.grand_total || 0), 0),
      orderCount: invoices.length,
      receivableTotal: receivables.reduce(
        (total, item) => total + Number(item.outstanding || 0),
        0,
      ),
      inventoryValue: stock.reduce((total, item) => total + Number(item.stock_value || 0), 0),
      activeProducts: productResult.count ?? 0,
      sales: monthlySales.map((value) => (value / maxMonthlySales) * 100),
      monthlySales,
      recentInvoices: invoices.slice(0, 4),
      lowStock: stock.filter((item) => item.stock_status !== "aman").slice(0, 4),
    });
    setDashboardLoading(false);
  }, [months]);

  useEffect(() => {
    void loadDashboardData();
  }, [loadDashboardData]);

  return (
    <div className="erp-shell">
      <aside className={`erp-sidebar ${sidebarOpen ? "is-open" : ""}`}>
        <div className="erp-brand">
          <div className="erp-brand-mark">
            <Store size={19} />
          </div>
          <div>
            <strong>Oudh Sannai</strong>
            <span>Business System</span>
          </div>
          <button
            className="erp-icon mobile-only"
            onClick={() => setSidebarOpen(false)}
            aria-label="Tutup navigasi"
          >
            <X size={18} />
          </button>
        </div>
        <div className="erp-workspace">
          <div className="erp-workspace-avatar">OS</div>
          <div>
            <strong>Oudh Sannai Factory</strong>
            <span>Workspace utama</span>
          </div>
          <ChevronDown size={14} />
        </div>
        <nav className="erp-nav" aria-label="Navigasi utama">
          <small>Workspace</small>
          {navigation.map(([label, Icon]) => (
            <button
              key={label}
              className={activePage === label ? "active" : ""}
              onClick={() => {
                setActivePage(label);
                setSidebarOpen(false);
                if (label === "Persediaan") setInventoryTransactionOpen(true);
              }}
            >
              <Icon size={17} />
              <span>{label}</span>
              {label === "Persediaan" && <em>3</em>}
            </button>
          ))}
          <small className="nav-gap">Master Data</small>
          <button onClick={() => setMasterEntity("customers")}>
            <Users size={17} />
            <span>Pelanggan</span>
          </button>
          <button onClick={() => setMasterEntity("suppliers")}>
            <Truck size={17} />
            <span>Pemasok</span>
          </button>
          <button onClick={() => setMasterEntity("products")}>
            <PackageSearch size={17} />
            <span>Produk & Jasa</span>
          </button>
        </nav>
        <div className="erp-sidebar-bottom">
          <button className="erp-nav-button">
            <Settings size={17} />
            <span>Pengaturan</span>
          </button>
          <button className="erp-profile" onClick={onSignOut} title="Logout">
            <div>NA</div>
            <span>
              <strong>{email}</strong>
              <small>{roleName} · Logout</small>
            </span>
            <ChevronDown size={14} />
          </button>
        </div>
      </aside>
      {sidebarOpen && (
        <button
          className="erp-scrim"
          onClick={() => setSidebarOpen(false)}
          aria-label="Tutup menu"
        />
      )}
      <main className="erp-main">
        <header className="erp-topbar">
          <button
            className="erp-icon mobile-only"
            onClick={() => setSidebarOpen(true)}
            aria-label="Buka navigasi"
          >
            <Menu size={20} />
          </button>
          <div className="erp-crumb">
            <span>Workspace</span>
            <b>/</b>
            <strong>{activePage}</strong>
          </div>
          <div className="erp-top-actions">
            <button className="erp-icon desktop-only" aria-label="Cari">
              <Search size={17} />
            </button>
            <button className="erp-icon" aria-label="Notifikasi">
              <Bell size={17} />
              <i />
            </button>
            <div className="erp-top-avatar">NA</div>
          </div>
        </header>
        <div className="erp-page">
          {masterEntity && (
            <MasterDataPanel
              entity={masterEntity}
              onClose={() => setMasterEntity(null)}
              onChanged={loadDashboardData}
            />
          )}
          {inventoryTransactionOpen && (
            <InventoryAdjustmentPanel
              onClose={() => setInventoryTransactionOpen(false)}
              onChanged={loadDashboardData}
            />
          )}
          <section className="erp-intro">
            <div>
              <small>Selasa, 24 September 2024</small>
              <h1>Selamat pagi, Nurhadi.</h1>
              <p>Berikut ringkasan performa bisnis Anda hari ini.</p>
            </div>
            <div className="erp-actions">
              <button className="erp-secondary">
                <FileText size={15} /> Export laporan
              </button>
              <button className="erp-primary" onClick={() => setInventoryTransactionOpen(true)}>
                <Plus size={16} /> Transaksi baru
              </button>
            </div>
          </section>
          <section className="erp-metrics">
            <Metric
              icon={CircleDollarSign}
              label="Total penjualan"
              value={formatCurrency(dashboardData.salesTotal)}
              change={dashboardLoading ? "..." : `${dashboardData.orderCount} invoice`}
              detail="tahun berjalan"
              color="green"
            />
            <Metric
              icon={ShoppingCart}
              label="Pesanan masuk"
              value={dashboardData.orderCount.toLocaleString("id-ID")}
              change={dashboardLoading ? "..." : "terposting"}
              detail="invoice tahun berjalan"
              color="blue"
            />
            <Metric
              icon={FileText}
              label="Piutang usaha"
              value={formatCurrency(dashboardData.receivableTotal)}
              change={dashboardLoading ? "..." : "aktif"}
              detail="saldo belum tertagih"
              color="amber"
              down
            />
            <Metric
              icon={Boxes}
              label="Nilai persediaan"
              value={formatCurrency(dashboardData.inventoryValue)}
              change={dashboardLoading ? "..." : `${dashboardData.activeProducts} produk`}
              detail="nilai stok saat ini"
              color="red"
            />
          </section>
          <section className="erp-two-col">
            <div className="erp-panel">
              <PanelTitle
                title="Ikhtisar penjualan"
                subtitle="Pendapatan bersih selama periode berjalan"
              >
                <label className="erp-select">
                  <select
                    value={period}
                    onChange={(event) => setPeriod(event.target.value)}
                    aria-label="Pilih periode"
                  >
                    <option>Tahun ini</option>
                    <option>6 bulan terakhir</option>
                    <option>Bulan ini</option>
                  </select>
                  <ChevronDown size={13} />
                </label>
              </PanelTitle>
              <div className="erp-legend">
                <span>
                  <i className="dot sales" /> Penjualan
                </span>
                <span>
                  <i className="dot target" /> Target
                </span>
              </div>
              <div className="erp-chart">
                <div className="erp-y-axis">
                  <span>100 jt</span>
                  <span>75 jt</span>
                  <span>50 jt</span>
                  <span>25 jt</span>
                  <span>0</span>
                </div>
                <div className="erp-chart-body">
                  <div className="erp-grid-lines">
                    <i />
                    <i />
                    <i />
                    <i />
                    <i />
                  </div>
                  <div className="erp-bars">
                    {dashboardData.sales.map((value, index) => (
                      <div className="erp-bar-wrap" key={months[index]}>
                        <div
                          className="erp-bar"
                          style={{ height: `${value}%` }}
                          title={`${months[index]}: ${formatCurrency(dashboardData.monthlySales[index])}`}
                        />
                        <span>{months[index]}</span>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
              <div className="erp-chart-footer">
                <span>
                  <b>{formatCurrency(dashboardData.salesTotal)}</b> total penjualan
                </span>
                <strong>
                  {dashboardLoading
                    ? "Memuat data..."
                    : `${dashboardData.orderCount} invoice terposting`}
                </strong>
              </div>
            </div>
            <div className="erp-panel">
              <PanelTitle title="Arus kas" subtitle="Posisi kas dan bank saat ini">
                <button className="erp-more">•••</button>
              </PanelTitle>
              <div className="erp-cash-total">
                <span>Saldo tersedia</span>
                <b>Rp 156,8 jt</b>
                <strong>
                  <ArrowUpRight size={13} /> 6,4% dibanding bulan lalu
                </strong>
              </div>
              <CashBar label="Pemasukan" amount="Rp 346,2 jt" width="82%" color="income" />
              <CashBar label="Pengeluaran" amount="Rp 189,4 jt" width="54%" color="expense" />
              <div className="erp-cash-breakdown">
                <span>
                  <i className="dot income" /> Pemasukan <b>64%</b>
                </span>
                <span>
                  <i className="dot expense" /> Pengeluaran <b>36%</b>
                </span>
              </div>
            </div>
          </section>
          <section className="erp-two-col lower">
            <div className="erp-panel">
              <PanelTitle title="Invoice terbaru" subtitle="Transaksi penjualan terakhir">
                <button className="erp-link">
                  Lihat semua <ArrowUpRight size={14} />
                </button>
              </PanelTitle>
              <div className="erp-table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th>Nomor invoice</th>
                      <th>Pelanggan</th>
                      <th>Tanggal</th>
                      <th>Total</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {dashboardData.recentInvoices.map((invoice) => {
                      const status = invoice.payment_status === "paid" ? "Lunas" : "Belum lunas";
                      const tone = invoice.payment_status === "paid" ? "paid" : "waiting";
                      return (
                        <tr key={invoice.doc_number}>
                          <td>
                            <b>{invoice.doc_number}</b>
                          </td>
                          <td>{invoice.customers?.name ?? "-"}</td>
                          <td>{formatDate(invoice.doc_date)}</td>
                          <td>
                            <b>{formatCurrency(invoice.grand_total)}</b>
                          </td>
                          <td>
                            <em className={`erp-status ${tone}`}>{status}</em>
                          </td>
                        </tr>
                      );
                    })}
                    {!dashboardData.recentInvoices.length && (
                      <tr>
                        <td colSpan={5} className="master-empty">
                          Belum ada invoice terposting.
                        </td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
            </div>
            <div className="erp-panel">
              <PanelTitle title="Stok perlu perhatian" subtitle="Produk dengan stok minimum">
                <button className="erp-link">
                  Kelola <ArrowUpRight size={14} />
                </button>
              </PanelTitle>
              <div className="erp-stock-list">
                {dashboardData.lowStock.map((item) => {
                  const level =
                    item.stock_status === "habis"
                      ? "critical"
                      : item.stock_status === "minimum"
                        ? "low"
                        : "medium";
                  return (
                    <div className="erp-stock" key={`${item.sku}-${item.product_name}`}>
                      <div className={`erp-stock-icon ${level}`}>
                        <Boxes size={16} />
                      </div>
                      <span>
                        <b>{item.product_name}</b>
                        <small>{item.sku}</small>
                      </span>
                      <strong className={level}>
                        {Number(item.qty_on_hand || 0).toLocaleString("id-ID")}{" "}
                        {item.unit_code ?? "unit"}
                        <small>
                          {level === "critical"
                            ? "Kritis"
                            : level === "low"
                              ? "Menipis"
                              : "Perhatian"}
                        </small>
                      </strong>
                    </div>
                  );
                })}
                {!dashboardData.lowStock.length && <p className="master-empty">Semua stok aman.</p>}
              </div>
            </div>
          </section>
          {dashboardError && (
            <p className="master-error">Gagal memuat data dashboard: {dashboardError}</p>
          )}
        </div>
      </main>
    </div>
  );
}

type InventoryAdjustment = {
  id: string;
  doc_number: string;
  doc_date: string;
  warehouse_id: string;
  reason: string;
  status: string;
  notes: string | null;
  warehouses: { code: string; name: string } | null;
};
type InventoryAdjustmentItem = {
  id?: string;
  product_id: string;
  qty_change: number;
  notes?: string | null;
  products?: { sku: string; name: string } | null;
};

function InventoryAdjustmentPanel({
  onClose,
  onChanged,
}: {
  onClose: () => void;
  onChanged: () => Promise<void>;
}) {
  const [records, setRecords] = useState<InventoryAdjustment[]>([]);
  const [products, setProducts] = useState<{ id: string; sku: string; name: string }[]>([]);
  const [warehouses, setWarehouses] = useState<{ id: string; code: string; name: string }[]>([]);
  const [editing, setEditing] = useState<InventoryAdjustment | null>(null);
  const [items, setItems] = useState<InventoryAdjustmentItem[]>([]);
  const [form, setForm] = useState({
    doc_date: new Date().toISOString().slice(0, 10),
    warehouse_id: "",
    reason: "",
    notes: "",
    product_id: "",
    qty_change: "",
    item_notes: "",
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const loadRecords = useCallback(async () => {
    setBusy(true);
    setError("");
    const { data, error: queryError } = await supabase
      .from("stock_adjustments")
      .select("*, warehouses(code, name)")
      .order("doc_date", { ascending: false });
    if (queryError) setError(queryError.message);
    else setRecords((data ?? []) as unknown as InventoryAdjustment[]);
    setBusy(false);
  }, []);

  useEffect(() => {
    void loadRecords();
    void Promise.all([
      supabase.from("products").select("id, sku, name").eq("is_active", true).order("name"),
      supabase.from("warehouses").select("id, code, name").eq("is_active", true).order("name"),
    ]).then(([productResult, warehouseResult]) => {
      if (productResult.error || warehouseResult.error) {
        setError(productResult.error?.message ?? warehouseResult.error?.message ?? "Gagal memuat referensi.");
        return;
      }
      setProducts(productResult.data ?? []);
      setWarehouses(warehouseResult.data ?? []);
      setForm((current) => ({
        ...current,
        warehouse_id: current.warehouse_id || warehouseResult.data?.[0]?.id || "",
        product_id: current.product_id || productResult.data?.[0]?.id || "",
      }));
    });
  }, [loadRecords]);

  function resetForm() {
    setEditing(null);
    setItems([]);
    setForm({
      doc_date: new Date().toISOString().slice(0, 10),
      warehouse_id: warehouses[0]?.id || "",
      reason: "",
      notes: "",
      product_id: products[0]?.id || "",
      qty_change: "",
      item_notes: "",
    });
  }

  async function selectRecord(record: InventoryAdjustment) {
    setError("");
    const { data, error: itemError } = await supabase
      .from("stock_adjustment_items")
      .select("id, product_id, qty_change, notes, products(sku, name)")
      .eq("adjustment_id", record.id)
      .order("id");
    if (itemError) {
      setError(itemError.message);
      return;
    }
    setEditing(record);
    setItems((data ?? []) as unknown as InventoryAdjustmentItem[]);
    setForm({
      doc_date: record.doc_date,
      warehouse_id: record.warehouse_id,
      reason: record.reason,
      notes: record.notes ?? "",
      product_id: products[0]?.id || "",
      qty_change: "",
      item_notes: "",
    });
  }

  function addItem() {
    const qty = Number(form.qty_change);
    if (!form.product_id || !Number.isFinite(qty) || qty === 0) {
      setError("Pilih produk dan isi perubahan stok selain 0.");
      return;
    }
    const product = products.find((item) => item.id === form.product_id);
    setItems((current) => [
      ...current.filter((item) => item.product_id !== form.product_id),
      { product_id: form.product_id, qty_change: qty, notes: form.item_notes || null, products: product },
    ]);
    setForm((current) => ({ ...current, qty_change: "", item_notes: "" }));
    setError("");
  }

  async function saveDraft(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!form.warehouse_id || !form.reason.trim() || !items.length) {
      setError("Gudang, alasan, dan minimal satu item wajib diisi.");
      return;
    }
    setBusy(true);
    setError("");
    const header = {
      doc_date: form.doc_date,
      warehouse_id: form.warehouse_id,
      reason: form.reason.trim(),
      notes: form.notes.trim() || null,
    };
    let adjustmentId = editing?.id;
    const headerResult = editing
      ? await supabase.from("stock_adjustments").update(header).eq("id", editing.id)
      : await supabase
          .from("stock_adjustments")
          .insert({ ...header, doc_number: `ADJ-${Date.now()}` })
          .select("id")
          .single();
    if (headerResult.error) {
      setError(headerResult.error.message);
      setBusy(false);
      return;
    }
    adjustmentId = adjustmentId ?? (headerResult.data as { id: string }).id;
    if (editing) await supabase.from("stock_adjustment_items").delete().eq("adjustment_id", editing.id);
    const itemResult = await supabase.from("stock_adjustment_items").insert(
      items.map((item) => ({
        adjustment_id: adjustmentId,
        product_id: item.product_id,
        qty_change: item.qty_change,
        notes: item.notes ?? null,
      })),
    );
    if (itemResult.error) setError(itemResult.error.message);
    else {
      resetForm();
      await loadRecords();
      await onChanged();
    }
    setBusy(false);
  }

  async function applyRecord(record: InventoryAdjustment) {
    if (!window.confirm(`Proses ${record.doc_number}? Stok akan berubah dan transaksi tidak dapat diedit.`)) return;
    setBusy(true);
    const { error: applyError } = await supabase.rpc("apply_stock_adjustment", { _id: record.id });
    if (applyError) setError(applyError.message);
    else {
      await loadRecords();
      await onChanged();
    }
    setBusy(false);
  }

  async function deleteRecord(record: InventoryAdjustment) {
    if (record.status !== "draft") return;
    if (!window.confirm(`Hapus ${record.doc_number}?`)) return;
    setBusy(true);
    const { error: deleteError } = await supabase.from("stock_adjustments").delete().eq("id", record.id);
    if (deleteError) setError(deleteError.message);
    else {
      if (editing?.id === record.id) resetForm();
      await loadRecords();
    }
    setBusy(false);
  }

  return (
    <section className="master-panel inventory-panel">
      <div className="master-header">
        <div>
          <small>TRANSAKSI PERSEDIAAN</small>
          <h2>Penyesuaian stok</h2>
          <p>Draft tersimpan di Supabase. Proses transaksi akan memperbarui saldo stok.</p>
        </div>
        <button className="erp-icon" onClick={onClose} aria-label="Tutup transaksi persediaan">
          <X size={18} />
        </button>
      </div>
      <div className="master-toolbar">
        <button className="erp-primary" onClick={resetForm}><Plus size={15} /> Transaksi baru</button>
        <button className="erp-secondary" onClick={() => void loadRecords()} disabled={busy}>Refresh</button>
      </div>
      {error && <p className="master-error">{error}</p>}
      <div className="master-content">
        <div className="master-table-wrap">
          <table>
            <thead><tr><th>Nomor</th><th>Tanggal</th><th>Gudang</th><th>Alasan</th><th>Status</th><th>Aksi</th></tr></thead>
            <tbody>
              {records.map((record) => (
                <tr key={record.id}>
                  <td><b>{record.doc_number}</b></td>
                  <td>{formatDate(record.doc_date)}</td>
                  <td>{record.warehouses?.name ?? "-"}</td>
                  <td>{record.reason}</td>
                  <td><em className={`erp-status ${record.status === "draft" ? "waiting" : "paid"}`}>{record.status}</em></td>
                  <td>
                    {record.status === "draft" && <button type="button" className="master-action" onClick={() => void selectRecord(record)}>Edit</button>}
                    {record.status === "draft" && <button type="button" className="master-action" onClick={() => void applyRecord(record)}>Proses</button>}
                    {record.status === "draft" && <button type="button" className="master-action danger" onClick={() => void deleteRecord(record)}>Hapus</button>}
                  </td>
                </tr>
              ))}
              {!records.length && <tr><td colSpan={6} className="master-empty">Belum ada transaksi persediaan.</td></tr>}
            </tbody>
          </table>
        </div>
        <form className="master-form" onSubmit={saveDraft}>
          <h3>{editing ? `Edit ${editing.doc_number}` : "Draft penyesuaian"}</h3>
          <label>Tanggal<input type="date" required value={form.doc_date} disabled={editing?.status !== "draft" && Boolean(editing)} onChange={(event) => setForm({ ...form, doc_date: event.target.value })} /></label>
          <label>Gudang<select required value={form.warehouse_id} onChange={(event) => setForm({ ...form, warehouse_id: event.target.value })}>{warehouses.map((warehouse) => <option key={warehouse.id} value={warehouse.id}>{warehouse.code} · {warehouse.name}</option>)}</select></label>
          <label>Alasan<input required value={form.reason} onChange={(event) => setForm({ ...form, reason: event.target.value })} placeholder="Contoh: Barang rusak" /></label>
          <label>Catatan<textarea value={form.notes} onChange={(event) => setForm({ ...form, notes: event.target.value })} /></label>
          <div className="inventory-item-entry">
            <label>Produk<select value={form.product_id} onChange={(event) => setForm({ ...form, product_id: event.target.value })}>{products.map((product) => <option key={product.id} value={product.id}>{product.sku} · {product.name}</option>)}</select></label>
            <label>Perubahan qty<input type="number" step="0.0001" value={form.qty_change} onChange={(event) => setForm({ ...form, qty_change: event.target.value })} placeholder="+ masuk / - keluar" /></label>
            <button type="button" className="erp-secondary" onClick={addItem}>Tambah item</button>
          </div>
          <div className="inventory-items">
            {items.map((item) => <div className="inventory-item" key={item.product_id}><span><b>{item.products?.name ?? products.find((product) => product.id === item.product_id)?.name}</b><small>{item.products?.sku ?? ""}</small></span><strong className={item.qty_change > 0 ? "positive" : "negative"}>{item.qty_change > 0 ? "+" : ""}{item.qty_change}</strong><button type="button" className="master-action danger" onClick={() => setItems((current) => current.filter((entry) => entry.product_id !== item.product_id))}>Hapus</button></div>)}
          </div>
          <div className="master-form-actions"><button type="button" className="erp-secondary" onClick={resetForm}>Bersihkan</button><button className="erp-primary" disabled={busy || editing?.status !== "draft"}>{editing ? "Simpan perubahan" : "Simpan draft"}</button></div>
        </form>
      </div>
    </section>
  );
}

type MasterEntity = "customers" | "suppliers" | "products";
type DashboardInvoice = {
  doc_number: string;
  doc_date: string;
  grand_total: number;
  paid_amount: number;
  payment_status: string;
  status: string;
  customers: { name: string } | null;
};
type DashboardReceivable = { outstanding: number | null };
type DashboardStock = {
  product_name: string | null;
  sku: string | null;
  qty_on_hand: number | null;
  min_stock: number | null;
  stock_status: string | null;
  stock_value: number | null;
  unit_code: string | null;
};
type DashboardData = {
  salesTotal: number;
  orderCount: number;
  receivableTotal: number;
  inventoryValue: number;
  activeProducts: number;
  sales: number[];
  monthlySales: number[];
  recentInvoices: DashboardInvoice[];
  lowStock: DashboardStock[];
};
const emptyDashboardData: DashboardData = {
  salesTotal: 0,
  orderCount: 0,
  receivableTotal: 0,
  inventoryValue: 0,
  activeProducts: 0,
  sales: Array(12).fill(0),
  monthlySales: Array(12).fill(0),
  recentInvoices: [],
  lowStock: [],
};

function formatCurrency(value: number) {
  return `Rp ${value.toLocaleString("id-ID", { maximumFractionDigits: 0 })}`;
}

function formatDate(value: string) {
  return new Date(value).toLocaleDateString("id-ID", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

type MasterRecord = {
  id: string;
  code?: string;
  sku?: string;
  name: string;
  email?: string | null;
  phone?: string | null;
  description?: string | null;
  purchase_price?: number;
  selling_price?: number;
  is_active?: boolean;
};

function MasterDataPanel({
  entity,
  onClose,
  onChanged,
}: {
  entity: MasterEntity;
  onClose: () => void;
  onChanged: () => Promise<void>;
}) {
  const [records, setRecords] = useState<MasterRecord[]>([]);
  const [editing, setEditing] = useState<MasterRecord | null>(null);
  const [form, setForm] = useState({
    code: "",
    name: "",
    email: "",
    phone: "",
    sku: "",
    description: "",
    purchase_price: "0",
    selling_price: "0",
  });
  const [search, setSearch] = useState("");
  const [units, setUnits] = useState<{ id: string; code: string; name: string }[]>([]);
  const [unitId, setUnitId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const title =
    entity === "customers" ? "Pelanggan" : entity === "suppliers" ? "Pemasok" : "Produk & Jasa";
  const isProduct = entity === "products";

  const loadRecords = useCallback(async () => {
    setBusy(true);
    setError("");
    const query = supabase.from(entity).select("*").order("name");
    const { data, error: queryError } = await query;
    if (queryError) setError(queryError.message);
    else setRecords((data ?? []) as MasterRecord[]);
    setBusy(false);
  }, [entity]);

  useEffect(() => {
    void loadRecords();
    if (entity === "products") {
      void supabase
        .from("units")
        .select("id, code, name")
        .eq("is_active", true)
        .order("name")
        .then(({ data }) => {
          const nextUnits = data ?? [];
          setUnits(nextUnits);
          setUnitId((current) => current || nextUnits[0]?.id || "");
        });
    }
  }, [entity, loadRecords]);

  function startCreate() {
    setEditing(null);
    setForm({
      code: "",
      name: "",
      email: "",
      phone: "",
      sku: "",
      description: "",
      purchase_price: "0",
      selling_price: "0",
    });
  }

  function startEdit(record: MasterRecord) {
    setEditing(record);
    setForm({
      code: record.code ?? "",
      name: record.name,
      email: record.email ?? "",
      phone: record.phone ?? "",
      sku: record.sku ?? "",
      description: record.description ?? "",
      purchase_price: String(record.purchase_price ?? 0),
      selling_price: String(record.selling_price ?? 0),
    });
  }

  async function saveRecord(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (
      !form.name.trim() ||
      (!isProduct && !form.code.trim()) ||
      (isProduct && (!form.sku.trim() || !unitId))
    ) {
      setError(
        isProduct ? "SKU, unit, dan nama produk wajib diisi." : "Kode dan nama wajib diisi.",
      );
      return;
    }
    setBusy(true);
    setError("");
    const payload = isProduct
      ? {
          sku: form.sku.trim(),
          name: form.name.trim(),
          unit_id: unitId,
          description: form.description.trim() || null,
          purchase_price: Number(form.purchase_price) || 0,
          selling_price: Number(form.selling_price) || 0,
        }
      : {
          code: form.code.trim(),
          name: form.name.trim(),
          email: form.email.trim() || null,
          phone: form.phone.trim() || null,
        };
    const result = editing
      ? await supabase
          .from(entity)
          .update(payload as never)
          .eq("id", editing.id)
      : await supabase.from(entity).insert(payload as never);
    if (result.error) setError(result.error.message);
    else {
      startCreate();
      await loadRecords();
      await onChanged();
    }
    setBusy(false);
  }

  async function deleteRecord(record: MasterRecord) {
    if (!window.confirm(`Hapus ${record.name}? Data ini tidak dapat dipulihkan.`)) return;
    setBusy(true);
    const { error: deleteError } = await supabase.from(entity).delete().eq("id", record.id);
    if (deleteError) setError(deleteError.message);
    else {
      await loadRecords();
      await onChanged();
    }
    setBusy(false);
  }

  const filtered = records.filter((record) =>
    `${record.name} ${record.code ?? record.sku ?? ""}`
      .toLowerCase()
      .includes(search.toLowerCase()),
  );

  return (
    <section className="master-panel">
      <div className="master-header">
        <div>
          <small>MASTER DATA</small>
          <h2>{title}</h2>
          <p>Data tersimpan langsung di Supabase dan mengikuti RLS.</p>
        </div>
        <button className="erp-icon" onClick={onClose} aria-label="Tutup master data">
          <X size={18} />
        </button>
      </div>
      <div className="master-toolbar">
        <input
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder={`Cari ${title.toLowerCase()}...`}
          aria-label={`Cari ${title}`}
        />
        <button className="erp-primary" onClick={startCreate}>
          <Plus size={15} /> Tambah
        </button>
        <button className="erp-secondary" onClick={() => void loadRecords()} disabled={busy}>
          Refresh
        </button>
      </div>
      {error && <p className="master-error">{error}</p>}
      <div className="master-content">
        <div className="master-table-wrap">
          <table>
            <thead>
              <tr>
                <th>{isProduct ? "SKU" : "Kode"}</th>
                <th>Nama</th>
                <th>{isProduct ? "Harga jual" : "Email"}</th>
                <th>Status</th>
                <th>Aksi</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((record) => (
                <tr key={record.id}>
                  <td>{record.code ?? record.sku}</td>
                  <td>
                    <b>{record.name}</b>
                  </td>
                  <td>
                    {isProduct
                      ? `Rp ${(record.selling_price ?? 0).toLocaleString("id-ID")}`
                      : record.email || "-"}
                  </td>
                  <td>
                    <em className={`erp-status ${record.is_active === false ? "late" : "paid"}`}>
                      {record.is_active === false ? "Nonaktif" : "Aktif"}
                    </em>
                  </td>
                  <td>
                    <button
                      type="button"
                      className="master-action"
                      onClick={() => startEdit(record)}
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      className="master-action danger"
                      onClick={() => void deleteRecord(record)}
                    >
                      Hapus
                    </button>
                  </td>
                </tr>
              ))}
              {!filtered.length && (
                <tr>
                  <td colSpan={5} className="master-empty">
                    Belum ada data.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        <form className="master-form" onSubmit={saveRecord}>
          <h3>{editing ? "Edit data" : "Data baru"}</h3>
          {isProduct ? (
            <>
              <label>
                SKU
                <input
                  required
                  value={form.sku}
                  onChange={(event) => setForm({ ...form, sku: event.target.value })}
                />
              </label>
              <label>
                Unit
                <select required value={unitId} onChange={(event) => setUnitId(event.target.value)}>
                  <option value="">Pilih unit</option>
                  {units.map((unit) => (
                    <option key={unit.id} value={unit.id}>
                      {unit.code} · {unit.name}
                    </option>
                  ))}
                </select>
              </label>
            </>
          ) : (
            <label>
              Kode
              <input
                required
                value={form.code}
                onChange={(event) => setForm({ ...form, code: event.target.value })}
              />
            </label>
          )}
          <label>
            Nama
            <input
              required
              value={form.name}
              onChange={(event) => setForm({ ...form, name: event.target.value })}
            />
          </label>
          {isProduct ? (
            <>
              <label>
                Harga beli
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={form.purchase_price}
                  onChange={(event) => setForm({ ...form, purchase_price: event.target.value })}
                />
              </label>
              <label>
                Harga jual
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  value={form.selling_price}
                  onChange={(event) => setForm({ ...form, selling_price: event.target.value })}
                />
              </label>
              <label>
                Deskripsi
                <textarea
                  value={form.description}
                  onChange={(event) => setForm({ ...form, description: event.target.value })}
                />
              </label>
            </>
          ) : (
            <>
              <label>
                Email
                <input
                  type="email"
                  value={form.email}
                  onChange={(event) => setForm({ ...form, email: event.target.value })}
                />
              </label>
              <label>
                Telepon
                <input
                  value={form.phone}
                  onChange={(event) => setForm({ ...form, phone: event.target.value })}
                />
              </label>
            </>
          )}
          <div className="master-form-actions">
            <button type="button" className="erp-secondary" onClick={startCreate}>
              Bersihkan
            </button>
            <button className="erp-primary" disabled={busy}>
              {editing ? "Simpan perubahan" : "Simpan"}
            </button>
          </div>
        </form>
      </div>
    </section>
  );
}

function Metric({
  icon: Icon,
  label,
  value,
  change,
  detail,
  color,
  down = false,
}: {
  icon: typeof CircleDollarSign;
  label: string;
  value: string;
  change: string;
  detail: string;
  color: string;
  down?: boolean;
}) {
  return (
    <div className="erp-metric">
      <div className={`erp-metric-icon ${color}`}>
        <Icon size={18} />
      </div>
      <span>{label}</span>
      <b>{value}</b>
      <strong className={down ? "warn" : ""}>
        {down ? <ArrowDownRight size={13} /> : <ArrowUpRight size={13} />} {change}{" "}
        <small>{detail}</small>
      </strong>
    </div>
  );
}
function PanelTitle({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle: string;
  children: React.ReactNode;
}) {
  return (
    <div className="erp-panel-title">
      <div>
        <h2>{title}</h2>
        <p>{subtitle}</p>
      </div>
      {children}
    </div>
  );
}
function CashBar({
  label,
  amount,
  width,
  color,
}: {
  label: string;
  amount: string;
  width: string;
  color: string;
}) {
  return (
    <div className="erp-cash-bar">
      <div>
        <span>{label}</span>
        <b>{amount}</b>
      </div>
      <i>
        <em className={color} style={{ width }} />
      </i>
    </div>
  );
}
