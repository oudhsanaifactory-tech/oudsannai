export function formatRupiah(value: number | null | undefined): string {
  const amount = Number(value ?? 0);
  return `Rp ${amount.toLocaleString("id-ID", { maximumFractionDigits: 0 })}`;
}

export function formatRupiahShort(value: number | null | undefined): string {
  const amount = Number(value ?? 0);
  if (Math.abs(amount) >= 1_000_000_000)
    return `Rp ${(amount / 1_000_000_000).toLocaleString("id-ID", { maximumFractionDigits: 1 })} M`;
  if (Math.abs(amount) >= 1_000_000)
    return `Rp ${(amount / 1_000_000).toLocaleString("id-ID", { maximumFractionDigits: 1 })} jt`;
  if (Math.abs(amount) >= 1_000)
    return `Rp ${(amount / 1_000).toLocaleString("id-ID", { maximumFractionDigits: 0 })} rb`;
  return formatRupiah(amount);
}

export function formatNumber(value: number | null | undefined): string {
  return Number(value ?? 0).toLocaleString("id-ID", { maximumFractionDigits: 2 });
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return date.toLocaleDateString("id-ID", { day: "2-digit", month: "short", year: "numeric" });
}

export function formatLongDate(value: Date): string {
  return value.toLocaleDateString("id-ID", {
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  });
}

export function greetingByHour(hour: number): string {
  if (hour < 11) return "Selamat pagi";
  if (hour < 15) return "Selamat siang";
  if (hour < 19) return "Selamat sore";
  return "Selamat malam";
}
