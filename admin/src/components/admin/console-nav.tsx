'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

import { useT } from '@/i18n/client'
import { cn } from '@/lib/utils'

export function ConsoleNav() {
  const t = useT()
  const pathname = usePathname()
  const items = [
    { href: '/admin', label: t.nav.config },
    { href: '/admin/playground', label: t.nav.playground },
    { href: '/admin/releases', label: t.nav.releases },
    { href: '/admin/diagnostics', label: t.nav.diagnostics },
    { href: '/admin/audit', label: t.nav.audit },
    { href: '/admin/conversations', label: t.nav.conversations },
    { href: '/admin/records', label: t.nav.records },
    { href: '/admin/foods', label: t.nav.foods },
    { href: '/admin/devices', label: t.nav.devices },
    { href: '/admin/google-health', label: t.nav.googleHealth },
    { href: '/admin/goal-changes', label: t.nav.goalChanges },
    { href: '/admin/settings', label: t.nav.settings },
  ]
  return (
    <nav className="flex min-w-0 items-center gap-1 overflow-x-auto text-sm [scrollbar-width:none]">
      {items.map((item) => {
        const active = item.href === '/admin' ? pathname === '/admin' : pathname.startsWith(item.href)
        return (
          <Link
            key={item.href}
            href={item.href}
            className={cn(
              'rounded-md px-2.5 py-1.5 whitespace-nowrap text-muted-foreground transition-colors hover:text-foreground',
              active && 'bg-muted font-medium text-foreground'
            )}
          >
            {item.label}
          </Link>
        )
      })}
    </nav>
  )
}
