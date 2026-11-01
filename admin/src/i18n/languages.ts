/**
 * 界面语言：简体中文、英文；默认跟随浏览器，和 Conduit 一样可以手动切换。
 * 手动选的语言存在 cookie 里（页面在服务端渲染，localStorage 读不到）；选“跟随系统”删掉 cookie。
 */
export const LANGUAGES = ['zh', 'en'] as const
export type Lang = (typeof LANGUAGES)[number]

export const LANG_COOKIE = 'vita_admin_lang'

export const LANGUAGE_LABELS: Record<Lang, string> = { zh: '简体中文', en: 'English' }

export function isLang(value: unknown): value is Lang {
  return typeof value === 'string' && (LANGUAGES as readonly string[]).includes(value)
}

/** Accept-Language 里第一个认识的语言；中文各地区都归到简体中文，其余落到英文 */
export function langFromAcceptLanguage(header: string | null | undefined): Lang {
  for (const part of (header ?? '').split(',')) {
    const tag = part.split(';')[0].trim().toLowerCase()
    if (tag.startsWith('zh')) return 'zh'
    if (tag === 'en' || tag.startsWith('en-')) return 'en'
  }
  return 'en'
}
