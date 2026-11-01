import { adminUsername, requireSession } from '@/server/auth'

import { ConsoleNav } from '@/components/admin/console-nav'
import { Button } from '@/components/ui/button'

import { logoutAction } from '../actions'

export default async function ConsoleLayout({ children }: { children: React.ReactNode }) {
  await requireSession()
  return (
    <div className="flex flex-1 flex-col">
      <header className="sticky top-0 z-30 border-b bg-background/90 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-5xl items-center gap-3 px-4 sm:gap-6">
          <span className="font-semibold whitespace-nowrap">Vita Admin</span>
          <ConsoleNav />
          <form action={logoutAction} className="ml-auto flex shrink-0 items-center gap-3">
            <span className="hidden text-sm text-muted-foreground sm:inline">{adminUsername()}</span>
            <Button type="submit" variant="ghost" size="sm">
              退出
            </Button>
          </form>
        </div>
      </header>
      <main className="mx-auto w-full max-w-5xl flex-1 px-4 py-6">{children}</main>
    </div>
  )
}
