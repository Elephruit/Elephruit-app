/// Every "same day" and "how many days" question in the domain goes through these
/// two helpers, in local time — feed grouping, reminder buckets, and fact staleness
/// must never disagree about where a day starts.

export function startOfDay(date: Date): Date {
  const d = new Date(date)
  d.setHours(0, 0, 0, 0)
  return d
}

export function isSameDay(a: Date, b: Date): boolean {
  return startOfDay(a).getTime() === startOfDay(b).getTime()
}

/// Whole days from `from` to `to`, start-of-day to start-of-day. Negative when
/// `to` precedes `from`. Rounded so a DST-shortened day still counts as one day.
export function wholeDaysBetween(from: Date, to: Date): number {
  const ms = startOfDay(to).getTime() - startOfDay(from).getTime()
  return Math.round(ms / 86_400_000)
}
