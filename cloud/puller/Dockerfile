# 云机侧：只负责"错峰、限速地把 NAS 上已构建好的静态产物拉到本地"。
# 极轻——不含 node/quartz，只有 rclone + ionice/nice，整机内存几乎无负担。
FROM rclone/rclone:latest AS rclone

FROM alpine:3.20
# util-linux 提供 ionice（空闲 IO 调度）；busybox 自带 nice；tzdata 让日志时间正确
RUN apk add --no-cache util-linux coreutils tzdata ca-certificates

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

COPY puller/entrypoint-pull.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
