# notes-site

把 NAS 上的 Obsidian 笔记（白名单子集）自动编译成一个 Quartz 静态站点，对外发布。

**构建放在 NAS（内存足），公网云机只做"错峰拉取 + nginx 伺服"**——重活离开 1.6G 的小云机，OOM/卡死问题从云机消失。

```
Obsidian ─Remotely Save─▶ NAS(AList S3, tailnet 100.68.43.37:5246)
   ┌──────────────────────────────────────────────────────────┐
   │ NAS  推送 nas/ 整箱 → docker compose up -d --build        │
   │  builder(node22+rclone): loop                             │
   │   rclone 拉白名单笔记 → quartz build → 产物写入            │
   │   /srv/notes-site/public（AList 暴露成 NAS:site 供拉取）   │
   └──────────────────────────────────────────────────────────┘
                    │ 云机错峰、限速 rclone sync（ionice+nice+bwlimit）
                    ▼
   ┌──────────────────────────────────────────────────────────┐
   │ 云机  推送 cloud/ 整箱 → docker compose up -d --build      │
   │  puller(alpine+rclone): 宿主机空闲时把产物 sync 到 site 卷 │
   │  web(nginx:alpine): 只读托管 site 卷 → 127.0.0.1:8089     │
   └──────────────────────────────────────────────────────────┘
                                          └─▶ 你的 OpenResty/Nginx 反代
```

- **NAS builder** 每 `SYNC_INTERVAL` 秒：按 `filter-public.txt` 白名单拉笔记 → Quartz 构建 → 产物写入 NAS 上的目录（内容指纹未变则跳过构建）。白名单在 NAS 端就生效，私域内容**根本不进构建、更不会到公网机**。
- **云机 puller** 每 `PULL_INTERVAL` 秒：在**宿主机空闲时**（读 `/proc/loadavg` 当闸门）用 `ionice -c3 nice -n19 --bwlimit` 温柔地把产物 sync 到本地 `site` 卷。站点伺服的是本地副本，**NAS 掉线/tailnet 抖动也不影响访问**。
- **web** 只读挂载 `site` 卷，发布到 `127.0.0.1:8089`（`8088` 已被 408-nav 占用）。
- 用的是 **Quartz v5**（YAML 配置，需 node ≥ 22）。社区插件在**镜像构建时**从 GitHub 预装并 baked 进镜像，**运行时构建完全离线**；`og-image` 插件因需联网取字体已默认关闭。
- 云机镜像极轻（alpine + rclone，无 node/quartz），`mem_limit: 256m` 足够。

## 前置条件

1. **两台机器都在 tailnet 上**（`tailscale up`）：NAS builder 要连 AList 拉笔记，云机 puller 要连 NAS 拉产物。
2. NAS 与云机都装了 Docker / Docker Compose。**NAS 上镜像构建需能访问 GitHub**（预装 Quartz v5 插件）和 npm（走 npmmirror）；云机镜像只需 Docker Hub（alpine + rclone）。
3. NAS 上把构建产物目录（`/srv/notes-site/public`）在 **AList 里加成一个存储**，使云机能用 `SITE_REMOTE=NAS:site` 读到（路径/桶名按你的 AList 配置，与 `.env` 对应）。

## 部署

仓库分成两个**各自自包含、可独立打包推送**的目录：`nas/` 推到 NAS，`cloud/` 推到云机。各自 `cp .env.example .env` 填好后，在该目录里 `docker compose up -d --build` 即可。

**① 先把 `nas/` 推到 NAS 上起构建：**

```bash
cd nas
cp .env.example .env   # 填 NAS 凭据、RCLONE_REMOTE=NAS:obsidian、BASE_URL、SITE_TITLE
# docker-compose.yml 里把 /srv/notes-site/public 改成你 NAS 的真实产物目录
docker compose up -d --build
docker compose logs -f builder    # 看到「已发布到 /site」即成功
# 然后在 AList 里把该产物目录暴露出来（供云机拉取）
```

**② 再把 `cloud/` 推到云机上起拉取+伺服：**

```bash
cd cloud
cp .env.example .env   # 填 NAS 凭据、SITE_REMOTE=NAS:site，可调 LOAD_MAX / BWLIMIT / PULL_INTERVAL
docker compose up -d --build
docker compose logs -f puller     # 看到「已更新到 /site」即成功
```

访问 `http://127.0.0.1:8089`，然后在你的反代里把域名转发过去：

```nginx
location / {
    proxy_pass http://127.0.0.1:8089;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

## 发布哪些内容

- **选择目录**：编辑 `nas/filter-public.txt`（白名单，路径相对桶根）。新增一个公开顶层目录就加一行 `+ /目录名/**`。**改完在 `nas/` 里 `docker compose up -d --build`**（白名单 baked 进镜像，且在 NAS 端就生效）。
- **附件/图片**：记得把图片所在目录也加进白名单，否则站上图全裂。
- **单篇排除**：Quartz v5 默认启用 `remove-draft` 插件——给某篇 frontmatter 加 `draft: true` 即可不发布。
  - 想反过来「默认不发、只发标记过的」：进容器执行 `npx quartz plugin enable explicit-publish` 并 `disable remove-draft`（或编辑镜像里的 `quartz.config.yaml`），只发 `publish: true` 的笔记——但那样**没标记的一律不出现**，需逐篇打标。
- **插件/配置**：v5 配置是 `quartz.config.yaml`，插件用 `npx quartz plugin enable/disable <名>` 开关。改动后需重建镜像才会固化（`docker compose up -d --build`）。`og-image`（社交预览图）默认关闭，因为它构建时要联网下载字体；如需开启请确保构建机能联外网。

## 嵌入：SVG 图与 HTML 动画

Quartz v5 的 `obsidian-flavored-markdown` 插件对这两类嵌入有坑，`nas/builder/patch-ofm.js` 已在镜像构建时修补：

- **`![[图.svg]]`**：插件原本渲染成 `<object data="裸文件名">`，路径不被解析 → 404 空白。patch 把 `.svg` 并入栅格图列表，改走 `<img>`，由 `crawl-links` 正确解析相对路径。
- **`![[动画.html]]`**：插件原本直接丢弃。patch 改成渲染 `<iframe>`（`crawl-links` 同样会解析 iframe 的 src），动画内联显示。默认 `width:100%; min-height:480px`，可用 `![[动画.html|800x600]]` 指定尺寸。
- nginx 配了 `default_type text/html`：Quartz 把 html 动画当静态资源拷贝时会去掉扩展名，无扩展名文件按 HTML 渲染，避免 iframe 里变成下载。

## 数学公式：行内 vs 行间

Obsidian 把**任意** `$$..$$` 当行间（display）公式；但 Quartz 的 `remark-math` 只把「`$$` 围栏独占整行」的当 display，**单行 / 贴着文字的 `$$..$$` 会被当行内** → `\begin{align}`、`\tag` 这类只能用于 display 的命令直接报错。

`patch-ofm.js` 在 `textTransform` 里加了一段预处理（跳过代码块）：把 `$$..$$` 规范成块级（围栏独占行、前后空行），于是 remark-math 正确识别为 display。行内 `$..$` 不受影响。带内部 `$` 的合法块级（如 `\tag{$\star$}`）按「内部 `$` 个数为偶」识别保留。

**callout 感知**：直接插入裸行会把 Obsidian callout（`>` 引用块）截断成正文。所以预处理对 callout 区域**先脱去一层 `>`、规范化、再逐行加回 `>`**，公式作为 display 留在框内、后续文字也不掉出框。

**已知残留**：相邻且**不带空格**的两个行内公式 `$a$$b$`（如 `…$\implies$$f(x)$…`）会被 remark-math 误当分隔符报错——这是 Quartz 解析器比 Obsidian 严格之处，自动修复风险高（容易误伤真正的 `$$..$$`），故未做。**改法：中间加个空格** `$a$ $b$`。

> 以上都是对插件 `dist/` 的就地 patch；若将来 `quartz plugin install` 升级了该插件，patch 自检失配会让构建失败提醒你。

## 为什么构建放 NAS（小内存云机的由来）

最初把构建也放在公网云机（整机 1.6 GiB / 2 核，还同时跑 alist、mihomo、宝塔等），结果**开机所有容器同时启动 + 每次启动跑一遍 Node 构建**会瞬间吃光内存、触发 swap 狂抖、整机卡死；229 个文件的 build 在 768m 直接被 OOM `Killed`。这才把构建整体搬到 NAS。现在云机只剩 rclone + nginx，**根本不可能再因构建 OOM**。

云机侧仍保留两道温柔阀门（见 `puller/entrypoint-pull.sh`）：
- **宿主机负载闸门**（`LOAD_MAX`，默认 1.5）：读 `/proc/loadavg`（容器里反映宿主机全局负载），偏高就退避，空闲才拉。
- **`ionice -c3` + `nice -n19` + `--bwlimit`**：拉取走空闲 IO 类、最低 CPU 优先级、限带宽，尽量不打扰宿主机其它服务。
- puller 容器 `mem_limit: 256m`、`cpus: "0.5"`，纯静态同步绰绰有余。

NAS builder 侧（内存足）保留了**内容指纹跳过构建**（产物目录里的 `.content.fingerprint`）：笔记没变就跳过重量级 build；`BUILD_CONCURRENCY` 留空=按核数跑满最快，NAS 也偏小时可设 `1` 并给 builder 加 `mem_limit`。

> ionice 的空闲类在云 VM 上效果取决于磁盘调度器（`mq-deadline`/`none` 下只部分生效），但 `nice` + `--bwlimit` + 低并发依然有效；且产物是纯静态小文件，拉取本就很轻。

## 注意：桶里的脏数据

Remotely Save 不传播删除/重命名，桶里可能有冲突副本（`xxx 1.md`）和你早删了的残留——Quartz 会把它们也编译成页面。两种处理：

- **治本**：定期用 `rclone sync 本地库 → 桶 --delete` 把桶做成干净镜像；
- **治标**：在 `filter-public.txt` 里加排除规则，例如 `- /**/* [0-9].md`（按你副本实际命名调整）。

## 目录结构

两个目录各自自包含，可分别打包推送：

```
notes-site/
├── README.md                    # 总览（本文件）
├── .gitignore                   # 顶层（.env 在任意层级都被忽略）
│
├── nas/                         # ▶ 整箱推到 NAS（负责构建）
│   ├── docker-compose.yml       #   builder 服务
│   ├── builder/
│   │   ├── Dockerfile           #   node22 + rclone + Quartz v5（插件 baked 进镜像）
│   │   ├── entrypoint.sh        #   同步→（指纹比对）构建→产物写入 /site→休眠 循环
│   │   └── patch-ofm.js         #   修补 ofm 插件的 svg/html 嵌入 + 行间公式（见上文）
│   ├── filter-public.txt        #   rclone 白名单（NAS 端构建时生效）
│   ├── .env / .env.example      #   NAS 凭据 + 站点 + 构建参数
│   └── .dockerignore
│
└── cloud/                       # ▶ 整箱推到云机（负责拉取+伺服）
    ├── docker-compose.yml       #   puller + web
    ├── puller/
    │   ├── Dockerfile           #   alpine + rclone + util-linux（ionice，极轻）
    │   └── entrypoint-pull.sh   #   宿主机空闲时 ionice+nice+bwlimit 拉产物→site 卷→循环
    ├── web/nginx.conf           #   干净链接 try_files + 相对跳转 + default_type + 真 404
    ├── .env / .env.example      #   NAS 凭据 + SITE_REMOTE + 拉取错峰参数
    └── .dockerignore
```

打包推送示例：`scp -r nas/ user@nas:/opt/notes-build/`、`scp -r cloud/ user@云机:/opt/obsidiannote/`（`.env` 含密钥，按需单独安全传输）。
