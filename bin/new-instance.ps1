#Requires -Version 5.1
<#
  new-instance.ps1  --  AI-DESK のインスタンスを新しく作る

  使い方:
    .\bin\new-instance.ps1 -Dest "C:\Users\yamada" -Name "AI-DESK"
    .\bin\new-instance.ps1 -Dest "Z:\個人\yamada" -Name "AI-DESK2" -Source "Z:\AI-DESK\_配布\AI-DESK"

  やること:
    1. コピー先が既にあれば、何もせず中止する（上書きしません）
    2. 配布物を丸ごとコピーする（.git は絶対にコピーしません）
    3. PROFILE.example.md から PROFILE.md を作る（無い場合だけ）
    4. settings.local.json.example から settings.local.json を作る（無い場合だけ）
    5. .ai-desk\source.txt に、コピー元のパスを記録する

  このスクリプトは、削除・移動を一切行いません。
  終了コード: 0=成功 / 1=中止（メッセージを読んでください）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Dest,                      # 置き場所（この下に -Name のフォルダを作ります）

    [string]$Name = 'AI-DESK',          # インスタンスのフォルダ名。自由に付けられます

    [string]$Source                     # コピー元の配布物。既定は、このスクリプトの隣の AI-DESK\
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "[new-instance] $Message" }

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

function Write-TextFileUtf8NoBom {
    param([string]$LiteralPath, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($LiteralPath, $Text, $encoding)
}

# --- 1. コピー元を決める -----------------------------------------------------

if (-not $Source) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $Source = Join-Path $repoRoot 'AI-DESK'
}

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Warning "コピー元が見つかりません: $Source"
    exit 1
}
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath

$sourceVersionFile = Join-Path (Join-Path $Source '.ai-desk') 'VERSION'
if (-not (Test-Path -LiteralPath $sourceVersionFile)) {
    Write-Warning "コピー元が AI-DESK の配布物ではありません（.ai-desk\VERSION が見つかりません）: $Source"
    exit 1
}
$version = (Get-Content -LiteralPath $sourceVersionFile -Raw -Encoding UTF8).Trim()

# --- 2. .git が混ざっていないか ----------------------------------------------

$gitDirs = @(Get-ChildItem -LiteralPath $Source -Recurse -Force -Directory -Filter '.git' -ErrorAction SilentlyContinue)
if ($gitDirs.Count -gt 0) {
    Write-Warning "コピー元に .git が含まれています。中止します。"
    Write-Warning "インスタンスは git のクローンではありません。機密情報が push される事故を防ぐためです。"
    foreach ($d in $gitDirs) { Write-Warning ("  " + $d.FullName) }
    exit 1
}

# --- 3. コピー先を決める（既にあれば中止） -----------------------------------

if (-not (Test-Path -LiteralPath $Dest)) {
    Write-Warning "置き場所が見つかりません: $Dest"
    Write-Warning "フォルダを先に作るか、パスの打ち間違いがないか確かめてください。"
    exit 1
}
$Dest = (Resolve-Path -LiteralPath $Dest).ProviderPath
$target = Join-Path $Dest $Name

if (Test-Path -LiteralPath $target) {
    Write-Warning "そこには既に何かあります。上書きしないため中止します: $target"
    Write-Warning "既存のインスタンスを新しい版にするには、update-instance.ps1 を使ってください。"
    exit 1
}

# --- 4. コピーする -----------------------------------------------------------

Write-Step "コピー元: $Source （版 $version）"
Write-Step "コピー先: $target"

$files = @(Get-DistributionFile -Root $Source)
$null = New-Item -ItemType Directory -Path $target

try {
    foreach ($file in $files) {
        $relative = Get-RelativePath -Root $Source -FullName $file.FullName
        $to = Join-Path $target $relative
        $toDir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $toDir)) {
            $null = New-Item -ItemType Directory -Path $toDir -Force
        }
        Copy-Item -LiteralPath $file.FullName -Destination $to
    }
}
catch {
    Write-Warning "コピーの途中で失敗しました。出力をそのまま示します:"
    Write-Host ($_ | Out-String)
    Write-Warning "途中まで作られたフォルダが残っています: $target"
    Write-Warning "このスクリプトは削除を行いません。中身を確認して、手で片付けてください。"
    exit 1
}

Write-Step ("コピーしたファイル: " + $files.Count + " 個")

# --- 5. サイト固有ファイルを用意する（無い場合だけ）--------------------------

$profileExample = Join-Path $target 'PROFILE.example.md'
$profileFile    = Join-Path $target 'PROFILE.md'
if ((Test-Path -LiteralPath $profileExample) -and -not (Test-Path -LiteralPath $profileFile)) {
    Copy-Item -LiteralPath $profileExample -Destination $profileFile
    Write-Step "PROFILE.md を作りました（PROFILE.example.md の写しです）"
}

$claudeDir      = Join-Path $target '.claude'
$settingExample = Join-Path $claudeDir 'settings.local.json.example'
$settingFile    = Join-Path $claudeDir 'settings.local.json'
if ((Test-Path -LiteralPath $settingExample) -and -not (Test-Path -LiteralPath $settingFile)) {
    Copy-Item -LiteralPath $settingExample -Destination $settingFile
    Write-Step ".claude\settings.local.json を作りました（.example の写しです）"
}

# --- 6. どこから来たかを記録する ---------------------------------------------

$aiDeskDir  = Join-Path $target '.ai-desk'
$sourceFile = Join-Path $aiDeskDir 'source.txt'
if (-not (Test-Path -LiteralPath $aiDeskDir)) {
    $null = New-Item -ItemType Directory -Path $aiDeskDir -Force
}
Write-TextFileUtf8NoBom -LiteralPath $sourceFile -Text ($Source + "`r`n")
Write-Step ".ai-desk\source.txt に配布元を記録しました"

# --- 7. 完了メッセージ -------------------------------------------------------

Write-Host ""
Write-Host "AI-DESK のインスタンスを作りました。"
Write-Host ""
Write-Host "  場所: $target"
Write-Host "  版  : $version"
Write-Host ""
Write-Host "次にやってください。"
Write-Host ""
Write-Host "  1. PROFILE.md に、あなたの組織の情報を書いてください。"
Write-Host "     （業態・社内の言葉・資料がどこにあるか。中身は架空の記入例です）"
Write-Host ""
Write-Host "  2. .claude\settings.local.json に、読んでよいフォルダを書いてください。"
Write-Host "     （書き方は同じフォルダの .example と、README.md にあります）"
Write-Host ""
Write-Host "  3. そのフォルダで claude を起動し、「疎通確認」と言ってください。"
Write-Host ""
Write-Host "  4. 【重要】初回に一度だけ出る「このフォルダを信頼しますか」に、必ず承諾してください。"
Write-Host "     ここで断ると設定がすべて無視され、資料を一切読めません。"
Write-Host ""
exit 0
