import type { NextRequest } from 'next/server'

import { clientIp, isLockedOut } from '@/server/auth'
import { PasskeyError, beginLogin } from '@/server/passkey'
import { passkeyRoute } from '@/server/passkey-route'

export async function POST(req: NextRequest) {
  return passkeyRoute(async () => {
    if (isLockedOut(await clientIp())) throw new PasskeyError('失败次数太多，请 15 分钟后再试')
    return beginLogin(req)
  })
}
