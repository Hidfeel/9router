#!/bin/sh
set -e

# 复制官方 entrypoint.sh 的权限修复（9Router 以 node 用户运行）
chown -R node:node /app/data /app/data-home 2>/dev/null

# ===== 调试（部署后去 Logs 顶部查看；确认无误可删这一段）=====
echo "=== DEBUG /etc/secrets ==="
ls -la /etc/secrets 2>&1 || echo "(/etc/secrets 不存在)"
echo "=== DEBUG /app/data/db ==="
ls -la /app/data/db 2>&1 || echo "(/app/data/db 尚不存在)"
# =============================================================

mkdir -p /app/data/db
DB=/app/data/db/data.sqlite
# Render Secret File 存的是「base64 编码后的 data.sqlite 文本」（明文文本才能进 Secret Files）
SECRET=/etc/secrets/router-db.b64

if [ -f "$SECRET" ]; then
  # 仅当目标不存在时才恢复：挂了持久盘(重启后盘内有数据)就跳过，避免覆盖。
  if [ ! -f "$DB" ]; then
    base64 -d "$SECRET" > "$DB"
    chown node:node "$DB"
    echo "=== restored data.sqlite from Secret File (base64) ==="
  else
    echo "=== $DB 已存在，跳过恢复（持久盘优先）==="
  fi
else
  echo "=== 未找到 $SECRET，将以空库启动（首次运行/未配置 Secret Files）==="
fi

# 以非 root 用户启动（与官方 entrypoint 行为一致：exec su-exec node "$@"）
exec su-exec node "$@"
