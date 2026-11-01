import 'server-only'

import { adminUsername, clientIp, requireSession } from './auth'
import type { Actor } from './config/service'

/** 已登录的管理员与来源 IP，写审计用。没登录时跳到登录页 */
export async function requireActor(): Promise<Actor> {
  await requireSession()
  return { name: adminUsername(), ip: await clientIp() }
}
