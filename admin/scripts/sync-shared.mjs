// 把 Admin 依赖的仓库内共享文件拷进 src/generated/（不进 git）：
// - shared/config-schema/config.schema.json：发布前校验，与 iOS 共用
// - ios/Vita/Resources/DefaultConfig.json：客户端内置默认值（L1），用来初始化草稿、对比哪些项与内置相同
// - shared/agent-tools/tool-parameters.json：工具参数 schema，Prompt 试跑时和 App 发一样的工具定义
// dev / build / test 前自动运行；Docker 构建时这两个文件也要在构建上下文里，见 Dockerfile。
import { copyFileSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const admin = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const repo = path.resolve(admin, '..')
const out = path.join(admin, 'src/generated')

mkdirSync(out, { recursive: true })
for (const [from, to] of [
  ['shared/config-schema/config.schema.json', 'config.schema.json'],
  ['ios/Vita/Resources/DefaultConfig.json', 'default-config.json'],
  ['shared/agent-tools/tool-parameters.json', 'tool-parameters.json'],
]) {
  copyFileSync(path.join(repo, from), path.join(out, to))
}
