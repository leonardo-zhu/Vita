import 'server-only'

import { cookies, headers } from 'next/headers'

import { isLang, LANG_COOKIE, langFromAcceptLanguage, type Lang } from './languages'
import { messages, type Messages } from './messages'

/** 手动选过的语言；没选过返回 null（跟随系统） */
export async function chosenLang(): Promise<Lang | null> {
  const value = (await cookies()).get(LANG_COOKIE)?.value
  return isLang(value) ? value : null
}

export async function getLang(): Promise<Lang> {
  return (await chosenLang()) ?? langFromAcceptLanguage((await headers()).get('accept-language'))
}

export async function getT(): Promise<Messages> {
  return messages[await getLang()]
}
