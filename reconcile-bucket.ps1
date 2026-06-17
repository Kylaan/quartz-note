# ============================================================
# reconcile-bucket.ps1
# 把 S3 桶对齐成「本地库的精确镜像」：删掉 Remotely Save 没传播的
# 孤儿文件（重构/改名/删除后留在桶里的旧路径），让 Quartz 不再编译
# 出幽灵页面。本地库 = 唯一真相，单向 本地 → 桶（带删除）。
#
# 安全设计：每次先 DRY-RUN 列出【将删除/将上传】明细，输入 yes 才真执行。
# 用法：双击同目录的 reconcile.bat；或在 PowerShell 里直接运行本文件。
#
# 注意：
#  1) 本机必须在 tailnet 上（tailscale up），桶 endpoint 是 100.68.43.37。
#  2) 若你也在手机/其它设备改笔记，先把那些改动同步回本机再跑——
#     否则 --delete 会把「别处改了但还没到本地」的内容从桶里删掉。
#  3) --size-only：只按大小判断是否上传，避免 mtime 抖动导致整库重传、
#     也避免惊动 Remotely Save 反向重下。正常内容更新仍交给 Remotely Save。
#  4) --max-size 15M：忽略 >15MiB 的大文件（视频/大 PDF 等）——既不上传新的，
#     也不会去删桶里已有的大文件（被 size 过滤掉，rclone 根本不看它）。
# ============================================================

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------- 配置（按需修改）----------
$VaultRoot   = 'D:\NOTE-OB\LEARNING'                 # 本地库根（= 桶顶层映射处）
$Remote      = 'NAS:obsidian'                        # rclone 远端:桶
$EnvFile     = Join-Path $PSScriptRoot 'nas\.env'    # 复用 NAS 侧凭据（RCLONE_CONFIG_NAS_*）
$Excludes    = @('--exclude', '.obsidian/**', '--exclude', '.trash/**')  # 护住 RS 元数据/回收站
$CommonFlags = @('--size-only', '--max-size', '15M', '--track-renames', '--fast-list', '-v')

function Section($t){ Write-Host "`n========== $t ==========" -ForegroundColor Cyan }

Section '桶对齐 reconcile（本地 → 桶，带删除）'
Write-Host "本地库 : $VaultRoot"
Write-Host "远端桶 : $Remote"

# ---------- 1) 注入 rclone 凭据 ----------
if (-not (Test-Path $EnvFile)) { throw "找不到凭据文件：$EnvFile" }
Get-Content $EnvFile | Where-Object { $_ -match '^RCLONE_CONFIG_NAS_' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    Set-Item "env:$k" $v
}
Write-Host '[ok] 已从 nas\.env 载入 NAS 凭据' -ForegroundColor Green

# ---------- 2) 本地库存在性 ----------
if (-not (Test-Path $VaultRoot)) { throw "本地库不存在：$VaultRoot" }

# ---------- 3) 连通性（tailnet）----------
Write-Host "`n[..] 检查 NAS 连通性（需在 tailnet 上）..." -ForegroundColor Yellow
rclone lsd $Remote --max-depth 1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "连不上 $Remote —— 确认本机已 tailscale up、NAS/AList 在线。" }
Write-Host '[ok] NAS 可达' -ForegroundColor Green

# ---------- 4) DRY-RUN 预览 ----------
Section 'DRY-RUN 预览（不改动任何文件，请核对下面清单）'
rclone sync $VaultRoot $Remote @Excludes @CommonFlags --dry-run
Write-Host "`n图例：'Skipped delete' = 将删除的孤儿 ；'Skipped copy' = 将上传覆盖的文件" -ForegroundColor DarkGray
Write-Host "Deleted = 桶有本地无（重构/改名残留）；Transferred = 大小不一致，以本地为准" -ForegroundColor DarkGray

# ---------- 5) 二次确认 ----------
$ans = Read-Host "`n确认按上面预览真正执行？输入 yes 继续（其它任意键取消）"
if ($ans -ne 'yes') { Write-Host '已取消，桶未改动。' -ForegroundColor Yellow; exit 0 }

# ---------- 6) 正式执行 ----------
Section '正式执行'
rclone sync $VaultRoot $Remote @Excludes @CommonFlags --stats 2s --stats-one-line
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[ok] 桶已对齐为本地镜像，孤儿已清除。" -ForegroundColor Green
    Write-Host 'NAS builder 下一轮（<= SYNC_INTERVAL 秒）会重建，幽灵页面随之消失。' -ForegroundColor Green
} else {
    Write-Host "`n[err] rclone 退出码 $LASTEXITCODE，桶可能未完全对齐，请检查上面日志。" -ForegroundColor Red
}
