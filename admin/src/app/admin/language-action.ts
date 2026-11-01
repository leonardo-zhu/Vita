'use server'

import { cookies } from 'next/headers'

import { isLang, LANG_COOKIE, type Lang } from '@/i18n/languages'

/** 记住手动选的界面语言；null 表示跟随系统。登录页也能切，所以不要求登录 */
export async function setLanguageAction(lang: Lang | null) {
  const store = await cookies()
  if (lang === null) {
    store.delete(LANG_COOKIE)
    return
  }
  if (!isLang(lang)) return
  store.set(LANG_COOKIE, lang, { path: '/', sameSite: 'lax', maxAge: 365 * 86400 })
}
