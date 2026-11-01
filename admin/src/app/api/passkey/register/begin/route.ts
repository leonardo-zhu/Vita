import { NextResponse, type NextRequest } from 'next/server'

import { checkPassword, currentSession } from '@/server/auth'
import { PasskeyError, beginRegistration } from '@/server/passkey'
import { passkeyRoute } from '@/server/passkey-route'

// 注册前再确认一次密码，会话被盗用时不能偷偷加 Passkey
export async function POST(req: NextRequest) {
  const session = await currentSession()
  if (!session) return NextResponse.json({ ok: false, message: '未登录' }, { status: 401 })
  const body = (await req.json().catch(() => ({}))) as { password?: unknown }
  return passkeyRoute(async () => {
    if (typeof body.password !== 'string' || !checkPassword(body.password)) {
      throw new PasskeyError('密码不对')
    }
    return beginRegistration(req, session.sid)
  })
}
