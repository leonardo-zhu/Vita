import type { Metadata } from 'next'

import { Providers } from '@/components/admin/providers'

import './globals.css'

export const metadata: Metadata = {
  title: 'Vita Admin',
  description: 'Vita 远程配置的编辑与发布',
  robots: { index: false, follow: false },
}

export default function RootLayout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="zh-CN" suppressHydrationWarning className="h-full antialiased">
      <body className="flex min-h-full flex-col">
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
