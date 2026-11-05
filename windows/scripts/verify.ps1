# AITrans Windows 自动化验收脚本
#
# 用法（在仓库根目录或任意位置）：
#   powershell -ExecutionPolicy Bypass -File windows\scripts\verify.ps1
#   powershell -ExecutionPolicy Bypass -File windows\scripts\verify.ps1 -Publish
#
# 退出码：0 全部通过；非 0 表示有失败步骤。

[CmdletBinding()]
param(
    [switch]$Publish,
    [switch]$NoRestore
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $scriptDir "..\..")
$tests = Join-Path $root "windows\AITrans.Core.Tests\AITrans.Core.Tests.csproj"
$app = Join-Path $root "windows\AITrans.App\AITrans.App.csproj"
$results = @()
$failed = $false

function Write-Section($title) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkGray
    Write-Host $title -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkGray
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Section $Name
    try {
        & $Action
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
            throw "命令返回 $LASTEXITCODE"
        }
        $script:results += [pscustomobject]@{ Step = $Name; Result = "PASS" }
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    catch {
        $script:results += [pscustomobject]@{ Step = $Name; Result = "FAIL" }
        $script:failed = $true
        Write-Host "FAIL: $Name -> $_" -ForegroundColor Red
    }
}

Write-Host "AITrans Windows 自动化验收" -ForegroundColor White
Write-Host "仓库：$root"

Invoke-Step "环境检查：dotnet SDK" {
    dotnet --version
    $version = (dotnet --version).Trim()
    $major = [int]($version.Split('.')[0])
    if ($major -lt 10) {
        throw "需要 .NET 10 SDK，当前 $version"
    }
}

Invoke-Step "单元测试（fixtures / 解析 / 输出 / 重试 / 取消 / 存储）" {
    $restore = if ($NoRestore) { "--no-restore" } else { "" }
    dotnet test $tests -c Release $restore --logger "console;verbosity=normal"
}

Invoke-Step "构建 WinUI 客户端" {
    dotnet build $app -c Release -p:Platform=x64
}

if ($Publish) {
    Invoke-Step "发布自包含包并校验产物" {
        $dist = Join-Path $root "windows\dist\app"
        if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
        dotnet publish $app -c Release -r win-x64 --self-contained true `
            -p:Version=0.0.0-verify -o $dist
        $exe = Join-Path $dist "AITrans.exe"
        if (-not (Test-Path $exe)) { throw "缺少 $exe" }
        Write-Host "产物：$exe"
        Get-ChildItem $dist -Filter "*.dll" | Measure-Object | ForEach-Object {
            Write-Host "附带 DLL 数量：$($_.Count)"
        }
    }
}

Write-Section "汇总"
$results | Format-Table -AutoSize | Out-String | Write-Host

if ($failed) {
    Write-Host "存在失败步骤，请把上面的输出完整贴回。" -ForegroundColor Red
    exit 1
}

Write-Host "自动化部分全部通过。" -ForegroundColor Green
Write-Host "仍需人工确认的项目见 docs/verification-windows.md 第三节。" -ForegroundColor Yellow
exit 0
