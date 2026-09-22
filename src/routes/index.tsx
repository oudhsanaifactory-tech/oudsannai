import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
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
      .from("profiles")
      .select("display_name, roles(name)")
      .eq("id", session.user.id)
      .maybeSingle()
      .then(({ data }) => {
        const role = data?.roles as { name?: string } | null;
        if (role?.name) setRoleName(role.name);
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

  const navigation = [
    ["Overview", LayoutDashboard],
    ["Penjualan", ShoppingCart],
    ["Pembelian", Truck],
    ["Persediaan", Boxes],
    ["Keuangan", CircleDollarSign],
    ["Laporan", BarChart3],
  ] as const;

  const sales = [46, 58, 51, 67, 61, 78, 72, 88, 81, 94, 87, 100];
  const months = [
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
  ];

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
              }}
            >
              <Icon size={17} />
              <span>{label}</span>
              {label === "Persediaan" && <em>3</em>}
            </button>
          ))}
          <small className="nav-gap">Master Data</small>
          <button>
            <Users size={17} />
            <span>Pelanggan & Pemasok</span>
          </button>
          <button>
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
              <button className="erp-primary">
                <Plus size={16} /> Transaksi baru
              </button>
            </div>
          </section>
          <section className="erp-metrics">
            <Metric
              icon={CircleDollarSign}
              label="Total penjualan"
              value="Rp 284,6 jt"
              change="12,8%"
              detail="vs. periode sebelumnya"
              color="green"
            />
            <Metric
              icon={ShoppingCart}
              label="Pesanan masuk"
              value="186"
              change="8,4%"
              detail="vs. periode sebelumnya"
              color="blue"
            />
            <Metric
              icon={FileText}
              label="Piutang usaha"
              value="Rp 92,4 jt"
              change="4,2%"
              detail="lebih rendah dari bulan lalu"
              color="amber"
              down
            />
            <Metric
              icon={Boxes}
              label="Nilai persediaan"
              value="Rp 418,2 jt"
              change="2,1%"
              detail="dari 248 produk aktif"
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
                    {sales.map((value, index) => (
                      <div className="erp-bar-wrap" key={months[index]}>
                        <div
                          className="erp-bar"
                          style={{ height: `${value}%` }}
                          title={`${months[index]}: Rp ${value} jt`}
                        />
                        <span>{months[index]}</span>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
              <div className="erp-chart-footer">
                <span>
                  <b>Rp 284,6 jt</b> total penjualan
                </span>
                <strong>
                  <ArrowUpRight size={14} /> 12,8% dari bulan lalu
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
                    {[
                      [
                        "INV-2024-0918",
                        "PT Sumber Jaya",
                        "18 Sep 2024",
                        "Rp 24.850.000",
                        "Lunas",
                        "paid",
                      ],
                      [
                        "INV-2024-0917",
                        "CV Berkah Abadi",
                        "17 Sep 2024",
                        "Rp 18.420.000",
                        "Menunggu",
                        "waiting",
                      ],
                      [
                        "INV-2024-0916",
                        "Toko Makmur",
                        "16 Sep 2024",
                        "Rp 9.875.000",
                        "Lunas",
                        "paid",
                      ],
                      [
                        "INV-2024-0915",
                        "PT Arunika Niaga",
                        "15 Sep 2024",
                        "Rp 32.100.000",
                        "Jatuh tempo",
                        "late",
                      ],
                    ].map(([number, customer, date, amount, status, tone]) => (
                      <tr key={number}>
                        <td>
                          <b>{number}</b>
                        </td>
                        <td>{customer}</td>
                        <td>{date}</td>
                        <td>
                          <b>{amount}</b>
                        </td>
                        <td>
                          <em className={`erp-status ${tone}`}>{status}</em>
                        </td>
                      </tr>
                    ))}
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
                {[
                  ["Kopi Arabika Premium 250g", "PRD-00124", "12 pcs", "low"],
                  ["Teh Hijau Organik 100g", "PRD-00087", "28 pcs", "medium"],
                  ["Gula Aren Kristal 500g", "PRD-00102", "6 pcs", "critical"],
                ].map(([name, sku, stock, level]) => (
                  <div className="erp-stock" key={sku}>
                    <div className={`erp-stock-icon ${level}`}>
                      <Boxes size={16} />
                    </div>
                    <span>
                      <b>{name}</b>
                      <small>{sku}</small>
                    </span>
                    <strong className={level}>
                      {stock}
                      <small>
                        {level === "critical"
                          ? "Kritis"
                          : level === "low"
                            ? "Menipis"
                            : "Perhatian"}
                      </small>
                    </strong>
                  </div>
                ))}
              </div>
            </div>
          </section>
        </div>
      </main>
    </div>
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
