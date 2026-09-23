export type FieldType = "text" | "email" | "number" | "currency" | "textarea" | "select" | "switch";

export type MasterField = {
  key: string;
  label: string;
  type: FieldType;
  required?: boolean;
  options?: { value: string; label: string }[];
  ref?: { table: string; labelColumns: string[] };
  optional?: boolean;
  hint?: string;
};

export type MasterColumn = {
  key: string;
  label: string;
  kind?: "text" | "currency" | "number" | "status" | "ref";
};

export type MasterConfig = {
  table: string;
  title: string;
  singular: string;
  orderBy: string;
  searchKeys: string[];
  columns: MasterColumn[];
  fields: MasterField[];
};

const activeField: MasterField = { key: "is_active", label: "Aktif", type: "switch" };

export const MASTER_KEYS = [
  "products",
  "product_categories",
  "units",
  "customers",
  "suppliers",
  "warehouses",
  "accounts",
] as const;

export type MasterKey = (typeof MASTER_KEYS)[number];

export const MASTER_CONFIGS: Record<MasterKey, MasterConfig> = {
  products: {
    table: "products",
    title: "Produk & Jasa",
    singular: "produk",
    orderBy: "sku",
    searchKeys: ["sku", "name"],
    columns: [
      { key: "sku", label: "SKU" },
      { key: "name", label: "Nama" },
      { key: "purchase_price", label: "Harga beli", kind: "currency" },
      { key: "selling_price", label: "Harga jual", kind: "currency" },
      { key: "average_cost", label: "HPP rata-rata", kind: "currency" },
      { key: "is_active", label: "Status", kind: "status" },
    ],
    fields: [
      { key: "sku", label: "SKU", type: "text", required: true },
      { key: "name", label: "Nama produk", type: "text", required: true },
      {
        key: "product_type",
        label: "Jenis",
        type: "select",
        required: true,
        options: [
          { value: "inventory", label: "Barang (persediaan)" },
          { value: "service", label: "Jasa" },
        ],
      },
      {
        key: "unit_id",
        label: "Satuan",
        type: "select",
        required: true,
        ref: { table: "units", labelColumns: ["code", "name"] },
      },
      {
        key: "category_id",
        label: "Kategori",
        type: "select",
        optional: true,
        ref: { table: "product_categories", labelColumns: ["code", "name"] },
      },
      { key: "purchase_price", label: "Harga beli", type: "currency" },
      { key: "selling_price", label: "Harga jual", type: "currency" },
      { key: "min_stock", label: "Stok minimum", type: "number" },
      { key: "description", label: "Deskripsi", type: "textarea", optional: true },
      activeField,
    ],
  },
  product_categories: {
    table: "product_categories",
    title: "Kategori Produk",
    singular: "kategori",
    orderBy: "code",
    searchKeys: ["code", "name"],
    columns: [
      { key: "code", label: "Kode" },
      { key: "name", label: "Nama" },
      { key: "description", label: "Deskripsi" },
      { key: "is_active", label: "Status", kind: "status" },
    ],
    fields: [
      { key: "code", label: "Kode", type: "text", required: true },
      { key: "name", label: "Nama kategori", type: "text", required: true },
      { key: "description", label: "Deskripsi", type: "textarea", optional: true },
      activeField,
    ],
  },
  units: {
    table: "units",
    title: "Satuan",
    singular: "satuan",
    orderBy: "code",
    searchKeys: ["code", "name"],
    columns: [
      { key: "code", label: "Kode" },
      { key: "name", label: "Nama" },
      { key: "is_active", label: "Status", kind: "status" },
    ],
    fields: [
      { key: "code", label: "Kode", type: "text", required: true },
      { key: "name", label: "Nama satuan", type: "text", required: true },
      activeField,
    ],
  },
  customers: {
    table: "customers",
    title: "Pelanggan",
    singular: "pelanggan",
    orderBy: "code",
    searchKeys: ["code", "name", "email"],
    columns: [
      { key: "code", label: "Kode" },
      { key: "name", label: "Nama" },
      { key: "phone", label: "Telepon" },
      { key: "credit_limit", label: "Limit kredit", kind: "currency" },
      { key: "is_active", label: "Status", kind: "status" },
    ],
    fields: [
      { key: "code", label: "Kode", type: "text", required: true },
      { key: "name", label: "Nama pelanggan", type: "text", required: true },
      { key: "phone", label: "Telepon", type: "text", optional: true },
      { key: "email", label: "Email", type: "email", optional: true },
      { key: "npwp", label: "NPWP", type: "text", optional: true },
      { key: "credit_limit", label: "Limit kredit", type: "currency" },
      { key: "address", label: "Alamat", type: "textarea", optional: true },
      activeField,
    ],
  },
  suppliers: {
    table: "suppliers",
    title: "Pemasok",
    singular: "pemasok",
    orderBy: "code",
    searchKeys: ["code", "name", "email"],
    columns: [
      { key: "code", label: "Kode" },
      { key: "name", label: "Nama" },
      { key: "phone", label: "Telepon" },
      { key: "email", label: "Email" },
      { key: "is_active", label: "Status", kind: "status" },
    ],
    fields: [
      { key: "code", label: "Kode", type: "text", required: true },
      { key: "name", label: "Nama pemasok", type: "text", required: true },
      { key: "phone", label: "Telepon", type: "text", optional: true },
      { key: "email", label: "Email", type: "email", optional: true },
      { key: "npwp", label: "NPWP", type: "text", optional: true },
      { key: "address", label: "Alamat", type: "textarea", optional: true },
      activeField,
    ],
  },
  warehouses: {
    table: "warehouses",
    title: "Gudang",
    singular: "gudang",
    orderBy: "code",
    searchKeys: ["code", "name"],
    columns: [
      { key: "code", label: "Kode" },
      { key: "name", label: "Nama" },
      { key: "address", label: "Alamat" },
      { key: "is_active", label: "Status", kind: "status" },
    ],
    fields: [
      { key: "code", label: "Kode", type: "text", required: true },
      { key: "name", label: "Nama gudang", type: "text", required: true },
      { key: "address", label: "Alamat", type: "textarea", optional: true },
      activeField,
    ],
  },
  accounts: {
    table: "accounts",
    title: "Akun Keuangan",
    singular: "akun",
    orderBy: "code",
    searchKeys: ["code", "name"],
    columns: [
      { key: "code", label: "Kode" },
      { key: "name", label: "Nama akun" },
      { key: "account_type", label: "Tipe" },
      { key: "normal_balance", label: "Saldo normal" },
      { key: "is_active", label: "Status", kind: "status" },
    ],
    fields: [
      { key: "code", label: "Kode akun", type: "text", required: true },
      { key: "name", label: "Nama akun", type: "text", required: true },
      {
        key: "account_type",
        label: "Tipe akun",
        type: "select",
        required: true,
        options: [
          { value: "asset", label: "Aset" },
          { value: "liability", label: "Kewajiban" },
          { value: "equity", label: "Ekuitas" },
          { value: "revenue", label: "Pendapatan" },
          { value: "expense", label: "Beban" },
        ],
      },
      {
        key: "normal_balance",
        label: "Saldo normal",
        type: "select",
        required: true,
        options: [
          { value: "debit", label: "Debit" },
          { value: "credit", label: "Kredit" },
        ],
      },
      { key: "is_cash_account", label: "Akun kas/bank", type: "switch" },
      { key: "description", label: "Keterangan", type: "textarea", optional: true },
      activeField,
    ],
  },
};
