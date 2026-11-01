// 生成 ADMIN_PASSWORD_HASH：node scripts/hash-password.mjs，按提示输入密码（至少 12 位）。
// 格式与 src/server/auth.ts 的 verifyPassword 对应：scrypt:N:r:p:salt:hash（不用 $，免得 env 文件把它当变量展开）
import { randomBytes, scryptSync } from 'node:crypto'
import { createInterface } from 'node:readline/promises'

const rl = createInterface({ input: process.stdin, output: process.stdout })
const password = await rl.question('密码：')
rl.close()
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
