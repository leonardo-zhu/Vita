import { configDiff } from '@/lib/config-diff'
import type { DraftContent } from '@/server/config/model'

import { TextDiff } from './text-diff'

/** 两份配置的差异：取值改动列成表，prompt 与工具描述逐段标出增删 */
export function ConfigDiffView({
  before,
  after,
  empty = '内容没有变化。',
}: {
  before: DraftContent
  after: DraftContent
  empty?: string
}) {
  const entries = configDiff(before, after)
  if (entries.length === 0) return <p className="text-sm text-muted-foreground">{empty}</p>
  const values = entries.filter((entry) => entry.kind === 'value')
  const texts = entries.filter((entry) => entry.kind === 'text')
  return (
    <div className="flex flex-col gap-4 text-sm">
      {values.length > 0 && (
        <div className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1.5">
          {values.map((entry) => (
            <div key={entry.key} className="contents">
              <span className="text-muted-foreground">{entry.label}</span>
              <span className="font-mono text-xs leading-5">
                <del className="text-red-700 dark:text-red-300">{entry.from}</del>
                <span className="px-1.5 text-muted-foreground">→</span>
                <ins className="text-emerald-700 no-underline dark:text-emerald-300">{entry.to}</ins>
              </span>
            </div>
          ))}
        </div>
      )}
      {texts.map((entry) => (
        <div key={entry.key} className="flex flex-col gap-1.5">
          <span className="font-medium">{entry.label}</span>
          <TextDiff from={entry.from} to={entry.to} />
        </div>
      ))}
    </div>
  )
}
