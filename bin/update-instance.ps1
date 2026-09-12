#Requires -Version 5.1
<#
  update-instance.ps1  --  既にあるインスタンスの、配布物だけを新しい版にする

  使い方:
    .\bin\update-instance.ps1 -Path "C:\Users\yamada\AI-DESK" -WhatIf   # 差分を見るだけ
    .\bin\update-instance.ps1 -Path "C:\Users\yamada\AI-DESK"           # 実行する
    .\bin\update-instance.ps1 -Path "..." -Source "Z:\AI-DESK\_配布\AI-DESK"

  絶対に触らないもの:
    - タスクフォルダ（配布物に無いフォルダは、中身ごと一切触りません）
    - PROFILE.md
    - .claude\settings.local.json
    - .ai-desk\source.txt
    - 利用者が足したスキル（配布物に無い .claude\skills\ の中身）

  上書きする前に、元のファイルを .ai-desk\backup\<旧版番号>\ に退避します。
  ファイルの削除は一切行いません。

  終了コード: 0=成功または中止（差分なし・利用者が中止） / 1=異常（メッセージを読んでください）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,                      # インスタンスのフォルダ（.ai-desk\VERSION がある場所）

    [string]$Source,                    # 配布元。既定は source.txt の場所、無ければ隣の AI-DESK\

    [switch]$WhatIf                     # 差分を表示するだけで、何も書き換えない
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[update-instance] $Message" }

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

function Get-VersionText {
    param([string]$Root)
    $file = Join-Path (Join-Path $Root '.ai-desk') 'VERSION'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return (Get-Content -LiteralPath $file -Raw -Encoding UTF8).Trim()
}

# --- 1. インスタンスかどうか確かめる -----------------------------------------

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Warning "見つかりません: $Path"
    exit 1
}
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

$currentVersion = Get-VersionText -Root $Path
if (-not $currentVersion) {
    Write-Warning "ここは AI-DESK のインスタンスではありません（.ai-desk\VERSION が見つかりません）: $Path"
    Write-Warning "新しく作るのなら new-instance.ps1 を使ってください。"
    exit 1
}

# --- 2. 配布元を決める -------------------------------------------------------

$sourceFile = Join-Path (Join-Path $Path '.ai-desk') 'source.txt'
$sourceOrigin = ''

if ($Source) {
    $sourceOrigin = '-Source で指定'
}
elseif (Test-Path -LiteralPath $sourceFile) {
    $recorded = (Get-Content -LiteralPath $sourceFile -Raw -Encoding UTF8).Trim()
    if ($recorded -and (Test-Path -LiteralPath $recorded)) {
        $Source = $recorded
        $sourceOrigin = '.ai-desk\source.txt に記録された配布元'
    }
    else {
        Write-Warning "source.txt に書かれた配布元に届きません: $recorded"
        Write-Warning "（NAS に繋がっていない、配布元が移動した、などが考えられます）"
    }
}

if (-not $Source) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $Source = Join-Path $repoRoot 'AI-DESK'
    $sourceOrigin = 'このスクリプトの隣の配布物'
}

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Warning "配布元が見つかりません: $Source"
    exit 1
}
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath

$newVersion = Get-VersionText -Root $Source
if (-not $newVersion) {
    Write-Warning "配布元が AI-DESK の配布物ではありません（.ai-desk\VERSION が見つかりません）: $Source"
    exit 1
}

$gitDirs = @(Get-ChildItem -LiteralPath $Source -Recurse -Force -Directory -Filter '.git' -ErrorAction SilentlyContinue)
if ($gitDirs.Count -gt 0) {
    Write-Warning "配布元に .git が含まれています。中止します。"
    foreach ($d in $gitDirs) { Write-Warning ("  " + $d.FullName) }
    exit 1
}

Write-Step "インスタンス: $Path （版 $currentVersion）"
Write-Step "配布元      : $Source （版 $newVersion） ← $sourceOrigin"

# --- 3. 差分を調べる ---------------------------------------------------------

$files = @(Get-DistributionFile -Root $Source)
$added   = New-Object System.Collections.ArrayList
$changed = New-Object System.Collections.ArrayList
$same    = New-Object System.Collections.ArrayList

foreach ($file in $files) {
    $relative = Get-RelativePath -Root $Source -FullName $file.FullName
    $to = Join-Path $Path $relative
    if (-not (Test-Path -LiteralPath $to)) {
        $null = $added.Add($relative)
    }
    else {
        $hashFrom = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $hashTo   = (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash
        if ($hashFrom -ne $hashTo) { $null = $changed.Add($relative) }
        else { $null = $same.Add($relative) }
    }
}

Write-Host ""
Write-Host "■ 新しく置かれるファイル ($($added.Count) 個)"
if ($added.Count -eq 0) { Write-Host "  （なし）" }
foreach ($r in $added) { Write-Host "  + $r" }

Write-Host ""
Write-Host "■ 上書きされるファイル ($($changed.Count) 個)"
if ($changed.Count -eq 0) { Write-Host "  （なし）" }
foreach ($r in $changed) { Write-Host "  * $r" }

Write-Host ""
Write-Host "■ 変わらないファイル: $($same.Count) 個"

Write-Host ""
Write-Host "■ 触らないもの（このスクリプトは絶対に書き換えません）"
Write-Host "  - タスクフォルダ（配布物に無いフォルダは、中身ごと触りません）"
Write-Host "  - PROFILE.md"
Write-Host "  - .claude\settings.local.json"
Write-Host "  - .ai-desk\source.txt"
Write-Host "  - 利用者が足したスキル（配布物に無い .claude\skills\ の中身）"
Write-Host "  - ファイルの削除は一切行いません"
Write-Host ""

if (($added.Count + $changed.Count) -eq 0) {
    Write-Step "差分はありません。すでに版 $newVersion です。何もしませんでした。"
    exit 0
}

if ($WhatIf) {
    Write-Step "-WhatIf のため、ここで終わります。何も書き換えていません。"
    exit 0
}

# --- 4. 確認をとる -----------------------------------------------------------

Write-Host "版 $currentVersion → $newVersion に更新します。"
$answer = Read-Host "よろしいですか（y を入力すると実行、それ以外で中止）"
if ($answer -ne 'y') {
    Write-Step "中止しました。何も書き換えていません。"
    exit 0
}

# --- 5. 上書きされるファイルを退避する ---------------------------------------

if ($changed.Count -gt 0) {
    $backupRoot = Join-Path (Join-Path $Path '.ai-desk') 'backup'
    $backupDir = Join-Path $backupRoot $currentVersion
    if (Test-Path -LiteralPath $backupDir) {
        # 既にある退避先は上書きしない（同じ版で2回更新した場合）
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupDir = Join-Path $backupRoot ($currentVersion + '_' + $stamp)
    }

    try {
        foreach ($relative in $changed) {
            $from = Join-Path $Path $relative
            $to = Join-Path $backupDir $relative
            $toDir = Split-Path -Parent $to
            if (-not (Test-Path -LiteralPath $toDir)) {
                $null = New-Item -ItemType Directory -Path $toDir -Force
            }
            Copy-Item -LiteralPath $from -Destination $to
        }
    }
    catch {
        Write-Warning "退避に失敗しました。出力をそのまま示します:"
        Write-Host ($_ | Out-String)
        Write-Warning "上書きは行っていません。インスタンスは元のままです。"
        exit 1
    }
    Write-Step "元のファイルを退避しました: $backupDir"
}

# --- 6. 上書きする -----------------------------------------------------------

$written = 0
try {
    foreach ($relative in ($added + $changed)) {
        $from = Join-Path $Source $relative
        $to = Join-Path $Path $relative
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) {
            $null = New-Item -ItemType Directory -Path $toDir -Force
        }
        Copy-Item -LiteralPath $from -Destination $to -Force
        $written = $written + 1
    }
}
catch {
    Write-Warning "更新の途中で失敗しました。出力をそのまま示します:"
    Write-Host ($_ | Out-String)
    Write-Warning "途中まで更新された状態です。退避したファイルは .ai-desk\backup\ にあります。"
    Write-Warning "このスクリプトは削除も切り戻しも行いません。中身を確認してください。"
    exit 1
}

# --- 7. 結果 -----------------------------------------------------------------

$afterVersion = Get-VersionText -Root $Path

Write-Host ""
Write-Step "更新しました: $written 個のファイルを置きました"
Write-Step "版: $currentVersion → $afterVersion"
Write-Host ""
Write-Host "claude を起動中だった場合は、いったん終了して起動し直してください。"
Write-Host "規則とスキルは、起動したときに読み込まれます。"
Write-Host ""
exit 0
