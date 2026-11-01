import type { Messages } from '@/i18n/messages'
import type { ValidationIssue } from '@/server/config/validate'

/** 校验问题的说明文字：字段名 + 规则，按当前语言 */
export function issueText(t: Messages, issue: ValidationIssue): string {
  const tool = /^\/prompts\/tools\/([^/]+)/.exec(issue.path)?.[1]
  const field =
    t.issues.fieldByPath[issue.path as keyof Messages['issues']['fieldByPath']] ??
    (tool ? t.diff.toolDescription(tool) : issue.path || t.issues.config)
  return t.issues.rule[issue.rule](field, issue.param)
}
