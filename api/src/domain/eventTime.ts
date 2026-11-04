/**
 * 摄入时间（TDD §3.1、§6.4、ADR-011）。精度决定哪些字段存在，构造时校验不变量：
 * 不会把"中午"伪装成 12:00，也不会让时刻落到别的日期。
 */
import type { EventTime, MealPeriod, TimePrecision } from '@vita/contract'

import { isLocalDate, isTimeZone, localDateOf, localParts, zonedInstant } from './time.ts'

export class EventTimeError extends Error {
  readonly code: string
  constructor(code: string) {
    super(code)
    this.code = code
  }
}

export function makeEventTime(input: {
  localDate: string
  precision: TimePrecision
  timestamp?: Date | null
  mealPeriod?: MealPeriod | null
  timeZone: string
}): EventTime {
  const { localDate, precision, timeZone } = input
  const timestamp = input.timestamp ?? null
  const mealPeriod = input.mealPeriod ?? null
  if (!isLocalDate(localDate)) throw new EventTimeError('invalidLocalDate')
  if (!isTimeZone(timeZone)) throw new EventTimeError('unknownTimeZone')
  switch (precision) {
    case 'exact':
    case 'approximate':
    case 'defaultedEntryTime':
      if (!timestamp) throw new EventTimeError('missingTimestamp')
      if (localDateOf(timestamp, timeZone) !== localDate) throw new EventTimeError('timestampOutsideLocalDate')
      if (mealPeriod) throw new EventTimeError('unexpectedMealPeriod')
      break
    case 'mealPeriod':
      if (timestamp) throw new EventTimeError('unexpectedTimestamp')
      if (!mealPeriod) throw new EventTimeError('missingMealPeriod')
      break
    case 'dateOnly':
      if (timestamp) throw new EventTimeError('unexpectedTimestamp')
      if (mealPeriod) throw new EventTimeError('unexpectedMealPeriod')
      break
  }
  return { localDate, precision, timestamp: timestamp ? timestamp.toISOString() : null, mealPeriod, timeZone }
}

const MEAL_TIMES: Record<MealPeriod, [number, number]> = {
  breakfast: [8, 0],
  lunch: [12, 30],
  dinner: [18, 30],
  snack: [15, 30],
  other: [12, 0],
}

/**
 * 需要具体时刻的场合（排序、写入 Apple 健康）用的时刻：有 timestamp 用它，餐段取代表性时间，
 * 仅日期取当日 12:00。只用于计算，不能当作用户陈述的事实展示。
 */
export function representativeTimestamp(eventTime: EventTime): Date {
  if (eventTime.timestamp) return new Date(eventTime.timestamp)
  const [hour, minute] = MEAL_TIMES[eventTime.mealPeriod ?? 'other']
  return zonedInstant(eventTime.localDate, hour, minute, 0, eventTime.timeZone)
}

/** 用户完全没表达时间时的默认值：会话日期 + 当前本地时分秒，保证记录不跨出所在日期，历史日期同样适用。 */
export function defaultedEntryTime(sessionDate: string, now: Date, timeZone: string): EventTime {
  const { hour, minute, second } = localParts(now, timeZone)
  return makeEventTime({
    localDate: sessionDate,
    precision: 'defaultedEntryTime',
    timestamp: zonedInstant(sessionDate, hour, minute, second, timeZone),
    timeZone,
  })
}
