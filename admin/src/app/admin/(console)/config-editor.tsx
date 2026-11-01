'use client'

import { RotateCcw } from 'lucide-react'
import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { ConfigDiffView } from '@/components/admin/config-diff-view'
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { describeChanges } from '@/lib/config-diff'
import { formatTime } from '@/lib/format'
import type { DraftContent, PublishedConfig } from '@/server/config/model'
import type { ValidationIssue } from '@/server/config/validate'

import { discardDraftAction, publishAction, saveDraftAction, type ActionResult } from '../actions'

interface Props {
  initial: DraftContent
  builtin: DraftContent
  tools: string[]
  saved: boolean
  current: { configVersion: string; publishedAt: number; publishedBy: string } | null
  /** 线上版本（还没发布过时是内置默认值），草稿与它对比 */
  baseline: DraftContent
  hasPendingChanges: boolean
  preview: PublishedConfig
  issues: ValidationIssue[]
}

export function ConfigEditor(props: Props) {
  const { initial, builtin, tools, current, preview } = props
  const [content, setContent] = useState(initial)
  const [issues, setIssues] = useState(props.issues)
  const [pending, startTransition] = useTransition()
  const [publishOpen, setPublishOpen] = useState(false)
  const [note, setNote] = useState('')

  const unsaved = JSON.stringify(content) !== JSON.stringify(initial)
  const canPublish = !unsaved && props.hasPendingChanges && issues.length === 0
  const issueFor = (path: string) => issues.find((issue) => issue.path === path)?.message

  function update(change: (draft: DraftContent) => DraftContent) {
    setContent((draft) => change(structuredClone(draft)))
  }

  function run(action: () => Promise<ActionResult>, after?: () => void) {
    startTransition(async () => {
      const result = await action()
      if (result.ok) {
        toast.success(result.message)
        if (result.warning) toast.warning(result.warning)
        after?.()
      } else {
        toast.error(result.message)
        if (result.issues) setIssues(result.issues)
      }
    })
  }

  return (
    <div className="flex flex-col gap-6 pb-24">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <h1 className="text-xl font-semibold">远程配置</h1>
          <p className="text-sm text-muted-foreground">
            {current
              ? `线上版本 ${current.configVersion}，${formatTime(current.publishedAt)} 由 ${current.publishedBy} 发布`
              : '还没有发布过，App 正在使用内置默认值'}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {unsaved ? (
            <Badge variant="secondary">有未保存的修改</Badge>
          ) : props.hasPendingChanges ? (
            <Badge>草稿未发布</Badge>
          ) : (
            <Badge variant="outline">与线上一致</Badge>
          )}
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>模型与请求</CardTitle>
          <CardDescription>模型别名必须是 Conduit 上已有的别名，发布前会检查。</CardDescription>
        </CardHeader>
        <CardContent className="grid gap-4 sm:grid-cols-2">
          <Field label="模型别名" error={issueFor('/llm/modelId')}>
            <Input
              value={content.llm.modelId}
              onChange={(e) => update((d) => ((d.llm.modelId = e.target.value), d))}
            />
          </Field>
          <Field label="超时秒数（5–180）" error={issueFor('/llm/timeoutSeconds')}>
            <NumberInput
              value={content.llm.timeoutSeconds}
              onChange={(v) => update((d) => ((d.llm.timeoutSeconds = v), d))}
            />
          </Field>
          <Field label="重试次数（0–3）" error={issueFor('/llm/maxRetries')}>
            <NumberInput
              value={content.llm.maxRetries}
              onChange={(v) => update((d) => ((d.llm.maxRetries = v), d))}
            />
          </Field>
          <SwitchField
            label="流式输出"
            checked={content.llm.streaming}
            onChange={(v) => update((d) => ((d.llm.streaming = v), d))}
          />
          <Field label="上下文消息条数（1–100）" error={issueFor('/context/maxRecentMessages')}>
            <NumberInput
              value={content.context.maxRecentMessages}
              onChange={(v) => update((d) => ((d.context.maxRecentMessages = v), d))}
            />
          </Field>
          <SwitchField
            label="上下文附带个人食品库"
            checked={content.context.includePersonalFoodSummary}
            onChange={(v) => update((d) => ((d.context.includePersonalFoodSummary = v), d))}
          />
          <Field
            label="最低客户端版本（可空）"
            hint="低于这个版本的 App 忽略本配置，格式 0.1.0"
            error={issueFor('/minClientVersion')}
          >
            <Input
              value={content.minClientVersion}
              placeholder="不限制"
              onChange={(e) => update((d) => ((d.minClientVersion = e.target.value), d))}
            />
          </Field>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>系统 prompt</CardTitle>
          <CardDescription>和 App 内置的一样时不写进配置文件，App 用自带的那份。</CardDescription>
        </CardHeader>
        <CardContent>
          <PromptField
            label="系统 prompt"
            value={content.systemPrompt}
            builtin={builtin.systemPrompt}
            rows={14}
            error={issueFor('/prompts/system/text')}
            onChange={(v) => update((d) => ((d.systemPrompt = v), d))}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>工具描述</CardTitle>
          <CardDescription>
            只能改模型看到的说明文字；工具清单和参数由 App 代码决定，这里改不了。
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2">
          {tools.map((name) => {
            const modified = content.toolDescriptions[name] !== builtin.toolDescriptions[name]
            const error = issueFor(`/prompts/tools/${name}/description`)
            return (
              <details key={name} className="group rounded-lg border px-3 py-2" open={Boolean(error)}>
                <summary className="flex cursor-pointer list-none items-center gap-2 text-sm">
                  <span className="font-mono">{name}</span>
                  {modified && <Badge>已修改</Badge>}
                  {error && <Badge variant="destructive">有问题</Badge>}
                  <span className="ml-auto text-xs text-muted-foreground group-open:hidden">展开</span>
                </summary>
                <div className="pt-3">
                  <PromptField
                    label={`${name} 的描述`}
                    value={content.toolDescriptions[name] ?? ''}
                    builtin={builtin.toolDescriptions[name]}
                    rows={4}
                    error={error}
                    onChange={(v) => update((d) => ((d.toolDescriptions[name] = v), d))}
                  />
                </div>
              </details>
            )
          })}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>功能开关</CardTitle>
          <CardDescription>只能启用或关闭 App 已经带上的能力。</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {Object.keys(builtin.features).length === 0 ? (
            <p className="text-sm text-muted-foreground">当前 App 没有可远程控制的开关。</p>
          ) : (
            Object.keys(builtin.features).map((name) => (
              <SwitchField
                key={name}
                label={name}
                checked={content.features[name] ?? builtin.features[name]}
                onChange={(v) => update((d) => ((d.features[name] = v), d))}
              />
            ))
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>发布预览</CardTitle>
          <CardDescription>
            按已保存的草稿生成，下一个版本号 {preview.configVersion}。App 回到前台时拉取，下一轮对话生效。
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {issues.length > 0 && (
            <ul className="list-inside list-disc text-sm text-destructive">
              {issues.map((issue) => (
                <li key={issue.path + issue.message}>{issue.message}</li>
              ))}
            </ul>
          )}
          <div className="flex flex-col gap-2">
            <span className="text-sm font-medium">相对线上{current ? ` ${current.configVersion}` : '（内置默认值）'}的改动</span>
            <ConfigDiffView before={props.baseline} after={initial} empty="已保存的草稿和线上一致。" />
          </div>
          <details>
            <summary className="cursor-pointer text-sm text-muted-foreground">查看将要发布的 stable.json</summary>
            <pre className="mt-2 max-h-96 overflow-auto rounded-lg bg-muted p-3 text-xs">
              {JSON.stringify(preview, null, 2)}
            </pre>
          </details>
        </CardContent>
      </Card>

      <div className="fixed inset-x-0 bottom-0 z-30 border-t bg-background/95 backdrop-blur">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-end gap-2 px-4 py-3">
          {unsaved && (
            <Button variant="ghost" disabled={pending} onClick={() => setContent(initial)}>
              撤销编辑
            </Button>
          )}
          {!unsaved && props.saved && (
            <Button variant="ghost" disabled={pending} onClick={() => run(discardDraftAction)}>
              放弃草稿
            </Button>
          )}
          <Button variant="outline" disabled={!unsaved || pending} onClick={() => run(() => saveDraftAction(content))}>
            保存草稿
          </Button>
          <Button disabled={!canPublish || pending} onClick={() => setPublishOpen(true)}>
            发布…
          </Button>
        </div>
      </div>

      <AlertDialog open={publishOpen} onOpenChange={setPublishOpen}>
        <AlertDialogContent className="sm:max-w-md">
          <AlertDialogHeader>
            <AlertDialogTitle>发布 {preview.configVersion}？</AlertDialogTitle>
            <AlertDialogDescription>
              发布后立即对外生效。相对线上{current ? ` ${current.configVersion}` : '（内置默认值）'}的改动：
            </AlertDialogDescription>
          </AlertDialogHeader>
          <ul className="list-inside list-disc text-sm">
            {describeChanges(props.baseline, initial).map((change) => (
              <li key={change}>{change}</li>
            ))}
          </ul>
          <Field label="备注（可空）">
            <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="这次改了什么、为什么" />
          </Field>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>取消</AlertDialogCancel>
            <Button disabled={pending} onClick={() => run(() => publishAction(note), () => setPublishOpen(false))}>
              {pending ? '发布中…' : '发布'}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

function Field({
  label,
  hint,
  error,
  children,
}: {
  label: string
  hint?: string
  error?: string
  children: React.ReactNode
}) {
  return (
    <div className="flex flex-col gap-1.5">
      {/* 标签包住输入框，读屏和点标签都能对上 */}
      <Label className="flex flex-col items-stretch gap-1.5">
        <span>{label}</span>
        {children}
      </Label>
      {error ? (
        <p className="text-xs text-destructive">{error}</p>
      ) : (
        hint && <p className="text-xs text-muted-foreground">{hint}</p>
      )}
    </div>
  )
}

function SwitchField({
  label,
  checked,
  onChange,
}: {
  label: string
  checked: boolean
  onChange: (value: boolean) => void
}) {
  return (
    <Label className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2 font-normal">
      {label}
      <Switch checked={checked} onCheckedChange={onChange} />
    </Label>
  )
}

function NumberInput({ value, onChange }: { value: number; onChange: (value: number) => void }) {
  return (
    <Input
      type="number"
      inputMode="numeric"
      value={Number.isFinite(value) ? value : ''}
      onChange={(e) => onChange(e.target.value === '' ? Number.NaN : Math.trunc(Number(e.target.value)))}
    />
  )
}

function PromptField({
  label,
  value,
  builtin,
  rows,
  error,
  onChange,
}: {
  label: string
  value: string
  builtin: string
  rows: number
  error?: string
  onChange: (value: string) => void
}) {
  const modified = value !== builtin
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        {modified ? <Badge>已修改</Badge> : <Badge variant="outline">与内置相同</Badge>}
        <span>{value.length} 字</span>
        {modified && (
          <Button variant="ghost" size="xs" className="ml-auto" onClick={() => onChange(builtin)}>
            <RotateCcw />
            恢复内置
          </Button>
        )}
      </div>
      <Textarea
        aria-label={label}
        value={value}
        rows={rows}
        className="font-mono text-sm leading-relaxed"
        onChange={(e) => onChange(e.target.value)}
      />
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  )
}
