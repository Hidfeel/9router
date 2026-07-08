# 9Router on Render —— 无稳定硬盘的解决方案

Render 本地磁盘默认 ephemeral（每次 deploy/重启清空）。下面是用 **Render 平台自身能力**
让 9Router 在「无稳定硬盘」下也能恢复配置的可运行方案。

---

## 关于 `docs/ARCHITECTURE.md`（你问的这份）

**它已经过时了，不能直接照着做。** 核实源码后结论：

- `ARCHITECTURE.md` 说主库是 `${DATA_DIR}/db.json`（JSON 文件）。但 `src/lib/localDb.js`
  现在整个文件只是个 **shim**，注释明写 `// Shim → re-export from new SQLite-based DB layer`，
  真实实现在 `src/lib/db/`。
- 主库真实路径（`src/lib/db/paths.js`）：`DATA_FILE = path.join(DATA_DIR, "db", "data.sqlite")`
  → 容器里即 **`/app/data/db/data.sqlite`**（受 `DATA_DIR` 环境变量控制）。
- 旧 `db.json` 被定义为 `LEGACY_FILES.main`，仅作遗留兼容；`migrate.js` 会在 SQLite 为空时
  **自动把 `db.json` 迁移进 SQLite**。

所以：文档请以 `DOCKER.md` 和源码为准，别信 `ARCHITECTURE.md` 的存储描述。

---

## 文件说明

- `Dockerfile` —— `FROM decolua/9router:latest`（官方镜像，多平台），只加 `/start.sh` 并设为 ENTRYPOINT。
- `start.sh` —— 启动前：修权限 → 从 Secret File 恢复配置 → `su-exec node "$@"` 接力官方 CMD。
- `render.yaml` —— Render Blueprint，指向 `./deploy/render/Dockerfile`。

---

## 方案 A：Secret Files（免费 / 无盘，推荐先试）

9Router 启动时会：若 SQLite 为空库 **且** 存在 `DATA_DIR/db.json`，自动把该 JSON 迁移进 SQLite。
因此**首选把配置存成明文 JSON 文本**进 Secret Files（无 base64、无二进制大小限制）。

### A-1. 准备 Secret File 内容（两种格式，任选）

**首选：JSON 文本（`router-db.json`）**
- 内容 = 一份 legacy 格式的 `db.json`。获取方式（任一）：
  1. 你用过的**旧版** 9Router 本机文件 `~/.9router/db.json`（直接用它）；
  2. 在当前/临时 9Router 实例里用「导出配置」拿到 JSON（结构与 legacy `db.json` 兼容，
     因为 `exportDb()` 导出的字段名与 `importLegacyMain` 读取的完全一致）；
  3. 首run 先用持久盘或本地容器配好账号，再想办法导出/拷出（见下方「鸡生蛋」）。
- 粘贴进 Secret Files，挂载路径 **`/etc/secrets/router-db.json`**。

**后备：base64 SQLite（`router-db.b64`）** —— 拿不到 JSON 导出、或库较大时用。
```sh
# 从已运行的实例拷贝主库后编码（本机/临时容器）
base64 -i /app/data/db/data.sqlite -o router-db.b64   # macOS
# Linux: base64 -w0 /app/data/db/data.sqlite > router-db.b64
```
粘贴进 Secret Files，挂载路径 **`/etc/secrets/router-db.b64`**。

> ⚠️ 两种都含 OAuth token 等敏感数据，仅存进 Render Secret Files（加密、不进 git）。

### A-2. Render Dashboard → Secret Files → New File
- 内容：上面其一
- 挂载路径：`/etc/secrets/router-db.json` **或** `/etc/secrets/router-db.b64`（与 start.sh 对应）

### A-3. 部署 / Redeploy
去 **Logs** 顶部看 DEBUG，应出现：
```
=== restored db.json (legacy JSON) -> 9Router 将在启动时自动迁移为 SQLite ===
# 或
=== restored data.sqlite from base64 Secret File ===
```

### A-4. 改配置怎么办
无盘重启会清空 `/app/data`，于是每次都从 Secret File 重新恢复 → **以 Secret File 为准**。
改配置流程：在实例里改好 → 重新导出 JSON（或重新 base64 编码 data.sqlite）→ 更新 Secret Files → Redeploy。

### ⚠️ 鸡生蛋（首次拿配置）
新装 9Router 直接写 SQLite，**不会**生成 `db.json`。首次配置建议：
1. 先在本机 Docker / 临时容器（挂卷）配好账号，确认可用；
2. 用它页面「导出配置」拿 JSON → 存 Secret File（JSON 方案）；
3. 或 `docker cp` 出 `/app/data/db/data.sqlite` → base64 编码 → 存 Secret File（b64 方案）；
4. 之后删掉临时容器，Render 免费实例即可靠 Secret File 自举。

### ⚠️ Secret Files 大小限制
明文单文件有大小上限。JSON 通常比 SQLite 小很多，但若 provider/用量历史极多仍可能超限。
超限请改用方案 B（持久盘）或外置对象存储 / Supabase。

---

## 方案 B：持久盘（付费实例，最稳）

取消 `render.yaml` 里 `disks` 段的注释，在 Render 给 disk 设大小(≥1GB)并确认挂载 `/app/data`。
- `start.sh` 检测到 `/app/data/db/data.sqlite` 已存在 → **跳过 Secret File 恢复**，直接用盘内数据；
- 运行期写入正常持久化，重启不丢；二进制 SQLite 无压力，不受大小限制。

---

## 常见报错

### `sh: <整串命令>: not found`
源于官方镜像 `ENTRYPOINT ["/entrypoint.sh"]`（`exec su-exec node "$@"`），Render 的 Docker Command
被当单字符串 → 整串当作命令名。本方案已用镜像内 `/start.sh` 替换入口，yaml 无 `dockerCommand`，不会再触发。

### 日志里看不到 DEBUG / 配置没恢复
- 去 **Logs（运行日志）**，不是 Build（构建）日志；
- 确认 **Secret Files 的 mount path 字面量**就是 `/etc/secrets/router-db.json`（或 `.b64`）；
- JSON 方案注意：恢复目标是 **`/app/data/db.json`**（DATA_DIR 根，**不是** `/app/data/db/` 子目录）；
- 免费实例会休眠，手动点一次 Deploy 再查 Logs。

---

## 验证清单

- [ ] 仓库 `deploy/render/` 下有 `Dockerfile` + `start.sh`，`render.yaml` 已连仓库
- [ ] Secret Files：内容 = db.json(JSON) 或 base64(data.sqlite)；mount path 匹配
- [ ] Logs 顶部出现 `=== restored ... ===`
- [ ] 面板 `http://<svc>.onrender.com` 能看到恢复的 provider / 组合
- [ ] 确认无误后，删掉 `start.sh` 里的 DEBUG 段（三处 echo/ls）
