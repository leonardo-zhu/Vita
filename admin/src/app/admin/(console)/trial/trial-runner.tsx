'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { formatTime } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { TrialRun } from '@/server/trial'

import { runTrialAction, type TrialMode } from '../../actions'

interface Props {
  configured: boolean
  liveLabel: string
  draftDirty: boolean
  defaultContext: string
  history: TrialRun[]
}

export function TrialRunner({ configured, liveLabel, draftDirty, defaultContext, history }: Props) {
  const [mode, setMode] = useState<TrialMode>(draftDirty ? 'both' : 'live')
  const [message, setMessage] = useState('')
  const [context, setContext] = useState(defaultContext)
  const [runs, setRuns] = useState<TrialRun[] | null>(null)
  const [pending, startTransition] = useTransition()

  function run() {
    startTransition(async () => {
      const result = await runTrialAction({ mode, message, context })
      if (!result.ok) {
        toast.error(result.message)
        return
      }
      setRuns(result.runs)
    })
  }

  const modes: { value: TrialMode; label: string }[] = [
    { value: 'live', label: liveLabel },
    { value: 'draft', label: '当前草稿（已保存的）' },
    { value: 'both', label: '两边对比' },
  ]

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold">Prompt 试跑</h1>
        <p className="text-sm text-muted-foreground">
          用和 App 一样的系统 prompt 与工具定义让模型跑一轮，看它怎么回答、会调用哪个工具。只跑第一步：工具不会执行，用户数据都在手机上。
        </p>
      </div>

      {!configured && (
        <Alert>
          <AlertTitle>还不能试跑</AlertTitle>
          <AlertDescription>
            需要在服务器的 .env 里配置 CONDUIT_BASE_URL 和 CONDUIT_API_KEY（Conduit 后台给 Vita 应用另建一个密钥），然后重启 Admin。
          </AlertDescription>
        </Alert>
      )}

      <Card>
        <CardContent className="flex flex-col gap-4">
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-2 text-sm font-medium">用哪份配置</legend>
            <div className="flex flex-wrap gap-2">
              {modes.map((option) => (
                <label
                  key={option.value}
                  className={cn(
                    'cursor-pointer rounded-lg border px-3 py-1.5 text-sm transition-colors has-focus-visible:ring-3 has-focus-visible:ring-ring/50',
                    mode === option.value ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted'
                  )}
                >
                  <input
                    type="radio"
                    name="mode"
                    value={option.value}
                    checked={mode === option.value}
                    onChange={() => setMode(option.value)}
                    className="sr-only"
                  />
                  {option.label}
                </label>
              ))}
            </div>
          </fieldset>
          <Label className="flex flex-col items-stretch gap-1.5">
            <span>用户消息</span>
            <Textarea
              rows={3}
              value={message}
              placeholder="如：中午吃了 200g 鸡胸肉和一碗米饭"
              onChange={(e) => setMessage(e.target.value)}
            />
          </Label>
          <details>
            <summary className="cursor-pointer text-sm text-muted-foreground">
              客户端状态（App 会在系统 prompt 后附上这一段，这里可以改成想测的情况）
            </summary>
            <Textarea
              aria-label="客户端状态"
              rows={8}
              className="mt-2 font-mono text-xs"
              value={context}
              onChange={(e) => setContext(e.target.value)}
            />
          </details>
          <div className="flex justify-end">
            <Button disabled={!configured || pending || !message.trim()} onClick={run}>
              {pending ? '模型思考中…' : '试跑'}
            </Button>
          </div>
        </CardContent>
      </Card>

      {runs && (
        <div className={cn('grid gap-4', runs.length > 1 && 'lg:grid-cols-2')}>
          {[...runs].sort((a, b) => (a.source === 'live' ? -1 : b.source === 'live' ? 1 : 0)).map((run) => (
            <RunCard key={run.id} run={run} liveLabel={liveLabel} />
          ))}
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle>最近的试跑</CardTitle>
          <CardDescription>保留最近 40 条。请求 ID 可以在 Conduit 的使用日志里查到同一次调用。</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2">
          {history.length === 0 && <p className="text-sm text-muted-foreground">还没有试跑过。</p>}
          {history.map((run) => (
            <details key={run.id} className="rounded-lg border px-3 py-2">
              <summary className="flex cursor-pointer list-none flex-wrap items-center gap-2 text-sm">
                <span className="text-muted-foreground">{formatTime(run.createdAt)}</span>
                <SourceBadge run={run} liveLabel={liveLabel} />
                <span className="min-w-0 flex-1 truncate">{run.message}</span>
                {run.error ? (
                  <Badge variant="destructive">失败</Badge>
                ) : (
                  run.output?.toolCalls.map((call, i) => (
                    <Badge key={i} variant="outline" className="font-mono">
                      {call.name}
                    </Badge>
                  ))
                )}
              </summary>
              <div className="pt-3">
                <RunBody run={run} />
              </div>
            </details>
          ))}
        </CardContent>
      </Card>
    </div>
  )
}

function SourceBadge({ run, liveLabel }: { run: TrialRun; liveLabel: string }) {
  if (run.source === 'draft') return <Badge>草稿</Badge>
  return <Badge variant="secondary">{run.configVersion ? `线上 ${run.configVersion}` : liveLabel.split('（')[0]}</Badge>
}

function RunCard({ run, liveLabel }: { run: TrialRun; liveLabel: string }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <SourceBadge run={run} liveLabel={liveLabel} />
          <span className="font-mono text-sm font-normal text-muted-foreground">{run.model}</span>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <RunBody run={run} />
      </CardContent>
    </Card>
  )
}

function RunBody({ run }: { run: TrialRun }) {
  return (
    <div className="flex flex-col gap-3 text-sm">
      {run.error && <p className="text-destructive">{run.error}</p>}
      {run.output?.reasoning && (
        <details>
          <summary className="cursor-pointer text-muted-foreground">推理摘要</summary>
          <p className="mt-1 whitespace-pre-wrap text-muted-foreground">{run.output.reasoning}</p>
        </details>
      )}
      {run.output?.text && <p className="whitespace-pre-wrap">{run.output.text}</p>}
      {run.output?.toolCalls.map((call, i) => (
        <div key={i} className="flex flex-col gap-1">
          <span className="text-xs text-muted-foreground">
            调用工具 <span className="font-mono text-foreground">{call.name}</span>
          </span>
          <pre className="max-h-80 overflow-auto rounded-lg bg-muted p-3 text-xs">{prettyJSON(call.arguments)}</pre>
        </div>
      ))}
      {run.output && !run.output.text && run.output.toolCalls.length === 0 && (
        <p className="text-muted-foreground">模型没有回复文字，也没有调用工具。</p>
      )}
      <p className="font-mono text-xs text-muted-foreground">
        {(run.latencyMs / 1000).toFixed(1)} 秒
        {run.inputTokens !== null && ` · 输入 ${run.inputTokens} / 输出 ${run.outputTokens} tokens`} · 请求 {run.requestId}
      </p>
    </div>
  )
}

function prettyJSON(text: string): string {
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    return text
  }
}
