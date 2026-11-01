import 'server-only'

import { NextResponse } from 'next/server'

import { AuthConfigError } from './auth'
import { PasskeyError } from './passkey'

/** Passkey 路由的统一出错处理：业务错误给前端错误码，其他照常抛出 */
export async function passkeyRoute(run: () => Promise<unknown>) {
  try {
    return NextResponse.json({ ok: true, data: await run() })
  } catch (error) {
    if (error instanceof PasskeyError) {
      return NextResponse.json({ ok: false, code: error.code, detail: error.detail }, { status: 400 })
    }
    if (error instanceof AuthConfigError) {
      return NextResponse.json({ ok: false, code: 'authNotConfigured' }, { status: 400 })
    }
    throw error
  }
}
