import type { ServiceContext } from './context.ts'
import { DayService } from './day.ts'
import { FoodService } from './foods.ts'
import { PendingService } from './pending.ts'
import { RecordService } from './records.ts'

export interface Services {
  context: ServiceContext
  records: RecordService
  foods: FoodService
  pending: PendingService
  days: DayService
}

export function createServices(context: ServiceContext): Services {
  const records = new RecordService(context)
  const foods = new FoodService(context)
  return { context, records, foods, pending: new PendingService(context, records, foods), days: new DayService(context) }
}
