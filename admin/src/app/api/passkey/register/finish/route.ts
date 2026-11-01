import { NextResponse, type NextRequest } from 'next/server'

import { recordAudit } from '@/server/audit'
import { adminUsername, clientIp, currentSession } from '@/server/auth'
import { finishRegistration } from '@/server/passkey'
import { passkeyRoute } from '@/server/passkey-route'

export async function POST(req: NextRequest) {
  const session = await currentSession()
  if (!session) return NextResponse.json({ ok: false, code: 'notLoggedIn' }, { status: 401 })
  const body = (await req.json().catch(() => ({}))) as {
    flowToken?: unknown
    credential?: unknown
    name?: unknown
  }
  const name = typeof body.name === 'string' && body.name.trim() ? body.name.trim().slice(0, 64) : 'Passkey'
  return passkeyRoute(async () => {
    await finishRegistration(req, session.sid, body.flowToken, body.credential, name)
    recordAudit({
      actor: adminUsername(),
      action: 'passkey_add',
      targetType: 'passkey',
      targetId: name,
      ip: await clientIp(),
    })
    return null
  })
}
