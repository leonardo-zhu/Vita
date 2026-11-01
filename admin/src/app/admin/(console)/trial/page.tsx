import { currentRelease, getDraft } from '@/server/config/service'
import { conduitConfigured, listTrials, sampleContext } from '@/server/trial'

import { TrialRunner } from './trial-runner'

export const metadata = { title: '试跑 · Vita Admin' }

export default async function TrialPage() {
  const live = currentRelease()
  const draft = getDraft()
  return (
    <TrialRunner
      configured={conduitConfigured()}
      liveLabel={live ? `线上 ${live.config_version}` : '线上（还没发布，即 App 内置默认值）'}
      draftDirty={draft.dirty}
      defaultContext={sampleContext()}
      history={listTrials()}
    />
  )
}
