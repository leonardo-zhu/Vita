'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

import { cn } from '@/lib/utils'

const ITEMS = [
  { href: '/admin', label: '配置' },
  { href: '/admin/trial', label: '试跑' },
  { href: '/admin/releases', label: '发布历史' },
  { href: '/admin/diagnostics', label: '诊断' },
  { href: '/admin/audit', label: '审计' },
  { href: '/admin/settings', label: '设置' },
] as const

export function ConsoleNav() {
  const pathname = usePathname()
  return (
    <nav className="flex min-w-0 items-center gap-1 overflow-x-auto text-sm [scrollbar-width:none]">
      {ITEMS.map((item) => {
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
