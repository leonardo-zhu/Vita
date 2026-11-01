import type { Messages } from '@/i18n/messages'

import { ApiError } from './post'

/** 接口错误码 → 当前语言的说明；带技术细节时附在后面 */
export function apiErrorText(t: Messages, error: unknown): string {
  if (!(error instanceof ApiError)) return (error as Error).message
  if (error.code === 'http') return t.apiErrors.http(error.detail)
  const text = t.apiErrors[error.code as Exclude<keyof Messages['apiErrors'], 'http'>]
  if (!text) return error.code
  return error.detail ? `${text}: ${error.detail}` : text
}
