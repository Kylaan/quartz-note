#!/bin/sh
set -eu

: "${RCLONE_REMOTE:?RCLONE_REMOTE 未设置（例：NAS:obsidian）}"
: "${SYNC_INTERVAL:=600}"
: "${SITE_TITLE:=我的笔记}"
: "${BASE_URL:=localhost}"
: "${STARTUP_DELAY:=20}"   # 开机错峰：先等宿主机/其它容器就绪，避开同时启动的内存峰值

CONTENT=/quartz/content
CONFIG=/quartz/quartz.config.yaml
FP=/site/.content.fingerprint   # 上次成功构建对应的内容指纹（存在 site 卷里，重启后仍在）

# 限制 Node 构建内存——小内存机上别让 build 把宿主机拖进 swap
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=512}"

# 用环境变量就地定制 Quartz v5 的 YAML 配置（configuration 下的 2 空格缩进字段）
sed -i "s|^  pageTitle:.*|  pageTitle: \"${SITE_TITLE}\"|" "$CONFIG" || true
sed -i "s|^  baseUrl:.*|  baseUrl: \"${BASE_URL}\"|"       "$CONFIG" || true
sed -i "s|^  locale:.*|  locale: zh-CN|"                   "$CONFIG" || true

mkdir -p "$CONTENT"

# 计算内容指纹（文件相对路径+大小+mtime 的哈希）。排除构建时才生成的 index.md，保证稳定。
content_fp() {
  find "$CONTENT" -type f ! -name index.md -printf '%P %s %T@\n' 2>/dev/null \
    | LC_ALL=C sort | md5sum | cut -d' ' -f1
}

# ── 一轮：同步白名单 →（指纹比对，或 FORCE=1 强制）→ 构建 → 发布到 /site ──
one_pass() {
  FORCE="${1:-0}"
  echo "===== $(date '+%F %T') rclone 同步白名单 ====="
  # --max-size 15M：忽略 >15MiB 的大文件（视频/大 PDF），站点不发布它们；
  #   配合 --delete-excluded，content 里已有的大文件也会被清掉。
  if rclone sync "$RCLONE_REMOTE" "$CONTENT" \
       --filter-from /quartz/filter-public.txt \
       --max-size 15M \
       --delete-excluded --transfers 4 --checkers 8 -v; then
    echo "[ok] 同步完成"
  else
    echo "[warn] rclone 同步失败（NAS 不可达？检查 tailscale），沿用已有内容"
  fi

  # 只要 content 里有东西就考虑构建
  if [ -n "$(ls -A "$CONTENT" 2>/dev/null | grep -v '^index.md$' || true)" ]; then
    NEW_FP="$(content_fp)"
    OLD_FP="$(cat "$FP" 2>/dev/null || true)"
    if [ "$FORCE" != "1" ] && [ "$NEW_FP" = "$OLD_FP" ] && [ -f /site/index.html ]; then
      # 内容未变且站点已在 → 跳过重量级 build（这是避免开机/重启卡死的关键）
      echo "[skip] 内容无变化且站点已存在，跳过构建（省内存）"
    else
      [ "$FORCE" = "1" ] && echo "[force] 手动触发，强制构建（忽略指纹）"
      # rclone --delete-excluded 每轮会清掉非白名单文件，故同步后补站点首页
      printf '%s\n' '---' "title: ${SITE_TITLE}" '---' '' \
        "# ${SITE_TITLE}" '' '这里是公开发布的学习笔记，左侧/搜索进入各章节。' \
        > "$CONTENT/index.md"
      echo "===== 构建 Quartz ====="
      # BUILD_CONCURRENCY：worker 线程数。NAS 内存足可留空（按核数自动跑满，最快）；
      # 小内存机设 1 砍掉峰值内存（默认按核数开会翻倍易 OOM）。
      CONC=""
      [ -n "${BUILD_CONCURRENCY:-}" ] && CONC="--concurrency ${BUILD_CONCURRENCY}"
      if npx quartz build $CONC; then
        # Quartz 输出到容器内 /quartz/public，再镜像同步到挂载卷 /site（含删除）
        rclone sync /quartz/public /site --transfers 4 --checkers 8
        echo "$NEW_FP" > "$FP"   # 记下本次已发布内容的指纹，下次无变化即跳过
        echo "[ok] 已发布到 /site"
      else
        echo "[warn] 构建失败（可能内存不足被 OOM），保留 /site 上一版"
        return 1
      fi
    fi
  else
    echo "[warn] content 为空且无法同步，跳过构建（首次需先连上 NAS）"
  fi
}

# ── 模式分发：once = 手动一次性强制构建后退出（供 publish 脚本远程触发）；默认 = 轮询循环 ──
if [ "${1:-loop}" = "once" ]; then
  echo "===== 手动触发：一次性强制构建 ====="
  if one_pass 1; then
    echo "===== [once] 构建完成 ====="
    exit 0
  else
    echo "===== [once] 构建失败 ====="
    exit 1
  fi
fi

# 开机错峰：第一轮构建前先让位给同时启动的其它容器/宝塔/tailscale
if [ "${STARTUP_DELAY:-0}" -gt 0 ] 2>/dev/null; then
  echo "启动错峰，等待 ${STARTUP_DELAY}s 让宿主机就绪..."
  sleep "$STARTUP_DELAY"
fi

while true; do
  one_pass 0 || echo "[warn] 本轮未成功，下轮重试"
  echo "===== 休眠 ${SYNC_INTERVAL}s ====="
  sleep "$SYNC_INTERVAL"
done
