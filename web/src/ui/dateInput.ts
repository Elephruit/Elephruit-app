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
