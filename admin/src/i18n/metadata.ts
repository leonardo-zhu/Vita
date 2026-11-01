import 'server-only'

import type { Metadata } from 'next'

import type { Messages } from './messages'
import { getT } from './server'

/** 页面标题：`<页面> · Vita Admin`，按当前语言 */
export function titled(key: keyof Messages['meta']) {
  return async function generateMetadata(): Promise<Metadata> {
    return { title: `${(await getT()).meta[key]} · Vita Admin` }
  }
}
