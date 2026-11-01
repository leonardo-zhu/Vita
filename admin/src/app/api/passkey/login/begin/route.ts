import type { NextRequest } from 'next/server'

import { clientIp, isLockedOut } from '@/server/auth'
import { PasskeyError, beginLogin } from '@/server/passkey'
import { passkeyRoute } from '@/server/passkey-route'

export async function POST(req: NextRequest) {
  return passkeyRoute(async () => {
    if (isLockedOut(await clientIp())) throw new PasskeyError('lockedOut')
    return beginLogin(req)
  })
}
