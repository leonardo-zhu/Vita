import { redirect } from 'next/navigation'

import { currentSession } from '@/server/auth'
import { listPasskeys } from '@/server/db'

import { LoginForm } from './login-form'

export const metadata = { title: '登录 · Vita Admin' }

export default async function LoginPage() {
  if (await currentSession()) redirect('/admin')
  return (
    <main className="flex flex-1 items-center justify-center p-4">
      {/* 还没注册过 Passkey 时只给密码登录，免得误以为已经有 Passkey 可用 */}
      <LoginForm passkeyAvailable={listPasskeys().length > 0} />
    </main>
  )
}
