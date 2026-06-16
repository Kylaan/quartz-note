# rclone 二进制直接取自官方镜像，免 apt
FROM rclone/rclone:latest AS rclone

# node:22（非 slim）自带 git/curl/ca-certificates，无需任何 apt 安装
# （Quartz v5 要求 node >= 22）
FROM node:22

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

WORKDIR /quartz

# 克隆 Quartz v5 并安装依赖（npm 走 npmmirror，国内快很多）
RUN git clone --depth 1 https://github.com/jackyzha0/quartz.git . \
 && npm config set registry https://registry.npmmirror.com \
 && npm install

# 生成 YAML 配置 → 关掉需要联网取字体的 og-image → 只装配置引用到的插件
# （--from-config 跳过 lockfile 里那个会超时的 quartz-themes；插件 baked 进镜像，
#  运行时构建完全离线、不依赖外网）
RUN cp quartz.config.default.yaml quartz.config.yaml \
 && npx quartz plugin disable og-image \
 && npx quartz plugin install --from-config

# 修补 ofm 插件：SVG 嵌入、HTML 嵌入、Obsidian 行间公式（见脚本注释）
COPY builder/patch-ofm.js /tmp/patch-ofm.js
RUN node /tmp/patch-ofm.js

# 白名单与入口脚本（baked 进镜像；改白名单后重新 build 即可）
COPY filter-public.txt /quartz/filter-public.txt
COPY builder/entrypoint.sh /entrypoint.sh
# 抹掉 Windows 换行，避免 sh 解释 CRLF 出错
RUN sed -i 's/\r$//' /entrypoint.sh /quartz/filter-public.txt \
 && chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
