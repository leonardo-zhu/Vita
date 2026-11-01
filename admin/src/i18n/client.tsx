'use client'

import { createContext, useContext } from 'react'

import type { Lang } from './languages'
import { messages, type Messages } from './messages'

const LangContext = createContext<Lang>('zh')

/** 服务端定好语言后传下来，客户端组件用 useT() 取同一份文案 */
export function I18nProvider({ lang, children }: { lang: Lang; children: React.ReactNode }) {
  return <LangContext.Provider value={lang}>{children}</LangContext.Provider>
}

export function useT(): Messages {
  return messages[useContext(LangContext)]
}

export function useLang(): Lang {
  return useContext(LangContext)
}
