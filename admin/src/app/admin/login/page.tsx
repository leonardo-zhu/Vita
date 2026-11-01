import { redirect } from 'next/navigation'

import { LanguageSwitcher } from '@/components/admin/language-switcher'
import { titled } from '@/i18n/metadata'
import { chosenLang } from '@/i18n/server'
import { currentSession } from '@/server/auth'
import { listPasskeys } from '@/server/db'

import { LoginForm } from './login-form'

export const generateMetadata = titled('login')

export default async function LoginPage() {
  if (await currentSession()) redirect('/admin')
  return (
    <main className="relative flex flex-1 items-center justify-center p-4">
      <div className="absolute top-3 right-3">
        <LanguageSwitcher chosen={await chosenLang()} />
      </div>
      {/* 还没注册过 Passkey 时只给密码登录，免得误以为已经有 Passkey 可用 */}
      <LoginForm passkeyAvailable={listPasskeys().length > 0} />
    </main>
  )
}
