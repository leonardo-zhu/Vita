import { ConsoleNav } from '@/components/admin/console-nav'
import { LanguageSwitcher } from '@/components/admin/language-switcher'
import { Button } from '@/components/ui/button'
import { chosenLang, getT } from '@/i18n/server'
import { adminUsername, requireSession } from '@/server/auth'

import { logoutAction } from '../actions'

export default async function ConsoleLayout({ children }: { children: React.ReactNode }) {
  await requireSession()
  const t = await getT()
  return (
    <div className="flex flex-1 flex-col">
      <header className="sticky top-0 z-30 border-b bg-background/90 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-5xl items-center gap-3 px-4 sm:gap-6">
          <span className="font-semibold whitespace-nowrap">Vita Admin</span>
          <ConsoleNav />
          <div className="ml-auto flex shrink-0 items-center gap-1">
            <LanguageSwitcher chosen={await chosenLang()} />
            <form action={logoutAction} className="flex items-center gap-3">
              <span className="hidden text-sm text-muted-foreground sm:inline">{adminUsername()}</span>
              <Button type="submit" variant="ghost" size="sm">
                {t.nav.logout}
              </Button>
            </form>
          </div>
        </div>
      </header>
      <main className="mx-auto w-full max-w-5xl flex-1 px-4 py-6">{children}</main>
    </div>
  )
}
