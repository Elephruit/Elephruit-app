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
