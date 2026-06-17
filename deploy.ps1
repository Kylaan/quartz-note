# ============================================================
# deploy.ps1 — 本地构建镜像并部署到远端（NAS 不用 git pull / 不在远端 build）：
#   本地 docker build → docker save 成 tar → scp 过去 → 远端 docker load → up -d → 验证
# 镜像已 baked entrypoint/白名单/patch，远端只需换镜像重启。
#
# 用法：双击 deploy.bat；或  powershell -File deploy.ps1 [-NasOnly] [-CloudOnly]
#   默认两台都部署；-NasOnly 只部署 NAS builder；-CloudOnly 只部署云机 puller。
#
# 前置：本机装了 Docker（linux/amd64）；能 ssh 到 homeserver 和云机。
# ============================================================
param([switch]$NasOnly, [switch]$CloudOnly)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Set-Location $PSScriptRoot   # 让 docker build 的相对路径（nas/、cloud/）成立

# ---------- 配置 ----------
$NasSsh   = 'homeserver';            $NasDir   = '/opt/docker-field/quartz-note'
$CloudSsh = 'kylaan@39.106.101.5';   $CloudDir = '/opt/obsidiannote'

function Section($t) { Write-Host "`n========== $t ==========" -ForegroundColor Cyan }

# 远端执行 compose 子命令：自动适配 docker compose(v2) 或 docker-compose(v1)
function Invoke-RemoteCompose($sshTarget, $dir, $composeArgs) {
    ssh $sshTarget "cd '$dir' && if docker compose version >/dev/null 2>&1; then docker compose $composeArgs; else docker-compose $composeArgs; fi"
}

# 通用：本地 build → save → scp → 远端 load+up -d → 验证关键字在镜像里
function Deploy-One($name, $image, $dockerfile, $context, $sshTarget, $remoteDir, $service, $verifyToken) {
    $tar = Join-Path $env:TEMP "$image.tar"
    try {
        Section "$name：本地构建镜像 $image"
        docker build -t "${image}:latest" -f $dockerfile $context
        if ($LASTEXITCODE -ne 0) { throw "$name docker build 失败（退出码 $LASTEXITCODE）" }

        Section "$name：导出 tar 并传到 $sshTarget"
        docker save "${image}:latest" -o $tar
        if ($LASTEXITCODE -ne 0) { throw "$name docker save 失败" }
        $sizeMB = [math]::Round((Get-Item $tar).Length / 1MB)
        Write-Host "tar 大小 ${sizeMB} MiB，scp 上传中..." -ForegroundColor DarkGray
        scp $tar "${sshTarget}:/tmp/$image.tar"
        if ($LASTEXITCODE -ne 0) { throw "$name scp 失败（退出码 $LASTEXITCODE）" }

        Section "$name：远端 load + 重启"
        ssh $sshTarget "docker load -i /tmp/$image.tar"
        if ($LASTEXITCODE -ne 0) { throw "$name 远端 docker load 失败（退出码 $LASTEXITCODE）" }
        Invoke-RemoteCompose $sshTarget $remoteDir 'up -d'
        if ($LASTEXITCODE -ne 0) { throw "$name 远端 up -d 失败（退出码 $LASTEXITCODE）" }
        ssh $sshTarget "rm -f /tmp/$image.tar"

        # 验证容器里确实是新代码（ASCII 关键字，避免中文经 ssh 编码出错）
        Invoke-RemoteCompose $sshTarget $remoteDir "exec -T $service grep -q $verifyToken /entrypoint.sh"
        if ($LASTEXITCODE -eq 0) { Write-Host "[verify] NEW（含 $verifyToken）" -ForegroundColor Green }
        else { Write-Host "[verify] OLD —— 未更新成功，检查上面日志！" -ForegroundColor Red }
        Write-Host "[ok] $name 部署完成" -ForegroundColor Green
    }
    finally {
        if (Test-Path $tar) { Remove-Item $tar -Force }
    }
}

if (-not $CloudOnly) {
    Deploy-One 'NAS builder' 'notes-builder' 'nas/builder/Dockerfile' 'nas' `
               $NasSsh $NasDir 'builder' 'one_pass'
}
if (-not $NasOnly) {
    Deploy-One '云机 puller' 'notes-puller' 'cloud/puller/Dockerfile' 'cloud' `
               $CloudSsh $CloudDir 'puller' 'pull_once'
}

Section '全部完成 ✅'
Write-Host '两台都显示 [verify] NEW 即成功。之后用 publish.bat 一键发布。' -ForegroundColor Green
