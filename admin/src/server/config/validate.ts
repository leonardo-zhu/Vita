/**
 * 发布前校验（vita-admin.md §6 / §8.3）：与客户端共用 shared/config-schema/config.schema.json，
 * 再补上 schema 表达不了的规则。校验不过不能发布。
 */
import Ajv2020, { type ErrorObject } from 'ajv/dist/2020'

import schema from '@/generated/config.schema.json'

import { knownTools, type BuiltinConfig, type PublishedConfig, builtin } from './model'
import { compareConfigVersion } from './version'

const ajv = new Ajv2020({ allErrors: true, strict: false })
const validateSchema = ajv.compile(schema)

export interface ValidationIssue {
  path: string
  message: string
}

const FIELD_LABELS: Record<string, string> = {
  '/llm/modelId': '模型别名',
  '/llm/timeoutSeconds': '超时秒数',
  '/llm/maxRetries': '重试次数',
  '/context/maxRecentMessages': '上下文消息条数',
  '/minClientVersion': '最低客户端版本',
  '/prompts/system/text': '系统 prompt',
}

function label(path: string): string {
  if (FIELD_LABELS[path]) return FIELD_LABELS[path]
  const tool = /^\/prompts\/tools\/([^/]+)\/description$/.exec(path)
  if (tool) return `工具 ${tool[1]} 的描述`
  return path || '配置'
}

function describe(error: ErrorObject): ValidationIssue {
  const path = error.instancePath
  const p = error.params as Record<string, unknown>
  let message: string
  switch (error.keyword) {
    case 'minimum':
      message = `不能小于 ${p.limit}`
      break
    case 'maximum':
      message = `不能大于 ${p.limit}`
      break
    case 'minLength':
      message = '不能为空'
      break
    case 'maxLength':
      message = `不能超过 ${p.limit} 个字符`
      break
    case 'pattern':
      message = '格式不对'
      break
    case 'type':
      message = `类型应为 ${p.type}`
      break
    default:
      message = error.message ?? '不合法'
  }
  return { path, message: `${label(path)}${message}` }
}

export function validatePublished(
  config: PublishedConfig,
  options: { latestVersion: string | null; base?: BuiltinConfig }
): ValidationIssue[] {
  const issues: ValidationIssue[] = []
  if (!validateSchema(config)) {
    issues.push(...(validateSchema.errors ?? []).map(describe))
  }
  const tools = new Set(knownTools(options.base ?? builtin))
  for (const name of Object.keys(config.prompts.tools)) {
    if (!tools.has(name)) issues.push({ path: `/prompts/tools/${name}`, message: `客户端没有工具 ${name}` })
  }
  if (options.latestVersion && compareConfigVersion(config.configVersion, options.latestVersion) <= 0) {
    issues.push({
      path: '/configVersion',
      message: `版本号 ${config.configVersion} 不比当前的 ${options.latestVersion} 新`,
    })
  }
  return issues
}
