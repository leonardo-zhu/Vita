import 'server-only'

import { NextResponse } from 'next/server'

import { AuthConfigError } from './auth'
import { PasskeyError } from './passkey'

/** Passkey 路由的统一出错处理：业务错误给前端看，其他照常抛出 */
export async function passkeyRoute(run: () => Promise<unknown>) {
  try {
    return NextResponse.json({ ok: true, data: await run() })
  } catch (error) {
    if (error instanceof PasskeyError || error instanceof AuthConfigError) {
      return NextResponse.json({ ok: false, message: error.message }, { status: 400 })
    }
    throw error
  }
}
