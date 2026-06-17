# ============================================================
# publish.ps1 — 一键发布（顺序阻塞执行，按一下走完整条链）：
#   ① 本地库 → 桶（强制推送，含删除、忽略 >15MiB）
#   ② SSH NAS：docker compose exec builder /entrypoint.sh once   —— 阻塞至「构建完成」
#   ③ SSH 云机：docker compose exec puller  /entrypoint.sh once  —— 阻塞至「拉取完成」
# 每一步都等上一步真正结束才进行，天然顺序。两端原有轮询循环保留作兜底。
#
# 用法：双击 publish.bat；或  powershell -File publish.ps1 [-Preview]
#   -Preview：只对「本地→桶」做 dry-run 预览，不真推、不触发两端。
#
# 前置：
#   * 本机在 tailnet 上；能 ssh 到 NAS（homeserver，已配密钥）和云机。
#   * 云机建议先配 SSH 密钥免密（见 README/对话），否则会交互式要密码。
#   * 两端镜像已含 once 模式（改完 entrypoint 后各自 docker compose up -d --build）。
# ============================================================
param([switch]$Preview)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------- 配置 ----------
$VaultRoot = 'D:\NOTE-OB\LEARNING'                  # 本地库根
$Remote    = 'NAS:obsidian'                         # rclone 远端:桶
$EnvFile   = Join-Path $PSScriptRoot 'nas\.env'     # 复用 NAS 凭据
$Excludes  = @('--exclude', '.obsidian/**', '--exclude', '.trash/**')
$Flags     = @('--size-only', '--max-size', '15M', '--track-renames', '--fast-list', '-v')

# SSH 目标（用户:主机 + 远端整箱目录）
$NasSsh   = 'homeserver';            $NasDir   = '/opt/docker-field/quartz-note'
$CloudSsh = 'kylaan@39.106.101.5';   $CloudDir = '/opt/obsidiannote'

function Section($t) { Write-Host "`n========== $t ==========" -ForegroundColor Cyan }

# 远端执行 compose 子命令：自动适配 docker compose(v2) 或 docker-compose(v1)
function Invoke-RemoteCompose($sshTarget, $dir, $composeArgs) {
    ssh $sshTarget "cd '$dir' && if docker compose version >/dev/null 2>&1; then docker compose $composeArgs; else docker-compose $composeArgs; fi"
}

# ---------- 载入 rclone 凭据 ----------
if (-not (Test-Path $EnvFile)) { throw "找不到凭据文件：$EnvFile" }
Get-Content $EnvFile | Where-Object { $_ -match '^RCLONE_CONFIG_NAS_' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    Set-Item "env:$k" $v
}

# ---------- ① 本地 → 桶（强制推送） ----------
Section '① 推送笔记到桶（本地 → 桶，含删除，忽略 >15MiB）'
$dry = @(); if ($Preview) { $dry = @('--dry-run') }
rclone sync $VaultRoot $Remote @Excludes @Flags @dry
if ($LASTEXITCODE -ne 0) { throw "推送失败（rclone 退出码 $LASTEXITCODE）" }
if ($Preview) {
    Write-Host "`n[preview] 仅预览推送，未触发构建/拉取。去掉 -Preview 正式发布。" -ForegroundColor Yellow
    exit 0
}

# ---------- ② NAS 构建一次（阻塞） ----------
Section '② NAS 构建一次（SSH 阻塞至完成）'
Invoke-RemoteCompose $NasSsh $NasDir 'exec -T builder /entrypoint.sh once'
if ($LASTEXITCODE -ne 0) { throw "NAS 构建失败（ssh/exec 退出码 $LASTEXITCODE）" }

# ---------- ③ 云机拉取一次（阻塞） ----------
Section '③ 云机拉取一次（SSH 阻塞至完成）'
Invoke-RemoteCompose $CloudSsh $CloudDir 'exec -T puller /entrypoint.sh once'
if ($LASTEXITCODE -ne 0) { throw "云机拉取失败（ssh/exec 退出码 $LASTEXITCODE）" }

# ---------- 完成 ----------
Section '发布完成 ✅'
$base = ((Get-Content $EnvFile) -match '^BASE_URL=' | Select-Object -First 1) -replace '^BASE_URL=', ''
if ($base) { Write-Host "站点：https://$base" -ForegroundColor Green }
