import { redirect } from 'next/navigation'

import { currentSession } from '@/server/auth'

import { LoginForm } from './login-form'

export const metadata = { title: '登录 · Vita Admin' }

export default async function LoginPage() {
  if (await currentSession()) redirect('/admin')
  return (
    <main className="flex flex-1 items-center justify-center p-4">
      <LoginForm />
    </main>
  )
}
