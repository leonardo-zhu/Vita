'use client'

import { Check, Languages } from 'lucide-react'
import { useRouter } from 'next/navigation'
import { useTransition } from 'react'

import { setLanguageAction } from '@/app/admin/language-action'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useT } from '@/i18n/client'
import { LANGUAGE_LABELS, LANGUAGES, type Lang } from '@/i18n/languages'
import { cn } from '@/lib/utils'

/** 和 Conduit 一样：默认跟随系统，手动选了才记住；选“跟随系统”清掉记录 */
export function LanguageSwitcher({ chosen }: { chosen: Lang | null }) {
  const t = useT()
  const router = useRouter()
  const [, startTransition] = useTransition()

  function choose(lang: Lang | null) {
    startTransition(async () => {
      await setLanguageAction(lang)
      router.refresh()
    })
  }

  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger render={<Button variant="ghost" size="icon-sm" aria-label={t.lang.change} />}>
        <Languages />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem onClick={() => choose(null)}>
          {t.lang.followSystem}
          <Check className={cn('ms-auto', chosen && 'invisible')} />
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        {LANGUAGES.map((lang) => (
          <DropdownMenuItem key={lang} onClick={() => choose(lang)}>
            {LANGUAGE_LABELS[lang]}
            <Check className={cn('ms-auto', chosen !== lang && 'invisible')} />
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
