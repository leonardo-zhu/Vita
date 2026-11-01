'use client'

import { useRouter } from 'next/navigation'

import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'

interface Props {
  days: number
  config: string
  app: string
  code: string
  options: { configVersions: string[]; appVersions: string[] }
}

const select =
  'h-8 rounded-lg border border-input bg-background px-2 text-sm outline-none focus-visible:ring-3 focus-visible:ring-ring/50'

/** 筛选条件放在 URL 里，换一项就跳转 */
export function DiagnosticsFilters({ days, config, app, code, options }: Props) {
  const router = useRouter()

  function go(change: Partial<Record<'days' | 'config' | 'app' | 'code', string>>) {
    const next = { days: String(days), config, app, code, ...change }
    const query = new URLSearchParams(Object.entries(next).filter(([, value]) => value))
    router.push(`/admin/diagnostics?${query}`)
  }

  return (
    <div className="flex flex-wrap items-end gap-3">
      <Label className="flex flex-col items-start gap-1.5">
        <span>时间</span>
        <select className={select} value={days} onChange={(e) => go({ days: e.target.value })}>
          <option value="1">最近 24 小时</option>
          <option value="7">最近 7 天</option>
          <option value="30">最近 30 天</option>
        </select>
      </Label>
      <Label className="flex flex-col items-start gap-1.5">
        <span>配置版本</span>
        <select className={select} value={config} onChange={(e) => go({ config: e.target.value })}>
          <option value="">全部</option>
          {options.configVersions.map((version) => (
            <option key={version} value={version}>
              {version}
            </option>
          ))}
        </select>
      </Label>
      <Label className="flex flex-col items-start gap-1.5">
        <span>App 版本</span>
        <select className={select} value={app} onChange={(e) => go({ app: e.target.value })}>
          <option value="">全部</option>
          {options.appVersions.map((version) => (
            <option key={version} value={version}>
              {version}
            </option>
          ))}
        </select>
      </Label>
      {code && (
        <Button variant="outline" onClick={() => go({ code: '' })}>
          错误码 {code} ✕
        </Button>
      )}
    </div>
  )
}
