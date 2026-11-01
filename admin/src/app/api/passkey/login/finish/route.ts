import type { NextRequest } from 'next/server'

import { recordAudit } from '@/server/audit'
import { adminUsername, clearFailures, clientIp, recordFailure, startSession } from '@/server/auth'
import { finishLogin } from '@/server/passkey'
import { passkeyRoute } from '@/server/passkey-route'

export async function POST(req: NextRequest) {
  const body = (await req.json().catch(() => ({}))) as { flowToken?: unknown; credential?: unknown }
  const ip = await clientIp()
  return passkeyRoute(async () => {
    try {
      const row = await finishLogin(req, body.flowToken, body.credential)
      clearFailures(ip)
      await startSession('passkey')
      recordAudit({ actor: adminUsername(), action: 'login', diff: { method: 'passkey', passkey: row.name }, ip })
      return null
    } catch (error) {
      recordFailure(ip)
      throw error
    }
  })
}
