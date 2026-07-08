# 基于官方镜像，而非从源码 build。
# 官方仓库根目录那个 start.sh 是「本地 docker 构建脚本」，不是容器入口，
# 所以我们这里用 /start.sh 命名，避免和官方文件冲突。
FROM decolua/9router:latest

# 把我们的入口脚本放进去，替换官方 ENTRYPOINT（官方 entrypoint 是 su-exec node "$@"，
# 会把 Render 的 Docker Command 当整串命令名执行 -> not found）。
COPY start.sh /start.sh
RUN chmod +x /start.sh

# 官方镜像 CMD 已为 ["node", "custom-server.js"]，start.sh 里用 su-exec node "$@" 接力。
ENTRYPOINT ["/start.sh"]
