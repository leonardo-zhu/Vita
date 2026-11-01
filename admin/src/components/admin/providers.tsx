'use client'

import { ThemeProvider } from 'next-themes'

import { Toaster } from '@/components/ui/sonner'
import { I18nProvider } from '@/i18n/client'
import type { Lang } from '@/i18n/languages'

export function Providers({ lang, children }: { lang: Lang; children: React.ReactNode }) {
  return (
    <I18nProvider lang={lang}>
      <ThemeProvider attribute="class" defaultTheme="system" enableSystem disableTransitionOnChange>
        {children}
        <Toaster position="top-center" />
      </ThemeProvider>
    </I18nProvider>
  )
}
