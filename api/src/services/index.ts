import type { ServiceContext } from './context.ts'
import { DayService } from './day.ts'
import { FoodService } from './foods.ts'
import { GoalService } from './goals.ts'
import { HealthService } from './health.ts'
import { PendingService } from './pending.ts'
import { RecordService } from './records.ts'

export interface Services {
  context: ServiceContext
  records: RecordService
  foods: FoodService
  pending: PendingService
  days: DayService
  goals: GoalService
  health: HealthService
}

export function createServices(context: ServiceContext): Services {
  const records = new RecordService(context)
  const foods = new FoodService(context)
  const goals = new GoalService(context)
  const health = new HealthService(context)
  return {
    context,
    records,
    foods,
    pending: new PendingService(context, records, foods),
    days: new DayService(context, goals, health),
    goals,
    health,
  }
}
