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

## 构建流程：触发与时序

**触发模型：定时轮询，不是事件驱动。** 没有 webhook / inotify，两端各跑一个 `while true` 循环，靠"睡 N 秒 → 干活 → 再睡"推进。容器都设了 `restart: unless-stopped`，**开机/重启自动起循环**。改一篇笔记到它出现在公网站上，是若干个"下一轮"叠加出来的延迟，不是实时的。

### ① NAS builder 一轮（`nas/builder/entrypoint.sh`）

容器启动先睡 `STARTUP_DELAY`（默认 **20s**，开机错峰让位给同时启动的其它容器），随后循环：

1. **拉白名单笔记**：`rclone sync NAS:obsidian → /quartz/content --filter-from filter-public.txt --delete-excluded`（`--transfers 4 --checkers 8`）。失败（NAS 不可达）则沿用已有内容，不中断。
2. **指纹比对（决定要不要构建）**：对 `content` 下所有文件的「相对路径+大小+mtime」算 md5 → `NEW_FP`，与 `/site/.content.fingerprint` 里的 `OLD_FP` 比。
   - **相同**且 `/site/index.html` 已存在 → **`[skip]` 跳过构建**（省内存，避免开机/重启卡死的关键）。
   - **不同** → 写站点首页 `index.md` → `npx quartz build`（`BUILD_CONCURRENCY` 留空=按核数跑满）→ `rclone sync /quartz/public → /site` → 把 `NEW_FP` 写回指纹文件。
   - 构建失败（如 OOM）则保留 `/site` 上一版，不会发半成品。
3. **休眠 `SYNC_INTERVAL`（默认 600s = 10 分钟）**，回到第 1 步。

> 即：**最多每 10 分钟才检查一次笔记是否有变**；有变才构建，无变只花一次 rclone 比对的钱。

### ② 云机 puller 一轮（`cloud/puller/entrypoint-pull.sh`）

与 builder **完全异步**，各睡各的。每轮：

1. **负载闸门 `idle_wait`**：读 `/proc/loadavg` 的 1 分钟负载。若 `load1 > LOAD_MAX`（默认 **1.5**）就退避 `IDLE_WAIT`（默认 **30s**）再看；连续退避满 `IDLE_MAX_TRIES`（默认 **20** 次，即最多等 `20×30s=600s`）后**强制拉一次**，防止永远等不到空闲。
2. **温柔拉取**：`ionice -c3 nice -n19 rclone sync NAS:site → /site --bwlimit 2M --transfers 1 --checkers 2`。失败则沿用本地副本（站点不受 NAS 抖动影响）。
3. **休眠 `PULL_INTERVAL`（默认 300s = 5 分钟）**，回到第 1 步。

### ③ 端到端时延（改一篇笔记 → 公网可见）

| 阶段 | 取决于 | 典型 | 最坏 |
|---|---|---|---|
| Obsidian → NAS 桶 | Remotely Save 的同步设置（手动/定时） | 数秒~分钟 | 看你插件 |
| builder 下一轮拉到改动 | `0 ~ SYNC_INTERVAL` | ~5 min | 10 min |
| Quartz 构建 | 笔记规模（指纹变才构建） | 数十秒~数分钟 | — |
| puller 下一轮拉到产物 | `0 ~ PULL_INTERVAL`，宿主机忙时再加退避 | ~2.5 min | 5 min + 退避最多 10 min |
| 拉取传输 | 产物大小、`BWLIMIT` | 数秒 | — |

**合计：通常 ~5–15 分钟可见；云机长期繁忙的最坏情况再叠加最多 ~10 分钟退避。** 这是"错峰省资源"换来的代价——要更快就调小 `SYNC_INTERVAL`/`PULL_INTERVAL`、调高 `LOAD_MAX`。

### 想立刻发布 / 强制重建

- **一键发布（推荐）**：本地 PC 双击 `publish.bat` —— 推送笔记→触发 NAS 构建一次→触发云机拉取一次，**顺序阻塞、按一下走完**，不必等轮询。原理见下文「一键脚本」。
- **手动在远端跑一轮**：`docker compose restart builder`（云机同理 `restart puller`）。但**指纹没变仍会 `[skip]`**。
- **强制构建一次（不靠 restart）**：两个 entrypoint 都支持 `once` 模式 —— `docker compose exec -T builder /entrypoint.sh once`（强制构建、跳过指纹）、`docker compose exec -T puller /entrypoint.sh once`（立即拉取、跳过负载闸门）。`publish.bat` 就是远程触发这两个。
- **改了白名单 / patch / Dockerfile**：要重建镜像 —— 本地 PC 双击 `deploy.bat`（本地 build→传镜像→远端换），或在远端 `docker compose up -d --build`。
- **内容没变也要强制重建产物**：删掉指纹即可下一轮重建 —— `rm /srv/notes-site/public/.content.fingerprint`（或删 `/site/index.html`）。

## 前置条件

1. **两台机器都在 tailnet 上**（`tailscale up`）：NAS builder 要连 AList 拉笔记，云机 puller 要连 NAS 拉产物。
2. NAS 与云机都装了 Docker / Docker Compose。**NAS 上镜像构建需能访问 GitHub**（预装 Quartz v5 插件）和 npm（走 npmmirror）；云机镜像只需 Docker Hub（alpine + rclone）。
3. NAS 上把构建产物目录（`/srv/notes-site/public`）在 **AList 里加成一个存储**，使云机能用 `SITE_REMOTE=NAS:site` 读到（路径/桶名按你的 AList 配置，与 `.env` 对应）。

## 部署

仓库分成两个**各自自包含、可独立打包推送**的目录：`nas/` 推到 NAS，`cloud/` 推到云机。各自 `cp .env.example .env` 填好后，在该目录里 `docker compose up -d --build` 即可。

> **首次部署**用下面的「在远端 build」流程把 `.env`、`docker-compose.yml` 等放到位、跑通一次。**之后更新镜像**（改了 entrypoint/白名单/patch）改用本地构建：PC 上双击 `deploy.bat`（见「一键脚本」），免在 NAS 上 git pull / `--build`。

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

## 一键脚本（本地 PC 运维）

仓库根目录有三个面向**本地 Windows PC** 的脚本（`.bat` 双击即用，`.ps1` 是实际逻辑）。它们把「改 → 构建 → 上线」从「等轮询」变成「按一下、顺序跑完」：

| 脚本 | 干什么 | 何时用 |
|---|---|---|
| `deploy.bat` | 本地 `docker build` 两个镜像 → `docker save` → scp 到远端 `/tmp` → `docker load` → `up -d` → 验证 | 改了 entrypoint / 白名单 / patch / Dockerfile（偶尔） |
| `publish.bat` | 本地→桶强制推（含删除）→ SSH 触发 NAS 构建一次 → SSH 触发云机拉取一次（顺序阻塞） | 改完笔记要立刻上线（日常） |
| `reconcile.bat` | 本地→桶镜像同步（带删除），清掉 Remotely Save 没传播的孤儿；先 dry-run 列清单、输 `yes` 才执行 | 重构/改名/删笔记后（按需） |

**为什么用 `deploy.bat` 在本地构建**：NAS 上 git pull 不便，所以镜像在 PC 上 build 好、`docker save` 成 tar 传过去 `docker load`。tar 落到远端 `/tmp`（可写），`up -d` 只**读** `/opt` 下的 compose/.env，**不需要 chown / sudo / git pull**。`load` 覆盖同名 tag 后，`up -d` 检测到镜像变了会自动重建容器。`deploy.bat -NasOnly` / `-CloudOnly` 可只部署一台。

**为什么 `publish.bat` 能「顺序」**：两个 entrypoint 都加了 `once` 模式（`/entrypoint.sh once` = 强制跑一遍就退出，不进轮询循环）。`publish.ps1` 用 `ssh … docker compose exec -T <svc> /entrypoint.sh once` 触发，**SSH 阻塞到远端那次跑完才返回**，于是「推送 → 构建 → 拉取」天然串行。两端原有轮询循环**保留作兜底**（脚本不跑时仍按 `SYNC_INTERVAL`/`PULL_INTERVAL` 自动更新）。`publish.bat -Preview` 只对推送那步做 dry-run、不触发两端。

**前置**：本机装 Docker（`linux/amd64`，与 NAS/云机架构一致）、在 tailnet 上、能 ssh 到两机。脚本里**不存密码**——首次给云机配免密：`ssh-copy-id kylaan@<云机>`（NAS 已有密钥）。各脚本顶部 `配置` 区有库路径、SSH 目标、远端目录，换机器改那几行即可。

> 闭环：**改 entrypoint/白名单/patch → `deploy.bat`**（换镜像，偶尔）；**改完笔记 → `publish.bat`**（推送+构建+拉取，经常）；**重构动了目录 → 先 `reconcile.bat` 清孤儿**（或直接 `publish.bat`，它含同样的推送）。

## 发布哪些内容

- **选择目录**：编辑 `nas/filter-public.txt`（白名单，路径相对桶根）。新增一个公开顶层目录就加一行 `+ /目录名/**`。**改完用 `deploy.bat` 重建镜像**（白名单 baked 进镜像，且在 NAS 端就生效）。
- **附件/图片**：记得把图片所在目录也加进白名单，否则站上图全裂。
- **大文件**：>15 MiB 的文件（视频/大 PDF）默认**不发布**——`reconcile`/`publish` 推送时 `--max-size 15M` 不上传，builder 构建时也 `--max-size 15M` 不拉取（两处都加了，桶里漏了也不会上站）。要改阈值改这两处的 `--max-size`。
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

Remotely Save 不传播删除/重命名，桶里可能有冲突副本（`xxx 1.md`）、改名/移动后的旧路径、和你早删了的残留——Quartz 会把它们也编译成幽灵页面。过滤规则只能挡有特征的副本（`xxx 1.md`），**挡不住改名/重构留下的旧路径**（名字完全正常），只能让桶变成本地库的镜像。两种处理：

- **治本（推荐）**：本地 PC 双击 **`reconcile.bat`** —— 以本地库为准 `rclone sync 本地 → 桶`（带删除），把桶做成干净镜像。带 `--size-only`（不被 mtime 抖动误传）、`--max-size 15M`（忽略大文件）、`--exclude .obsidian/**`（护住 Remotely Save 自己的元数据，避免两工具打架）；先 dry-run 列出「将删/将传」、输 `yes` 才执行。`publish.bat` 也含同样的推送。
  - **多设备注意**：这是单向 `本地 → 桶` 且会删——若你也在手机等其它设备改笔记，先把那边的改动同步回本机再跑，否则 `--delete` 会抹掉「别处改了还没到本地」的内容。
- **治标**：在 `filter-public.txt` 里加排除规则，例如 `- /**/* [0-9].md`（按你副本实际命名调整）——只能挡冲突副本。

## 目录结构

两个目录各自自包含，可分别打包推送：

```
notes-site/
├── README.md                    # 总览（本文件）
├── .gitignore                   # 顶层（.env 在任意层级都被忽略）
│
├── deploy.ps1 / deploy.bat      # ★本地 build 镜像→save→scp→远端 load→up -d→验证
├── publish.ps1 / publish.bat    # ★一键发布：推送→NAS 构建一次→云机拉取一次（顺序阻塞）
├── reconcile.ps1 / reconcile.bat# ★本地→桶镜像同步（带删除），清孤儿（dry-run 后确认）
│
├── nas/                         # ▶ 整箱推到 NAS（负责构建）
│   ├── docker-compose.yml       #   builder 服务
│   ├── builder/
│   │   ├── Dockerfile           #   node22 + rclone + Quartz v5（插件 baked 进镜像）
│   │   ├── entrypoint.sh        #   one_pass：同步(--max-size 15M)→指纹比对→构建→/site
│   │   │                        #   支持 `once`（强制构建一次）；默认轮询循环
│   │   └── patch-ofm.js         #   修补 ofm 插件的 svg/html 嵌入 + 行间公式（见上文）
│   ├── filter-public.txt        #   rclone 白名单（NAS 端构建时生效）
│   ├── .env / .env.example      #   NAS 凭据 + 站点 + 构建参数
│   └── .dockerignore
│
└── cloud/                       # ▶ 整箱推到云机（负责拉取+伺服）
    ├── docker-compose.yml       #   puller + web
    ├── puller/
    │   ├── Dockerfile           #   alpine + rclone + util-linux（ionice，极轻）
    │   └── entrypoint-pull.sh   #   pull_once：负载闸门→拉产物→site 卷；支持 `once`
    │                            #   （立即拉、跳过闸门）；默认轮询循环
    ├── web/nginx.conf           #   干净链接 try_files + 相对跳转 + default_type + 真 404
    ├── .env / .env.example      #   NAS 凭据 + SITE_REMOTE + 拉取错峰参数
    └── .dockerignore
```

镜像部署走本地构建（`deploy.bat`），无需在远端 git pull / `--build`。`.env` 含密钥不要提交，按需单独安全传输。
