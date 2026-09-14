#Requires -Version 5.1
<#
  setup_history.ps1  --  ネットワークドライブ上の AI-DESK で、Claude Code の履歴の一覧を出るようにする
  配置先: <AI-DESK のインスタンス>\bin\setup_history.ps1

  症状:
    AI-DESK がネットワークドライブ（Z: など）の上にあると、VS Code の Claude Code で
    履歴（過去の会話）の一覧に、過去のセッションが出てこない。

  原因（Claude Code 側の不具合）:
    Claude Code は履歴を <ユーザーのフォルダ>\.claude\projects\<名前>\ に保存する。
    <名前> は、作業フォルダのパスの英数字以外を - にしたもの。
      保存するとき          : Z:\... をそのまま使う                  → z--...
      VS Code が一覧を探すとき: 実体のパス（\\サーバー\共有\...）に直してから使う → --サーバー-共有-...
    探す先のフォルダが無いので、一覧が空になる。

  やること:
    「一覧が探す名前」で、「実際の保存先」を指すジャンクション（同じフォルダへの別の入口）を1本作る。
    保存先のフォルダがまだ無ければ、空のフォルダを先に作る。
    管理者権限は要らない。ファイルの移動・削除・上書きは一切しない。

  使い方:
    powershell -NoProfile -ExecutionPolicy Bypass -File "<インスタンスのルート>\bin\setup_history.ps1"
    powershell -NoProfile -ExecutionPolicy Bypass -File "<インスタンスのルート>\bin\setup_history.ps1" -CheckOnly

  PC ごと・AI-DESK のフォルダごとに1回必要です（履歴は PC ごとに保存されるため）。
  何度実行しても同じ結果になります。

  終了コード: 0=対処済み・対処不要 / 1=要対処・対処できなかった（メッセージを読んでください）
  このスクリプトは事業データに一切触れません。
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,         # 調べるだけ。何も作らない
    [string]$Path,              # 対象の作業フォルダ。既定は、このスクリプトがあるインスタンスのルート
    [string]$ProjectsRoot       # 履歴の置き場所。既定は <ユーザーのフォルダ>\.claude\projects
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[setup_history] $Message" }

function ConvertTo-ProjectName {
    # Claude Code と同じ規則: 英数字以外を - にする
    param([string]$Text)
    return ($Text -replace '[^a-zA-Z0-9]', '-')
}

function Get-JsonlCount {
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Folder -Filter '*.jsonl' -File -Force -ErrorAction SilentlyContinue).Count
}

# --- 1. 対象の作業フォルダ ---------------------------------------------------

if (-not $Path) {
    $Path = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Warning "フォルダが見つかりません: $Path"
    exit 1
}
$full = [System.IO.Path]::GetFullPath($Path)
if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }

# --- 2. ネットワークドライブの上か -------------------------------------------

if ($full -notmatch '^([A-Za-z]):\\') {
    Write-Step "ドライブ文字（Z: など）で始まる場所ではないため、この問題は起きません: $full"
    exit 0
}
$letter = $Matches[1]

$uncRoot = $null
$drive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue
if ($drive -and $drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\')) {
    $uncRoot = $drive.DisplayRoot
}
if (-not $uncRoot) {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $letter + ":'") -ErrorAction SilentlyContinue
    if ($disk -and $disk.ProviderName -and $disk.ProviderName.StartsWith('\\')) {
        $uncRoot = $disk.ProviderName
    }
}
if (-not $uncRoot) {
    Write-Step "$($letter): はネットワークドライブではありません。この問題は起きないため、対処は不要です。"
    exit 0
}

$uncPath = $uncRoot.TrimEnd('\') + $full.Substring(2)

# --- 3. 2つの名前を求める ----------------------------------------------------

if (-not $ProjectsRoot) {
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $ProjectsRoot = Join-Path $configDir 'projects'
}

$savedName = ConvertTo-ProjectName $full
$lookupName = ConvertTo-ProjectName $uncPath

Write-Step "作業フォルダ     : $full"
Write-Step "ネットワーク上   : $uncPath"
Write-Step "履歴の保存先     : $(Join-Path $ProjectsRoot $savedName)"
Write-Step "一覧が探しに行く先: $(Join-Path $ProjectsRoot $lookupName)"

if ($savedName.Length -gt 200 -or $lookupName.Length -gt 200) {
    Write-Warning "パスが長すぎるため、この方法では対処できません。"
    Write-Warning "200文字を超える名前は、Claude Code が別の規則で縮めて保存するためです。"
    Write-Warning "AI-DESK を、もっと浅い場所に置くことを検討してください。"
    exit 1
}

$saved = Join-Path $ProjectsRoot $savedName
$lookup = Join-Path $ProjectsRoot $lookupName

# --- 4. いまの状態を見る -----------------------------------------------------

$lookupItem = Get-Item -LiteralPath $lookup -Force -ErrorAction SilentlyContinue

if ($lookupItem) {
    if ($lookupItem.LinkType -eq 'Junction' -or $lookupItem.LinkType -eq 'SymbolicLink') {
        $target = [string](@($lookupItem.Target)[0])
        $sameTarget = $false
        if ($target) {
            $sameTarget = ([System.IO.Path]::GetFullPath($target).TrimEnd('\') -ieq
                           [System.IO.Path]::GetFullPath($saved).TrimEnd('\'))
        }
        if ($sameTarget) {
            Write-Step "対処済みです（一覧が探しに行く先は、履歴の保存先を指しています）。"
            exit 0
        }
        Write-Warning "一覧が探しに行く先は、別の場所を指すリンクになっています: $target"
        Write-Warning "このスクリプトは変更しません。中身を確かめてから、手で判断してください。"
        exit 1
    }

    # リンクではない、本物のフォルダがある
    $savedCount = Get-JsonlCount $saved
    Write-Step "一覧が探しに行く先に、すでに本物のフォルダがあります（履歴 $(Get-JsonlCount $lookup) 件）。"
    Write-Step "Claude Code 側で不具合が直り、そちらにも保存されるようになった可能性があります。"
    if ($savedCount -gt 0) {
        Write-Warning "履歴の保存先にも $savedCount 件あり、そちらは一覧に出ません。"
        Write-Warning "このスクリプトは、フォルダの中身を移したり消したりしないため、何もしません。"
        exit 1
    }
    Write-Step "履歴の保存先に履歴は無いため、対処は不要です。"
    exit 0
}

if ($CheckOnly) {
    Write-Step "まだ対処されていません（履歴の保存先にある履歴: $(Get-JsonlCount $saved) 件）。"
    Write-Step "-CheckOnly を付けずに実行すると、ジャンクションを作ります。"
    exit 1
}

# --- 5. ジャンクションを作る -------------------------------------------------

try {
    if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $ProjectsRoot -Force
    }
    if (-not (Test-Path -LiteralPath $saved -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $saved
        Write-Step "履歴の保存先がまだ無いため、空のフォルダを作りました。"
    }
    $null = New-Item -ItemType Junction -Path $lookup -Target $saved
}
catch {
    Write-Warning "ジャンクションを作れませんでした。出力をそのまま示します:"
    Write-Host ($_ | Out-String)
    exit 1
}

$check = Get-Item -LiteralPath $lookup -Force -ErrorAction SilentlyContinue
if (-not $check -or $check.LinkType -ne 'Junction') {
    Write-Warning "ジャンクションを作ったはずですが、確かめられませんでした: $lookup"
    exit 1
}

Write-Step "ジャンクションを作りました。"
Write-Host ""
Write-Host "VS Code の Claude Code で、履歴の一覧を開き直してください。"
Write-Host "出てこなければ、Ctrl+Shift+P →「Developer: Reload Window」でウィンドウを読み込み直してください。"
Write-Host "（この PC で、この AI-DESK を使うのは、これで大丈夫です。別の PC では、そこでも1回実行が要ります）"
exit 0
