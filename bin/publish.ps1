#Requires -Version 5.1
<#
  publish.ps1  --  開発リポジトリの配布物を、社内の配布原本の場所へ置く

  使い方:
    .\bin\publish.ps1 -Dest "Z:\AI-DESK\_配布"
    .\bin\publish.ps1 -Dest "Z:\AI-DESK\_配布" -WhatIf   # 何が置かれるか見るだけ

  -Dest の下に AI-DESK\ を作ります（既にあれば、確認のうえ上書きします）。
  .git は絶対にコピーしません。ファイルの削除も一切行いません。

  ※ このスクリプトは人が実行します。書き込み先が共有フォルダになるためです。

  終了コード: 0=成功または中止 / 1=異常（メッセージを読んでください）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Dest,                      # 配布原本の置き場所（この下に AI-DESK\ を作ります）

    [string]$Source,                    # 配布物。既定は、このスクリプトの隣の AI-DESK\

    [switch]$WhatIf                     # 置かれる内容を表示するだけで、何も書き換えない
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[publish] $Message" }

function Get-DistributionFile {
    # 配布物のファイル一覧。.git は必ず除く。
    param([string]$Root)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
        Where-Object { $_.FullName.Split($sep) -notcontains '.git' }
}

function Get-RelativePath {
    param([string]$Root, [string]$FullName)
    $rest = $FullName.Substring($Root.Length)
    return $rest.TrimStart([System.IO.Path]::DirectorySeparatorChar,
                           [System.IO.Path]::AltDirectorySeparatorChar)
}

# --- 1. 配布物を決める -------------------------------------------------------

if (-not $Source) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $Source = Join-Path $repoRoot 'AI-DESK'
}

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Warning "配布物が見つかりません: $Source"
    exit 1
}
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath

$sourceVersionFile = Join-Path (Join-Path $Source '.ai-desk') 'VERSION'
if (-not (Test-Path -LiteralPath $sourceVersionFile)) {
    Write-Warning "配布物ではありません（.ai-desk\VERSION が見つかりません）: $Source"
    exit 1
}
$version = (Get-Content -LiteralPath $sourceVersionFile -Raw -Encoding UTF8).Trim()

$gitDirs = @(Get-ChildItem -LiteralPath $Source -Recurse -Force -Directory -Filter '.git' -ErrorAction SilentlyContinue)
if ($gitDirs.Count -gt 0) {
    Write-Warning "配布物に .git が含まれています。中止します。"
    Write-Warning "配布原本に .git を持ち込むと、そこからコピーされるインスタンス全部に付いて回ります。"
    foreach ($d in $gitDirs) { Write-Warning ("  " + $d.FullName) }
    exit 1
}

# --- 2. 置き場所を決める -----------------------------------------------------

if (-not (Test-Path -LiteralPath $Dest)) {
    Write-Warning "置き場所が見つかりません: $Dest"
    Write-Warning "フォルダを先に作るか、パスの打ち間違いがないか確かめてください。"
    exit 1
}
$Dest = (Resolve-Path -LiteralPath $Dest).ProviderPath
$target = Join-Path $Dest 'AI-DESK'

$files = @(Get-DistributionFile -Root $Source)

Write-Step "配布物: $Source （版 $version）"
Write-Step "置き先: $target"
Write-Step ("ファイル数: " + $files.Count + " 個")

$targetExists = Test-Path -LiteralPath $target

# --- 3. 既にある原本との違いを見せる -----------------------------------------

if ($targetExists) {
    $oldVersionFile = Join-Path (Join-Path $target '.ai-desk') 'VERSION'
    $oldVersion = '(不明)'
    if (Test-Path -LiteralPath $oldVersionFile) {
        $oldVersion = (Get-Content -LiteralPath $oldVersionFile -Raw -Encoding UTF8).Trim()
    }
    Write-Step "既に原本があります（版 $oldVersion）。上書きすることになります。"

    # 配布物から消えたファイルが原本に残っていないか（消さずに知らせるだけ）
    $sourceRelatives = @()
    foreach ($file in $files) {
        $sourceRelatives += (Get-RelativePath -Root $Source -FullName $file.FullName)
    }
    $leftovers = @()
    foreach ($file in (Get-DistributionFile -Root $target)) {
        $relative = Get-RelativePath -Root $target -FullName $file.FullName
        if ($sourceRelatives -notcontains $relative) { $leftovers += $relative }
    }
    if ($leftovers.Count -gt 0) {
        Write-Host ""
        Write-Warning "配布物に無いファイルが、原本に残っています（削除はしません）:"
        foreach ($r in $leftovers) { Write-Warning "  ? $r" }
        Write-Warning "配布物から外したファイルなら、原本の側を手で片付けてください。"
    }
}

if ($WhatIf) {
    Write-Host ""
    Write-Step "-WhatIf のため、ここで終わります。何も書き換えていません。"
    exit 0
}

# --- 4. 確認をとる -----------------------------------------------------------

if ($targetExists) {
    Write-Host ""
    $answer = Read-Host "原本を上書きしますか（y を入力すると実行、それ以外で中止）"
    if ($answer -ne 'y') {
        Write-Step "中止しました。何も書き換えていません。"
        exit 0
    }
}

# --- 5. 置く -----------------------------------------------------------------

if (-not $targetExists) {
    $null = New-Item -ItemType Directory -Path $target
}

try {
    foreach ($file in $files) {
        $relative = Get-RelativePath -Root $Source -FullName $file.FullName
        $to = Join-Path $target $relative
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) {
            $null = New-Item -ItemType Directory -Path $toDir -Force
        }
        Copy-Item -LiteralPath $file.FullName -Destination $to -Force
    }
}
catch {
    Write-Warning "コピーの途中で失敗しました。出力をそのまま示します:"
    Write-Host ($_ | Out-String)
    Write-Warning "原本が途中まで更新された状態です。中身を確認してください。"
    exit 1
}

# --- 6. 結果 -----------------------------------------------------------------

$placedVersionFile = Join-Path (Join-Path $target '.ai-desk') 'VERSION'
$placedVersion = (Get-Content -LiteralPath $placedVersionFile -Raw -Encoding UTF8).Trim()

Write-Host ""
Write-Step "配布原本を更新しました。"
Write-Host ""
Write-Host "  場所: $target"
Write-Host "  版  : $placedVersion"
Write-Host ""
Write-Host "各インスタンスは、次のように更新できます。"
Write-Host ""
Write-Host "  .\bin\update-instance.ps1 -Path `"<インスタンスのパス>`" -WhatIf"
Write-Host "  .\bin\update-instance.ps1 -Path `"<インスタンスのパス>`""
Write-Host ""
Write-Host "インスタンス側で「疎通確認」と言うと、版のずれを知らせます。"
Write-Host ""
exit 0
