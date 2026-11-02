/**
 * 发布前校验（vita-admin.md §6 / §8.3）：与客户端共用 shared/config-schema/config.schema.json，
 * 再补上 schema 表达不了的规则。校验不过不能发布。
 * 结果只给规则与参数，文字由界面按当前语言生成（`@/lib/issue-text`）。
 */
import Ajv2020, { type ErrorObject } from 'ajv/dist/2020'

import schema from '@/generated/config.schema.json'

import { knownTools, type BuiltinConfig, type PublishedConfig, builtin } from './model'
import { compareConfigVersion } from './version'

const ajv = new Ajv2020({ allErrors: true, strict: false })
const validateSchema = ajv.compile(schema)

export type IssueRule =
  | 'minimum'
  | 'maximum'
  | 'empty'
  | 'maxLength'
  | 'pattern'
  | 'type'
  | 'enum'
  | 'reservedKey'
  | 'tooManyKeys'
  | 'unknownTool'
  | 'versionNotNewer'
  | 'aliasMissing'
  | 'other'

export interface ValidationIssue {
  path: string
  rule: IssueRule
  /** 上下限、长度上限、类型名、工具名或版本号，视规则而定 */
  param?: string | number
}

function fromAjv(error: ErrorObject): ValidationIssue {
  const p = error.params as Record<string, unknown>
  const path = error.instancePath
  switch (error.keyword) {
    case 'minimum':
      return { path, rule: 'minimum', param: p.limit as number }
    case 'maximum':
      return { path, rule: 'maximum', param: p.limit as number }
    case 'minLength':
      return { path, rule: 'empty' }
    case 'maxLength':
      return { path, rule: 'maxLength', param: p.limit as number }
    case 'pattern':
      return { path, rule: 'pattern' }
    case 'type':
      return { path, rule: 'type', param: String(p.type) }
    case 'enum':
      return { path, rule: 'enum', param: (p.allowedValues as unknown[]).join(' / ') }
    case 'propertyNames':
      return { path, rule: 'reservedKey', param: p.propertyName as string }
    case 'maxProperties':
      return { path, rule: 'tooManyKeys', param: p.limit as number }
    default:
      return { path, rule: 'other', param: error.message }
  }
}

export function validatePublished(
  config: PublishedConfig,
  options: { latestVersion: string | null; base?: BuiltinConfig }
): ValidationIssue[] {
  const issues: ValidationIssue[] = []
  if (!validateSchema(config)) {
    // propertyNames 不通过时 ajv 还会报一条内层的 not，只留外层那条
    const errors = (validateSchema.errors ?? []).filter((e) => !e.schemaPath.includes('/propertyNames/'))
    issues.push(...errors.map(fromAjv))
  }
  const tools = new Set(knownTools(options.base ?? builtin))
  for (const name of Object.keys(config.prompts.tools)) {
    if (!tools.has(name)) issues.push({ path: `/prompts/tools/${name}`, rule: 'unknownTool', param: name })
  }
  if (options.latestVersion && compareConfigVersion(config.configVersion, options.latestVersion) <= 0) {
    issues.push({ path: '/configVersion', rule: 'versionNotNewer', param: options.latestVersion })
  }
  return issues
}
