# 9Router on Render —— 无稳定硬盘的解决方案

Render 本地磁盘默认 ephemeral（每次 deploy/重启清空）。下面是用 **Render 平台自身能力**
让 9Router 在「无稳定硬盘」下也能恢复配置的可运行方案。

---

## 三个关键事实（决定了方案长这样）

1. **官方有现成镜像 `decolua/9router:latest`**（Docker Hub，多平台 amd64/arm64）。
   不用 fork 9router 仓库、不用从源码 build，直接 `FROM` 它。**部署快、且避开官方仓库里那个同名 `start.sh`**。

2. **官方仓库根目录的 `start.sh` 不是容器入口**，只是开发机本地 `docker build/run` 的便捷脚本：
   ```sh
   docker stop 9router
   docker rm 9router
   docker build -t 9router .
   docker run -d --name 9router -p 20128:20128 --env-file .env -v 9router-data:/app/data 9router
   ```
   它**不能**替掉容器里的 `su-exec` 入口，所以「仓库里已经有 start.sh」并不会让问题变简单。

3. **官方镜像入口是 `ENTRYPOINT ["/entrypoint.sh"]`，内容为 `exec su-exec node "$@"`**。
   Render 的 Docker Command 被当成**单个字符串**传给它，于是整串被当作一个可执行文件名
   → `sh: <整串>: not found`。**任何 `sh -c '...'` 包裹都救不了**（包裹照样被吞）。
   唯一解：在镜像里放一个真实 shell 脚本替换 ENTRYPOINT，让分词在 shell 内发生。

4. **数据布局已变：不再是 `db.json`，现在是 SQLite `/app/data/db/data.sqlite`**（来自官方 DOCKER.md）。
   Secret Files 是**明文文本**，不适合直接挂二进制 SQLite，所以要把 SQLite 做 **base64 编码**
   成文本再存进 Secret File，启动时 `base64 -d` 还原。

---

## 文件说明

- `Dockerfile` —— `FROM decolua/9router:latest`，只加一个 `/start.sh` 并设为 ENTRYPOINT。
- `start.sh` —— 启动前：修权限 → 从 Secret File 恢复 `data.sqlite` → `su-exec node "$@"` 接力官方 CMD。
- `render.yaml` —— Render Blueprint，指向 `./deploy/render/Dockerfile`。

---

## 方案 A：Secret Files（免费 / 无盘，推荐先试）

### 1. 本地生成 Secret File 内容（base64 编码的 SQLite）

先在你**已经配好账号的本机** 9Router 上找到库文件：
```sh
# 本机数据目录（macOS/Linux）
ls -la "$HOME/.9router/db/data.sqlite"
# 编码成单行 base64 文本
base64 -i "$HOME/.9router/db/data.sqlite" -o router-db.b64
```
打开 `router-db.b64`，把内容**完整复制**。

> ⚠️ 该文件含 OAuth token 等敏感数据，仅存进 Render Secret Files（加密、不进 git），不要提交到仓库。

### 2. Render Dashboard → Secret Files → New File
- 内容：粘贴上一步的 base64 文本
- 挂载路径（mount path）：**`/etc/secrets/router-db.b64`**
  （必须和 `start.sh` 里的 `$SECRET` 路径逐字一致）

### 3. 部署 / Redeploy
去 **Logs** 顶部看 DEBUG 输出，应出现：
```
=== restored data.sqlite from Secret File (base64) ===
```
配置即恢复。

### 4. 改配置怎么办
运行期在 UI 里的改动会写回 `/app/data/db/data.sqlite`，但重启后 ephemeral 盘清空、又会从
Secret File 恢复 → **以 Secret File 为准**。改配置流程：
1. 在本机或临时容器改好；
2. 重新 `base64` 编码 → 更新 Render Secret Files 内容；
3. Redeploy。

### ⚠️ Secret Files 大小限制
Render Secret Files 对单文件有大小上限（明文，base64 后约膨胀 33%）。若你的 `data.sqlite`
较大（装了很多 provider token / 用量历史），可能超限而无法保存。**若超限，请改用方案 B（持久盘）
或把状态外置到对象存储 / Supabase（见下文进阶）**。免费档只适合「库比较小」的情况。

---

## 方案 B：持久盘（付费实例，最稳）

取消 `render.yaml` 里 `disks` 段的注释，在 Render 给 disk 设大小(≥1GB)并确认挂载 `/app/data`。
此时：
- 启动脚本检测到 `/app/data/db/data.sqlite` 已存在 → **跳过 Secret File 恢复**，直接用盘内数据；
- 运行期写入正常持久化，重启不丢；
- 二进制 SQLite 无压力，不受 Secret Files 大小限制。

---

## 常见报错

### `sh: <整串命令>: not found`
原因见「事实 3」。出现在你用 Render 的 Docker Command 传复合命令时。本方案已用镜像内
`/start.sh` 替换 entrypoint，yaml 里**没有** `dockerCommand`，不会再触发此错。

### 日志里看不到 DEBUG / 配置没恢复
- 去 **Logs（运行日志）**，不是 Build（构建）日志——调试输出只在运行时出现；
- 确认 **Secret Files 的 mount path 字面量就是 `/etc/secrets/router-db.b64`**；
- 确认 `router-db.b64` 内容是完整的 base64（没被截断/换行破坏）；
- 免费实例会休眠，手动点一次 Deploy 再查 Logs。

---

## 进阶：免费 + 配置热更新（不重建镜像）

若想「免费 + 运行时改了配置也能保存」，可让 `start.sh` 改为**从对象存储 / Supabase 拉回
`data.sqlite`**（二进制友好），而非用 Secret Files。社区工具 **9router-sync** 可把
`providerConnections` 双向同步到 Supabase。这超出本目录范围，需要我再补 `entrypoint.sh` 拉取版可说。

---

## 验证清单

- [ ] 仓库 `deploy/render/` 下有 `Dockerfile` + `start.sh`，`render.yaml` 已连仓库
- [ ] Secret Files 内容 = 本机 `base64 data.sqlite`，mount path = `/etc/secrets/router-db.b64`
- [ ] Logs 顶部出现 `=== restored data.sqlite from Secret File (base64) ===`
- [ ] 面板 `http://<svc>.onrender.com` 能看到恢复的 provider / 组合
- [ ] 确认无误后，删掉 `start.sh` 里的 DEBUG 段（两处 echo/ls）
