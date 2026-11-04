import path from 'node:path'

import { dataDir } from '../db.ts'
import { BodyService } from './body.ts'
import { ChatService, LabelService } from './chat.ts'
import type { ServiceContext } from './context.ts'
import { DayService } from './day.ts'
import { FoodService } from './foods.ts'
import { GoalService } from './goals.ts'
import { HealthService } from './health.ts'
import { HealthSyncService } from './healthSync.ts'
import { ImportService } from './importer.ts'
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
  body: BodyService
  chat: ChatService
  labels: LabelService
  healthSync: HealthSyncService
  importer: ImportService
}

/** `filesDir`：标签照片等文件的目录，默认数据目录下的 files/。 */
export function createServices(context: ServiceContext, filesDir = path.join(dataDir(), 'files')): Services {
  const records = new RecordService(context)
  const foods = new FoodService(context)
  const goals = new GoalService(context)
  const health = new HealthService(context)
  const days = new DayService(context, goals, health)
  const body = new BodyService(context, health)
  return {
    context,
    records,
    foods,
    pending: new PendingService(context, records, foods),
    days,
    goals,
    health,
    body,
    healthSync: new HealthSyncService(context, days, body),
    importer: new ImportService(context, filesDir, days),
    chat: new ChatService(context),
    labels: new LabelService(context, filesDir),
  }
}
