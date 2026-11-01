import Link from 'next/link'

import { ConfigDiffView } from '@/components/admin/config-diff-view'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { draftFromBuiltin, draftFromPublished } from '@/server/config/model'
import { currentRelease, getDraft, getRelease, listReleases } from '@/server/config/service'

import { CompareForm, type CompareOption } from '../compare-form'

export const metadata = { title: '版本对比 · Vita Admin' }

/** `from` / `to` 取 release id，或 `builtin`（App 内置默认值）、`draft`（当前草稿） */
function resolve(key: string | undefined) {
  if (key === 'builtin') return { label: 'App 内置默认值', content: draftFromBuiltin() }
  if (key === 'draft') return { label: '当前草稿', content: getDraft().content }
  const release = key ? getRelease(Number(key)) : null
  return release ? { label: release.config_version, content: draftFromPublished(release.content) } : null
}

export default async function ComparePage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>
}) {
  const params = await searchParams
  const releases = listReleases()
  const live = currentRelease()
  const from = resolve(params.from ?? (releases[1] ? String(releases[1].id) : 'builtin'))
  const to = resolve(params.to ?? (live ? String(live.id) : 'draft'))
  const options: CompareOption[] = [
    { value: 'draft', label: '当前草稿' },
    ...releases.map((release) => ({
      value: String(release.id),
      label: `${release.config_version}${release.id === live?.id ? '（线上）' : ''}`,
    })),
    { value: 'builtin', label: 'App 内置默认值' },
  ]

  return (
    <div className="flex flex-col gap-4">
      <Link href="/admin/releases" className="text-sm text-muted-foreground hover:text-foreground">
        ← 发布历史
      </Link>
      <h1 className="text-xl font-semibold">版本对比</h1>
      <CompareForm options={options} from={params.from ?? ''} to={params.to ?? ''} />
      {from && to ? (
        <Card>
          <CardHeader>
            <CardTitle className="font-mono">
              {from.label} → {to.label}
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ConfigDiffView before={from.content} after={to.content} empty="两边内容相同。" />
          </CardContent>
        </Card>
      ) : (
        <p className="text-sm text-muted-foreground">找不到要对比的版本。</p>
      )}
    </div>
  )
}
