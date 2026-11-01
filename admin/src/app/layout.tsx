import type { Metadata } from 'next'

import { Providers } from '@/components/admin/providers'
import { getLang } from '@/i18n/server'

import './globals.css'

export const metadata: Metadata = {
  title: 'Vita Admin',
  robots: { index: false, follow: false },
}

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const lang = await getLang()
  return (
    <html lang={lang === 'zh' ? 'zh-CN' : 'en'} suppressHydrationWarning className="h-full antialiased">
      <body className="flex min-h-full flex-col">
        <Providers lang={lang}>{children}</Providers>
      </body>
    </html>
  )
}
