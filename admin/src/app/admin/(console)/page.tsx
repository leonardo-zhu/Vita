import { draftFromBuiltin, draftFromPublished, knownTools } from '@/server/config/model'
import { getDraft, preparePublish } from '@/server/config/service'

import { ConfigEditor } from './config-editor'

export const metadata = { title: '配置 · Vita Admin' }

export default async function ConfigPage() {
  const draft = getDraft()
  const { config, issues } = preparePublish(draft.content)
  const builtinDraft = draftFromBuiltin()
  const live = draft.current ? draftFromPublished(draft.current.content) : null
  return (
    <ConfigEditor
      // 保存或发布后服务端数据变了，重新挂载编辑器，用新数据初始化
      key={`${draft.updatedAt ?? 0}-${draft.current?.id ?? 0}`}
      initial={draft.content}
      builtin={builtinDraft}
      tools={knownTools()}
      saved={draft.saved}
      current={
        draft.current && {
          configVersion: draft.current.config_version,
          publishedAt: draft.current.published_at,
          publishedBy: draft.current.published_by,
        }
      }
      baseline={live ?? builtinDraft}
      hasPendingChanges={draft.dirty}
      preview={config}
      issues={issues}
    />
  )
}
