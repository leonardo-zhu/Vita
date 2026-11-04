/**
 * 本地日期与时区（TDD §3.1）。LocalDate 是 `YYYY-MM-DD` 字符串，不带时区；
 * 时刻一律是 Date / ISO 字符串，按 IANA 时区换算本地日期和时分。
 */

const LOCAL_DATE = /^(\d{4})-(\d{2})-(\d{2})$/

/** 合法的日历日期（含闰年）才返回 true。 */
export function isLocalDate(value: string): boolean {
  const match = LOCAL_DATE.exec(value)
  if (!match) return false
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])]
  const date = new Date(Date.UTC(year, month - 1, day))
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
}

export function isTimeZone(identifier: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: identifier })
    return true
  } catch {
    return false
  }
}

const formatters = new Map<string, Intl.DateTimeFormat>()

function formatter(timeZone: string): Intl.DateTimeFormat {
  let cached = formatters.get(timeZone)
  if (!cached) {
    cached = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
    formatters.set(timeZone, cached)
  }
  return cached
}

interface LocalParts {
  year: number
  month: number
  day: number
  hour: number
  minute: number
  second: number
}

export function localParts(instant: Date, timeZone: string): LocalParts {
  const parts = Object.fromEntries(formatter(timeZone).formatToParts(instant).map((part) => [part.type, part.value]))
  return {
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    second: Number(parts.second),
  }
}

function pad(value: number, width = 2): string {
  return String(value).padStart(width, '0')
}

/** `instant` 在 `timeZone` 下的本地日期。 */
export function localDateOf(instant: Date, timeZone: string): string {
  const { year, month, day } = localParts(instant, timeZone)
  return `${pad(year, 4)}-${pad(month)}-${pad(day)}`
}

/** 日历意义上的前后若干天，与时区无关。 */
export function addDays(localDate: string, days: number): string {
  const [year, month, day] = localDate.split('-').map(Number)
  const date = new Date(Date.UTC(year, month - 1, day + days))
  return `${pad(date.getUTCFullYear(), 4)}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`
}

/** 本地日期与时分秒在 `timeZone` 下对应的时刻。夏令时跳过的时刻取跳过之后。 */
export function zonedInstant(localDate: string, hour: number, minute: number, second: number, timeZone: string): Date {
  const [year, month, day] = localDate.split('-').map(Number)
  const wall = Date.UTC(year, month - 1, day, hour, minute, second)
  const offsetAt = (instant: number) => {
    const p = localParts(new Date(instant), timeZone)
    return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - instant
  }
  // 先按墙上时间的偏移猜一次，再用猜到的时刻的偏移校正（偏移在两者之间变化时才会不同）。
  let instant = wall - offsetAt(wall)
  instant = wall - offsetAt(instant)
  return new Date(instant)
}
