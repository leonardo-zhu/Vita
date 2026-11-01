import { titled } from '@/i18n/metadata'
import Link from 'next/link'
import { notFound } from 'next/navigation'

import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { formatTime } from '@/lib/format'
import { ConfigDiffView } from '@/components/admin/config-diff-view'
import { getT } from '@/i18n/server'
import { draftFromPublished } from '@/server/config/model'
import { currentRelease, getRelease, listReleases } from '@/server/config/service'

import { RollbackButton } from './rollback-button'

export const generateMetadata = titled('release')

export default async function ReleasePage({ params }: { params: Promise<{ id: string }> }) {
  const t = await getT()
  const release = getRelease(Number((await params).id))
  if (!release) notFound()
  const isCurrent = currentRelease()?.id === release.id
  // 与上一个版本比，列出这次改了什么
  const previous = listReleases().find((other) => other.id < release.id)
  const rollbackOf = release.rollback_of ? getRelease(release.rollback_of) : null

  return (
    <div className="flex flex-col gap-4">
      <Link href="/admin/releases" className="text-sm text-muted-foreground hover:text-foreground">
        {t.releases.back}
      </Link>
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="font-mono text-xl font-semibold">{release.config_version}</h1>
        {isCurrent && <Badge variant="outline">{t.releases.live}</Badge>}
        {!isCurrent && <RollbackButton releaseId={release.id} version={release.config_version} />}
      </div>
      <p className="text-sm text-muted-foreground">
        {t.releases.byline(formatTime(release.published_at), release.published_by)}
        {rollbackOf && ` · ${t.releases.rollbackOf(rollbackOf.config_version)}`}
        {release.note && ` · ${release.note}`}
      </p>
      <Card>
        <CardHeader>
          <CardTitle>{t.releases.changesTitle(previous?.config_version ?? null)}</CardTitle>
        </CardHeader>
        <CardContent className="text-sm">
          {previous ? (
            <ConfigDiffView before={draftFromPublished(previous.content)} after={draftFromPublished(release.content)} />
          ) : (
            <p className="text-muted-foreground">{t.releases.firstRelease}</p>
          )}
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle>{t.releases.fileTitle}</CardTitle>
        </CardHeader>
        <CardContent>
          <pre className="max-h-[32rem] overflow-auto rounded-lg bg-muted p-3 text-xs">
            {JSON.stringify(release.content, null, 2)}
          </pre>
          <p className="mt-2 font-mono text-xs break-all text-muted-foreground">sha256 {release.content_hash}</p>
        </CardContent>
      </Card>
    </div>
  )
}
