// 生成 ADMIN_PASSWORD_HASH：node scripts/hash-password.mjs，按提示输入密码（至少 12 位）。
// 格式与 src/server/auth.ts 的 verifyPassword 对应：scrypt:N:r:p:salt:hash（不用 $，免得 env 文件把它当变量展开）
import { randomBytes, scryptSync } from 'node:crypto'
import { createInterface } from 'node:readline/promises'
import { Writable } from 'node:stream'

// 输入密码时不回显：提示语照常输出，之后的按键不写到终端
let muted = false
const output = new Writable({
  write(chunk, encoding, callback) {
    if (!muted) process.stdout.write(chunk, encoding)
    callback()
  },
})
const rl = createInterface({ input: process.stdin, output, terminal: true })
const question = rl.question('密码（输入时不显示）：')
muted = true
const password = await question
muted = false
rl.close()
process.stdout.write('\n')
if (password.length < 12) {
  console.error('密码至少 12 位')
  process.exit(1)
}
const N = 16384
const r = 8
const p = 1
const salt = randomBytes(16)
const hash = scryptSync(password, salt, 32, { N, r, p })
console.log(['scrypt', N, r, p, salt.toString('base64'), hash.toString('base64')].join(':'))
