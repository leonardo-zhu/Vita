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
import { useT } from '@/i18n/client'
import { describeChanges } from '@/lib/config-diff'
import { issueText } from '@/lib/issue-text'
import { formatTime } from '@/lib/format'
import type { DraftContent, PublishedConfig } from '@/server/config/model'
import type { ValidationIssue } from '@/server/config/validate'

import { discardDraftAction, publishAction, saveDraftAction, type ActionResult } from '../actions'

const REASONING_EFFORTS = ['default', 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
const IMAGE_DETAILS = ['low', 'high', 'xhigh']

const select =
  'h-8 rounded-lg border border-input bg-background px-2 text-sm outline-none focus-visible:ring-3 focus-visible:ring-ring/50'

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
  const t = useT()
  const [content, setContent] = useState(initial)
  const [issues, setIssues] = useState(props.issues)
  const [pending, startTransition] = useTransition()
  const [publishOpen, setPublishOpen] = useState(false)
  const [note, setNote] = useState('')
  // 其他请求参数的 JSON 还没写完整时不能保存
  const [extraBodyInvalid, setExtraBodyInvalid] = useState(false)
  // 撤销编辑时让 JSON 编辑框按草稿重新填文字
  const [editRound, setEditRound] = useState(0)

  const unsaved = JSON.stringify(content) !== JSON.stringify(initial)
  const canPublish = !unsaved && props.hasPendingChanges && issues.length === 0
  const issueFor = (path: string) => {
    const issue = issues.find((item) => item.path === path)
    return issue && issueText(t, issue)
  }

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
          <h1 className="text-xl font-semibold">{t.editor.title}</h1>
          <p className="text-sm text-muted-foreground">
            {current
              ? t.editor.live(current.configVersion, formatTime(current.publishedAt), current.publishedBy)
              : t.editor.neverPublished}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {unsaved ? (
            <Badge variant="secondary">{t.editor.unsaved}</Badge>
          ) : props.hasPendingChanges ? (
            <Badge>{t.editor.draftPending}</Badge>
          ) : (
            <Badge variant="outline">{t.editor.inSync}</Badge>
          )}
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t.editor.modelTitle}</CardTitle>
          <CardDescription>{t.editor.modelDescription}</CardDescription>
        </CardHeader>
        <CardContent className="grid gap-4 sm:grid-cols-2">
          <Field label={t.fields.modelId} error={issueFor('/llm/modelId')}>
            <Input
              value={content.llm.modelId}
              onChange={(e) => update((d) => ((d.llm.modelId = e.target.value), d))}
            />
          </Field>
          <Field label={t.editor.timeoutLabel} error={issueFor('/llm/timeoutSeconds')}>
            <NumberInput
              value={content.llm.timeoutSeconds}
              onChange={(v) => update((d) => ((d.llm.timeoutSeconds = v), d))}
            />
          </Field>
          <Field label={t.editor.retriesLabel} error={issueFor('/llm/maxRetries')}>
            <NumberInput
              value={content.llm.maxRetries}
              onChange={(v) => update((d) => ((d.llm.maxRetries = v), d))}
            />
          </Field>
          <SwitchField
            label={t.fields.streaming}
            checked={content.llm.streaming}
            onChange={(v) => update((d) => ((d.llm.streaming = v), d))}
          />
          <Field label={t.editor.effortLabel} hint={t.editor.effortHint} error={issueFor('/llm/reasoningEffort')}>
            <select
              className={select}
              value={content.llm.reasoningEffort}
              onChange={(e) => update((d) => ((d.llm.reasoningEffort = e.target.value), d))}
            >
              {REASONING_EFFORTS.map((effort) => (
                <option key={effort} value={effort}>
                  {effort === 'default' ? t.editor.effortDefault : effort}
                </option>
              ))}
            </select>
          </Field>
          <Field label={t.editor.messagesLabel} error={issueFor('/context/maxRecentMessages')}>
            <NumberInput
              value={content.context.maxRecentMessages}
              onChange={(v) => update((d) => ((d.context.maxRecentMessages = v), d))}
            />
          </Field>
          <SwitchField
            label={t.fields.includePersonalFoodSummary}
            checked={content.context.includePersonalFoodSummary}
            onChange={(v) => update((d) => ((d.context.includePersonalFoodSummary = v), d))}
          />
          <Field
            label={t.editor.minClientLabel}
            hint={t.editor.minClientHint}
            error={issueFor('/minClientVersion')}
          >
            <Input
              value={content.minClientVersion}
              placeholder={t.editor.minClientPlaceholder}
              onChange={(e) => update((d) => ((d.minClientVersion = e.target.value), d))}
            />
          </Field>
          <div className="sm:col-span-2">
            <ExtraBodyField
              key={editRound}
              value={content.llm.extraBody}
              error={issueFor('/llm/extraBody')}
              onChange={(v) => update((d) => ((d.llm.extraBody = v), d))}
              onValidityChange={setExtraBodyInvalid}
            />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t.editor.labelImageTitle}</CardTitle>
          <CardDescription>{t.editor.labelImageDescription}</CardDescription>
        </CardHeader>
        <CardContent className="grid gap-4 sm:grid-cols-3">
          <Field label={t.editor.maxDimensionLabel} error={issueFor('/labelImage/maxDimension')}>
            <NumberInput
              value={content.labelImage.maxDimension}
              onChange={(v) => update((d) => ((d.labelImage.maxDimension = v), d))}
            />
          </Field>
          <Field label={t.editor.jpegQualityLabel} error={issueFor('/labelImage/jpegQuality')}>
            <Input
              type="number"
              inputMode="decimal"
              step="0.05"
              value={Number.isFinite(content.labelImage.jpegQuality) ? content.labelImage.jpegQuality : ''}
              onChange={(e) =>
                update((d) => ((d.labelImage.jpegQuality = e.target.value === '' ? Number.NaN : Number(e.target.value)), d))
              }
            />
          </Field>
          <Field label={t.editor.detailLabel} error={issueFor('/labelImage/detail')}>
            <select
              className={select}
              value={content.labelImage.detail}
              onChange={(e) => update((d) => ((d.labelImage.detail = e.target.value), d))}
            >
              {IMAGE_DETAILS.map((detail) => (
                <option key={detail} value={detail}>
                  {detail}
                </option>
              ))}
            </select>
          </Field>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t.editor.systemTitle}</CardTitle>
          <CardDescription>{t.editor.systemDescription}</CardDescription>
        </CardHeader>
        <CardContent>
          <PromptField
            label={t.fields.systemPrompt}
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
          <CardTitle>{t.editor.toolsTitle}</CardTitle>
          <CardDescription>{t.editor.toolsDescription}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2">
          {tools.map((name) => {
            const modified = content.toolDescriptions[name] !== builtin.toolDescriptions[name]
            const error = issueFor(`/prompts/tools/${name}/description`)
            return (
              <details key={name} className="group rounded-lg border px-3 py-2" open={Boolean(error)}>
                <summary className="flex cursor-pointer list-none items-center gap-2 text-sm">
                  <span className="font-mono">{name}</span>
                  {modified && <Badge>{t.editor.modified}</Badge>}
                  {error && <Badge variant="destructive">{t.editor.hasIssue}</Badge>}
                  <span className="ml-auto text-xs text-muted-foreground group-open:hidden">{t.common.expand}</span>
                </summary>
                <div className="pt-3">
                  <PromptField
                    label={t.editor.toolDescriptionLabel(name)}
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
          <CardTitle>{t.editor.featuresTitle}</CardTitle>
          <CardDescription>{t.editor.featuresDescription}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {Object.keys(builtin.features).length === 0 ? (
            <p className="text-sm text-muted-foreground">{t.editor.noFeatures}</p>
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
          <CardTitle>{t.editor.previewTitle}</CardTitle>
          <CardDescription>{t.editor.previewDescription(preview.configVersion)}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {issues.length > 0 && (
            <ul className="list-inside list-disc text-sm text-destructive">
              {issues.map((issue) => (
                <li key={issue.path + issue.rule}>{issueText(t, issue)}</li>
              ))}
            </ul>
          )}
          <div className="flex flex-col gap-2">
            <span className="text-sm font-medium">{t.editor.changesAgainst(current?.configVersion ?? null)}</span>
            <ConfigDiffView before={props.baseline} after={initial} empty={t.diff.draftSameAsLive} />
          </div>
          <details>
            <summary className="cursor-pointer text-sm text-muted-foreground">{t.editor.showFile}</summary>
            <pre className="mt-2 max-h-96 overflow-auto rounded-lg bg-muted p-3 text-xs">
              {JSON.stringify(preview, null, 2)}
            </pre>
          </details>
        </CardContent>
      </Card>

      <div className="fixed inset-x-0 bottom-0 z-30 border-t bg-background/95 backdrop-blur">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-end gap-2 px-4 py-3">
          {unsaved && (
            <Button variant="ghost" disabled={pending} onClick={() => (setContent(initial), setExtraBodyInvalid(false), setEditRound((n) => n + 1))}>
              {t.editor.undoEdits}
            </Button>
          )}
          {!unsaved && props.saved && (
            <Button variant="ghost" disabled={pending} onClick={() => run(discardDraftAction)}>
              {t.editor.discardDraft}
            </Button>
          )}
          <Button variant="outline" disabled={!unsaved || pending || extraBodyInvalid} onClick={() => run(() => saveDraftAction(content))}>
            {t.editor.saveDraft}
          </Button>
          <Button disabled={!canPublish || pending} onClick={() => setPublishOpen(true)}>
            {t.editor.publishEllipsis}
          </Button>
        </div>
      </div>

      <AlertDialog open={publishOpen} onOpenChange={setPublishOpen}>
        <AlertDialogContent className="sm:max-w-md">
          <AlertDialogHeader>
            <AlertDialogTitle>{t.editor.publishTitle(preview.configVersion)}</AlertDialogTitle>
            <AlertDialogDescription>{t.editor.publishDescription(current?.configVersion ?? null)}</AlertDialogDescription>
          </AlertDialogHeader>
          <ul className="list-inside list-disc text-sm">
            {describeChanges(t, props.baseline, initial).map((change) => (
              <li key={change}>{change}</li>
            ))}
          </ul>
          <Field label={t.editor.noteLabel}>
            <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder={t.editor.notePlaceholder} />
          </Field>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>{t.common.cancel}</AlertDialogCancel>
            <Button disabled={pending} onClick={() => run(() => publishAction(note), () => setPublishOpen(false))}>
              {pending ? t.editor.publishing : t.editor.publish}
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

/** JSON 对象的编辑框：输入时只改本地文字，能解析成对象时才写回草稿 */
function ExtraBodyField({
  value,
  error,
  onChange,
  onValidityChange,
}: {
  value: Record<string, unknown>
  error?: string
  onChange: (value: Record<string, unknown>) => void
  onValidityChange: (invalid: boolean) => void
}) {
  const t = useT()
  const [text, setText] = useState(() => JSON.stringify(value, null, 2))
  const [invalid, setInvalid] = useState(false)

  function edit(next: string) {
    setText(next)
    let parsed: unknown = null
    try {
      parsed = next.trim() === '' ? {} : JSON.parse(next)
    } catch {}
    const ok = parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
    setInvalid(!ok)
    onValidityChange(!ok)
    if (ok) onChange(parsed as Record<string, unknown>)
  }

  return (
    <Field
      label={t.editor.extraBodyLabel}
      hint={t.editor.extraBodyHint}
      error={invalid ? t.editor.extraBodyInvalid : error}
    >
      <Textarea
        value={text}
        rows={4}
        spellCheck={false}
        className="font-mono text-sm"
        onChange={(e) => edit(e.target.value)}
      />
    </Field>
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
  const t = useT()
  const modified = value !== builtin
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        {modified ? <Badge>{t.editor.modified}</Badge> : <Badge variant="outline">{t.editor.sameAsBuiltin}</Badge>}
        <span>{t.editor.chars(value.length)}</span>
        {modified && (
          <Button variant="ghost" size="xs" className="ml-auto" onClick={() => onChange(builtin)}>
            <RotateCcw />
            {t.editor.restoreBuiltin}
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
