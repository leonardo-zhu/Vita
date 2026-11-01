/**
 * 发布（vita-admin.md §8.1）：把配置文件原子写进发布目录，由 R4S 上的 Caddy 以 /config/* 直接提供，
 * 不经过 Next.js。先写临时文件再 rename，Caddy 不会读到写了一半的文件。
 * 将来换托管只需换掉这个实现。
 */
import { mkdirSync, renameSync, writeFileSync } from 'node:fs'
import path from 'node:path'

import { dataDir } from '../db'

export function publishDir(): string {
  return path.resolve(/*turbopackIgnore: true*/ process.env.VITA_PUBLISH_DIR || path.join(dataDir(), 'published'))
}

export function publishFile(channel: string, body: string) {
  const dir = publishDir()
  mkdirSync(dir, { recursive: true })
  const target = path.join(dir, `${channel}.json`)
  const temp = path.join(dir, `.${channel}.json.${process.pid}.tmp`)
  writeFileSync(temp, body)
  renameSync(temp, target)
}
