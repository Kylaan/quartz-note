#!/bin/sh
set -eu

# 云机侧错峰拉取：把 NAS 上构建好的静态产物 sync 到本地 /site，nginx 伺服本地副本。
# 站点与 NAS 解耦——NAS 掉线/tailnet 抖动也不影响访问（伺服的是上一份本地拷贝）。

: "${SITE_REMOTE:?SITE_REMOTE 未设置（例：NAS:site，指向 AList 上的构建产物目录）}"
: "${PULL_INTERVAL:=300}"   # 每轮检查间隔（秒）
: "${LOAD_MAX:=1.5}"        # 宿主机 1 分钟负载高于此值就退避（2 核机建议 1.5）
: "${BWLIMIT:=2M}"          # rclone 带宽上限，温柔拉取（按需调，0 为不限）
: "${IDLE_WAIT:=30}"        # 负载偏高时每次退避的秒数
: "${IDLE_MAX_TRIES:=20}"   # 连续退避多少次后强制拉一次（防止永远等不到空闲）

DEST=/site
mkdir -p "$DEST"

# 等宿主机空闲：/proc/loadavg 在容器里反映的是宿主机全局负载，IO 繁忙(D 状态)也会抬高它，
# 所以用 load1 当"忙不忙"的近似闸门。浮点比较交给 awk。
idle_wait() {
  tries=0
  while :; do
    load1=$(cut -d' ' -f1 /proc/loadavg)
    if awk -v l="$load1" -v m="$LOAD_MAX" 'BEGIN{exit !(l>m)}'; then
      tries=$((tries + 1))
      if [ "$tries" -ge "$IDLE_MAX_TRIES" ]; then
        echo "[idle] 负载持续偏高($load1>$LOAD_MAX)，已等 $((tries*IDLE_WAIT))s，强制拉取一次"
        return 0
      fi
      echo "[idle] 宿主机负载 $load1 > $LOAD_MAX，等待 ${IDLE_WAIT}s..."
      sleep "$IDLE_WAIT"
    else
      return 0
    fi
  done
}

while true; do
  idle_wait
  echo "===== $(date '+%F %T') 错峰拉取构建产物（load=$(cut -d' ' -f1 /proc/loadavg)）====="
  # ionice -c3：空闲 IO 类，只在磁盘没别人用时才读写；nice -n19：最低 CPU 优先级；
  # --bwlimit + 低并发：尽量不打扰宿主机上的其它服务。
  if ionice -c 3 nice -n 19 rclone sync "$SITE_REMOTE" "$DEST" \
       --bwlimit "$BWLIMIT" --transfers 1 --checkers 2 --fast-list -v; then
    echo "[ok] 已更新到 $DEST"
  else
    echo "[warn] 拉取失败（NAS/AList 不可达？检查 tailscale），沿用现有站点"
  fi
  echo "===== 休眠 ${PULL_INTERVAL}s ====="
  sleep "$PULL_INTERVAL"
done
