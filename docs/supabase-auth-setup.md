# Supabase Auth — Dashboard 配置 & 本地启动清单

> 配合 Supabase Auth 与 DayPage Cloud MCP。schema、RLS、同步 RPC、OAuth grant 和 token hook 均由仓库迁移管理；Dashboard 只负责环境级开关和密钥。

---

## 1. `.env` 必填项（已加入 `.env.example`）

| 变量 | 用途 | 取值位置 |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `@supabase/ssr` 浏览器/服务端客户端 | Supabase Dashboard → Project Settings → API → Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | 同上 | 同上 → anon public key |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | iOS 端继续使用 | 与上面同值，保持一致 |
| `DAYPAGE_ATTACHMENT_GC_SECRET` | 私有附件 GC 调度鉴权；仅服务端 | 每个环境独立的高熵随机值 |
| `RESEND_API_KEY` | （供 Supabase Dashboard 配置 SMTP 用） | resend.com → API Keys |
| `RESEND_FROM_EMAIL` | 发件人地址 | 例如 `onboarding@resend.dev`（沙盒）或自有域名 |

> Resend 的 API key / from email **不直接被 web 代码读取**。`@supabase/ssr` 走 Supabase 平台的邮件下发，所以 SMTP 凭据填到 **Supabase Dashboard 而不是 web app**。把 `.env` 里的 `RESEND_API_KEY` / `RESEND_FROM_EMAIL` 当作"自己以后查回时找得到"的备份即可。

---

## 2. Supabase Dashboard 操作清单（按顺序）

### 2.1 Auth → Providers
- [ ] 启用 **Email**（默认勾选）。Confirm email 建议开启；Allow new users to sign up 保持开启。
- [ ] 启用 **Apple**，并把原生 App 的 Bundle ID `com.daypage.app`、
  `com.daypage.mac` 加入允许的 Client IDs。DayPage 使用 Apple 原生 ID Token +
  SHA-256 nonce 登录；只有同时支持 Web OAuth 时才需要另外配置 Services ID 与
  定期轮换的 `.p8` client secret。

### 2.2 Auth → SMTP Settings（填 Resend）
- [ ] 打开 "Enable custom SMTP"
- [ ] Sender email: `RESEND_FROM_EMAIL` 的值（沙盒可用 `onboarding@resend.dev`）
- [ ] Sender name: `DayPage`
- [ ] Host: `smtp.resend.com`
- [ ] Port: `465`（TLS）
- [ ] Username: `resend`
- [ ] Password: `RESEND_API_KEY`（粘贴整个 `re_...` token）
- [ ] Minimum interval between emails: 默认即可
- [ ] Save

> ⚠️ 沙盒发件人 `onboarding@resend.dev` 只能投递到**注册 Resend 时验证过的邮箱**。要给任意邮箱发 magic link，必须在 Resend → Domains 验证一个自有域名，再把 `RESEND_FROM_EMAIL` 换成 `noreply@yourdomain.com`。

### 2.3 Auth → URL Configuration
- [ ] **Site URL**: `http://localhost:3000`
- [ ] **Redirect URLs** 白名单加入：
  - `http://localhost:3000/**`
  - `daypage://auth-callback`
  - `daypagemac://auth-callback`
  - 部署上生产环境后再加生产域名

### 2.4 Auth → Users（创建本地 dev 账号）
- [ ] Add user → Create new user
  - Email: `dev@daypage.local`
  - Password: `devpassword`
  - Auto Confirm User: ✅（不发确认信，直接可登）
- [ ] 创建后，DB 的 trigger `on_auth_user_created`（来自 migration `0024`）会自动在 `public.users` 插一条 profile 行。

### 2.5 业务表 RLS、同步 RPC 与 MCP grant

不要在 Dashboard 手工创建通配策略。按 journal 运行迁移至
`0029_revisioned_attachment_sync`；`0025` 安装 RLS、幂等同步 RPC、tombstone 与
MCP 客户端授权表，`0027` 安装单调增量 pull，`0028` 加固回执元组，`0029` 再安装
v2 附件 manifest、精确上传预约、配额、延迟 GC 队列与私有 worker RPC。

### 2.6 OAuth Server、DCR 与 access-token hook

- OAuth Server: enabled
- Authorization path: `/oauth/consent`
- Dynamic client registration: enabled
- Custom access token hook: `pg-functions://postgres/public/daypage_custom_access_token_hook`
- 设置 `public.daypage_runtime_config` 中 `mcp_resource` 为该环境的 HTTPS MCP URL；空字符串会让 hook 保持 inert。

Supabase 当前只支持标准身份 scopes。DayPage 的 read-only / read-write 权限保存在 `mcp_client_grants`，并在每个 MCP 请求上再次检查，而不是伪装成 OAuth 自定义 scope。

---

## 3. 本地启动验证

仓库根目录的 `.env` 面向 iOS/Web 与托管 Supabase；本地容器不读取其中的生产配置。
`pnpm db:start` 会使用锁定版本的 Supabase CLI，生成与线上相同的 MCP Edge bundle，
首次创建被 Git 忽略的 `supabase/functions/.env`（只含本地 URL 与本地专用 GC
secret），启动容器，然后按顺序运行 Storage migration 和 Web Drizzle journal
`0000` 至 `0029`。

1. 启动 OrbStack / Docker，然后执行 `pnpm db:start`。
2. 执行 `pnpm backend:verify:local`。它创建一次性本地用户并验证 Vault/outbox push、
   两个独立 Vault 的文本/图片/音频/PDF create/edit/delete/restore、TUS 续传、预约
   与跨租户负例、私有 GC，以及 PAT 鉴权的 MCP read/write；结束后清理测试用户与对象。
3. 需要从空数据库复验 migration 时执行 `pnpm db:reset`；停止并保留本地数据执行 `pnpm db:stop`。
4. Web 联调执行 `pnpm --filter daypage-web dev`（:13000）和
   `pnpm --filter daypage-web dev:inngest`（:8288）。
5. 浏览器开 `127.0.0.1:13000/login` → "Dev login (no email)" → 自动跳 `/home`。
6. 退出登录 → 用真实邮箱发 magic link → 收件箱（Resend 沙盒规则下需是已验证邮箱）。

---

## 4. 不在本次 PR 范围（确认已排除）

- 内置 IMAP/SMTP 邮件客户端（用户在 goal 中明确排除）
- iCloud Family Sharing 账户共享
- `user_preferences` 双向同步与 APNs 推送
- Apple Sign-In 的原生 App ID entitlement、Supabase Provider 开关与 Client IDs
  必须在对应环境核对；Web OAuth 所需的 Services ID / Team ID / Key ID / `.p8`
  不属于原生 ID Token 流程
- production 变更；Cloud MCP 必须先在独立 staging project 完成验证
