import { titled } from '@/i18n/metadata'
import Link from 'next/link'

import { ConfigDiffView } from '@/components/admin/config-diff-view'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { draftFromBuiltin, draftFromPublished } from '@/server/config/model'
import type { Messages } from '@/i18n/messages'
import { getT } from '@/i18n/server'
import { currentRelease, getDraft, getRelease, listReleases } from '@/server/config/service'

import { CompareForm, type CompareOption } from '../compare-form'

export const generateMetadata = titled('compare')

/** `from` / `to` 取 release id，或 `builtin`（App 内置默认值）、`draft`（当前草稿） */
function resolve(t: Messages, key: string | undefined) {
  if (key === 'builtin') return { label: t.compare.builtin, content: draftFromBuiltin() }
  if (key === 'draft') return { label: t.compare.draft, content: getDraft().content }
  const release = key ? getRelease(Number(key)) : null
  return release ? { label: release.config_version, content: draftFromPublished(release.content) } : null
}

export default async function ComparePage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>
}) {
  const params = await searchParams
  const t = await getT()
  const releases = listReleases()
  const live = currentRelease()
  const from = resolve(t, params.from ?? (releases[1] ? String(releases[1].id) : 'builtin'))
  const to = resolve(t, params.to ?? (live ? String(live.id) : 'draft'))
  const options: CompareOption[] = [
    { value: 'draft', label: t.compare.draft },
    ...releases.map((release) => ({
      value: String(release.id),
      label: `${release.config_version}${release.id === live?.id ? t.compare.liveSuffix : ''}`,
    })),
    { value: 'builtin', label: t.compare.builtin },
  ]

  return (
    <div className="flex flex-col gap-4">
      <Link href="/admin/releases" className="text-sm text-muted-foreground hover:text-foreground">
        {t.releases.back}
      </Link>
      <h1 className="text-xl font-semibold">{t.compare.title}</h1>
      <CompareForm options={options} from={params.from ?? ''} to={params.to ?? ''} />
      {from && to ? (
        <Card>
          <CardHeader>
            <CardTitle className="font-mono">
              {from.label} → {to.label}
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ConfigDiffView before={from.content} after={to.content} empty={t.diff.same} />
          </CardContent>
        </Card>
      ) : (
        <p className="text-sm text-muted-foreground">{t.compare.notFound}</p>
      )}
    </div>
  )
}
