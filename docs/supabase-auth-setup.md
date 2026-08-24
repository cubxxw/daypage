# Supabase Auth — Dashboard 配置 & 本地启动清单

> 配合 Supabase Auth 与 DayPage Cloud MCP。schema、RLS、同步 RPC、OAuth grant 和 token hook 均由仓库迁移管理；Dashboard 只负责环境级开关和密钥。

---

## 1. `.env` 必填项（已加入 `.env.example`）

| 变量 | 用途 | 取值位置 |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `@supabase/ssr` 浏览器/服务端客户端 | Supabase Dashboard → Project Settings → API → Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | 同上 | 同上 → anon public key |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | iOS 端继续使用 | 与上面同值，保持一致 |
| `RESEND_API_KEY` | （供 Supabase Dashboard 配置 SMTP 用） | resend.com → API Keys |
| `RESEND_FROM_EMAIL` | 发件人地址 | 例如 `onboarding@resend.dev`（沙盒）或自有域名 |

> Resend 的 API key / from email **不直接被 web 代码读取**。`@supabase/ssr` 走 Supabase 平台的邮件下发，所以 SMTP 凭据填到 **Supabase Dashboard 而不是 web app**。把 `.env` 里的 `RESEND_API_KEY` / `RESEND_FROM_EMAIL` 当作"自己以后查回时找得到"的备份即可。

---

## 2. Supabase Dashboard 操作清单（按顺序）

### 2.1 Auth → Providers
- [ ] 启用 **Email**（默认勾选）。Confirm email 建议开启；Allow new users to sign up 保持开启。
- [ ] **Apple** provider 暂时**不启用**：login 页保留按钮但点击会报错，符合 goal 文字"点了报错可接受，issue 备注"。后续真接通时再回来配 Services ID + Team ID + Key ID + .p8 私钥。

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
  - 部署上生产环境后再加生产域名

### 2.4 Auth → Users（创建本地 dev 账号）
- [ ] Add user → Create new user
  - Email: `dev@daypage.local`
  - Password: `devpassword`
  - Auto Confirm User: ✅（不发确认信，直接可登）
- [ ] 创建后，DB 的 trigger `on_auth_user_created`（来自 migration `0024`）会自动在 `public.users` 插一条 profile 行。

### 2.5 业务表 RLS、同步 RPC 与 MCP grant

不要在 Dashboard 手工创建通配策略。按 journal 运行迁移至 `0028_sync_receipt_integrity`；`0025` 按表结构分别处理直接 `user_id` 和通过父表归属的记录，并安装幂等同步 RPC、tombstone 与 MCP 客户端授权表，`0027` 再安装单调增量拉取序列与账户隔离的 pull RPC，`0028` 将历史回执绑定到 operation ID、memo ID、kind、revision 四元组，避免异常重试错误确认另一条操作。

### 2.6 OAuth Server、DCR 与 access-token hook

- OAuth Server: enabled
- Authorization path: `/oauth/consent`
- Dynamic client registration: enabled
- Custom access token hook: `pg-functions://postgres/public/daypage_custom_access_token_hook`
- 设置 `public.daypage_runtime_config` 中 `mcp_resource` 为该环境的 HTTPS MCP URL；空字符串会让 hook 保持 inert。

Supabase 当前只支持标准身份 scopes。DayPage 的 read-only / read-write 权限保存在 `mcp_client_grants`，并在每个 MCP 请求上再次检查，而不是伪装成 OAuth 自定义 scope。

---

## 3. 本地启动验证

1. 启动 OrbStack / Docker → `pnpm dlx supabase start`。Supabase CLI 只自动运行 `supabase/migrations`（当前是 Storage 配置），不会隐式运行 Web 的 Drizzle migrations。
2. 执行 `DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres pnpm --filter daypage-web db:migrate`，按 journal 运行 `0000` 至 `0028`。
3. `pnpm --filter daypage-web dev`（:13000）+ `pnpm --filter daypage-web dev:inngest`（:8288）。
4. 浏览器开 `127.0.0.1:13000/login` → "Dev login (no email)" → 自动跳 `/home`。
5. 退出登录 → 用真实邮箱发 magic link → 收件箱（Resend 沙盒规则下需是已验证邮箱）。

---

## 4. 不在本次 PR 范围（确认已排除）

- 内置 IMAP/SMTP 邮件客户端（用户在 goal 中明确排除）
- iCloud Family Sharing 账户共享
- `user_preferences` 双向同步与 APNs 推送
- Apple Sign-In 的 Services ID / Team ID / Key ID / `.p8` 仍需 Apple Developer 配置
- production 变更；Cloud MCP 必须先在独立 staging project 完成验证
