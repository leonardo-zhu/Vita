import { titled } from '@/i18n/metadata'
import { currentRelease, getDraft } from '@/server/config/service'
import { conduitConfigured, listTrials, sampleContext } from '@/server/trial'

import { Playground } from './playground'

export const generateMetadata = titled('playground')

export default async function PlaygroundPage() {
  return (
    <Playground
      configured={conduitConfigured()}
      liveVersion={currentRelease()?.config_version ?? null}
      draftDirty={getDraft().dirty}
      defaultContext={sampleContext()}
      history={listTrials()}
    />
  )
}
