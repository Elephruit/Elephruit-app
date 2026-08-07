/// datetime-local speaks 'YYYY-MM-DDTHH:mm' in local time; these keep the
/// conversion in one place so nobody round-trips through UTC by accident.

function pad(n: number): string {
  return String(n).padStart(2, '0')
}

export function toLocalInputValue(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

export function toLocalDateValue(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

export function toLocalMonthValue(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}`
}

export function fromLocalInputValue(value: string): Date {
  return new Date(value)
}

/// `<input type="date">` speaks 'YYYY-MM-DD', and `new Date(that)` parses it as
/// UTC midnight — which lands on the previous day for anybody west of
/// Greenwich. Built from parts so a date the user picked is the date they get.
export function fromLocalDateValue(value: string): Date | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!match) return null
  const [, year, month, day] = match
  return new Date(Number(year), Number(month) - 1, Number(day))
}

/// `<input type="month">` records the precision the user actually supplied.
/// The persisted model still uses a Date, so the first day at noon is the
/// stable representative for that month without risking a UTC day shift.
export function fromLocalMonthValue(value: string): Date | null {
  const match = /^(\d{4})-(\d{2})$/.exec(value)
  if (!match) return null
  const [, year, month] = match
  return new Date(Number(year), Number(month) - 1, 1, 12)
}
