import { diffWords } from 'diff'

import { cn } from '@/lib/utils'

// 中文没有空格，按词切分后再比，标出来的增删才是成词的
const segmenter = new Intl.Segmenter('zh', { granularity: 'word' })

/** 一段文字前后的差异：删掉的划线标红，新增的标绿，其余照常显示 */
export function TextDiff({ from, to, className }: { from: string; to: string; className?: string }) {
  const parts = diffWords(from, to, { intlSegmenter: segmenter })
  return (
    <div
      className={cn(
        'max-h-[28rem] overflow-auto rounded-lg bg-muted/50 p-3 font-mono text-xs leading-relaxed whitespace-pre-wrap',
        className
      )}
    >
      {parts.map((part, i) =>
        part.added ? (
          <ins key={i} className="rounded-sm bg-emerald-500/15 text-emerald-700 no-underline dark:text-emerald-300">
            {part.value}
          </ins>
        ) : part.removed ? (
          <del key={i} className="rounded-sm bg-red-500/15 text-red-700 dark:text-red-300">
            {part.value}
          </del>
        ) : (
          <span key={i}>{part.value}</span>
        )
      )}
    </div>
  )
}
