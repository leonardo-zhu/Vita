import Link from 'next/link'
import { notFound } from 'next/navigation'

import { Badge } from '@/components/ui/badge'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { formatTime } from '@/lib/format'
import { draftFromPublished, describeChanges } from '@/server/config/model'
import { currentRelease, getRelease, listReleases } from '@/server/config/service'

import { RollbackButton } from './rollback-button'

export const metadata = { title: '发布详情 · Vita Admin' }

export default async function ReleasePage({ params }: { params: Promise<{ id: string }> }) {
  const release = getRelease(Number((await params).id))
  if (!release) notFound()
  const isCurrent = currentRelease()?.id === release.id
  // 与上一个版本比，列出这次改了什么
  const previous = listReleases().find((other) => other.id < release.id)
  const changes = previous
    ? describeChanges(draftFromPublished(previous.content), draftFromPublished(release.content))
    : null
  const rollbackOf = release.rollback_of ? getRelease(release.rollback_of) : null

  return (
    <div className="flex flex-col gap-4">
      <Link href="/admin/releases" className="text-sm text-muted-foreground hover:text-foreground">
        ← 发布历史
      </Link>
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="font-mono text-xl font-semibold">{release.config_version}</h1>
        {isCurrent && <Badge variant="outline">线上</Badge>}
        {!isCurrent && <RollbackButton releaseId={release.id} version={release.config_version} />}
      </div>
      <p className="text-sm text-muted-foreground">
        {formatTime(release.published_at)} 由 {release.published_by} 发布
        {rollbackOf && `，回滚到 ${rollbackOf.config_version}`}
        {release.note && `。${release.note}`}
      </p>
      <Card>
        <CardHeader>
          <CardTitle>相对上一版的改动</CardTitle>
        </CardHeader>
        <CardContent className="text-sm">
          {changes === null ? (
            <p className="text-muted-foreground">第一次发布。</p>
          ) : changes.length === 0 ? (
            <p className="text-muted-foreground">内容没有变化。</p>
          ) : (
            <ul className="list-inside list-disc">
              {changes.map((change) => (
                <li key={change}>{change}</li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle>文件内容</CardTitle>
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
