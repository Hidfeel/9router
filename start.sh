#!/bin/sh
set -e

# 复制官方 entrypoint.sh 的权限修复（9Router 以 node 用户运行）
chown -R node:node /app/data /app/data-home 2>/dev/null

# ===== 调试（部署后去 Logs 顶部查看；确认无误可删这一段）=====
echo "=== DEBUG /etc/secrets ==="
ls -la /etc/secrets 2>&1 || echo "(/etc/secrets 不存在)"
echo "=== DEBUG /app/data ==="
ls -la /app/data 2>&1 || echo "(/app/data 尚不存在)"
echo "=== DEBUG DATA_DIR/db ==="
ls -la /app/data/db 2>&1 || echo "(/app/data/db 尚不存在)"
# =============================================================

mkdir -p /app/data
DB=/app/data/db/data.sqlite          # 9Router 真实主库（SQLite，受 DATA_DIR 控制）
LEGACY=/app/data/db.json             # 遗留 JSON；若 SQLite 为空且此文件存在，9Router 启动会自动迁移它

# 仅当 SQLite 还不存在时才从 Secret Files 恢复（持久盘场景盘内已有 SQLite，则跳过）。
if [ ! -f "$DB" ]; then
  # 首选：明文 JSON（Secret Files 原生支持，无 base64、无大小限制）
  if [ -f /etc/secrets/router-db.json ]; then
    cp /etc/secrets/router-db.json "$LEGACY"
    chown node:node "$LEGACY"
    echo "=== restored db.json (legacy JSON) -> 9Router 将在启动时自动迁移为 SQLite ==="
  # 后备：base64 编码的 SQLite（库较大、或拿不到 JSON 导出时使用）
  elif [ -f /etc/secrets/router-db.b64 ]; then
    base64 -d /etc/secrets/router-db.b64 > "$DB"
    chown node:node "$DB"
    echo "=== restored data.sqlite from base64 Secret File ==="
  else
    echo "=== 未找到 Secret File，将以空库启动（首次运行/未配置 Secret Files）==="
  fi
else
  echo "=== $DB 已存在（持久盘），跳过 Secret File 恢复 ==="
fi

# 以非 root 用户启动（与官方 entrypoint 行为一致：su-exec node "$@"）
# 兜底：部分平台（如 Render）运行时不向 ENTRYPOINT 传递 CMD，导致 $@ 为空，
# 此时 su-exec 直接打印 "Usage: su-exec user-spec command [args]" 并以状态 1 退出。
# 若未收到任何参数，默认启动 9Router 的独立 server（/app/custom-server.js）。
if [ "$#" -eq 0 ]; then
  set -- node /app/custom-server.js
fi
exec su-exec node "$@"
