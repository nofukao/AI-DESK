<#
  setup_python.ps1  --  Claude Code 作業環境の Python 自動セットアップ
  配置先: <AI-DESK のインスタンス>\bin\setup_python.ps1
  用途: どの PC でも同じ手順で Python + 抽出用ライブラリを整える（冪等）

  使い方:
    powershell -NoProfile -ExecutionPolicy Bypass -File "<インスタンスのルート>\bin\setup_python.ps1"
    powershell -NoProfile -ExecutionPolicy Bypass -File "<インスタンスのルート>\bin\setup_python.ps1" -CheckOnly

  終了コード: 0=使用可能 / 1=要対処（メッセージ参照）
  このスクリプトは事業データに一切触れません。
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,                     # 調査のみ。インストールしない
    [string]$WingetId = 'Python.Python.3.13',
    [string[]]$Packages = @('openpyxl','pandas','python-docx','python-pptx','pdfplumber')
)

$ErrorActionPreference = 'Continue'

function Write-Step($msg) { Write-Host "[setup] $msg" }

# --- 使える Python を探す ---------------------------------------------------
# 注意1: Windows には python.exe という「Microsoft Store 誘導用スタブ」が
#        PATH 上に存在することがある。これは実行すると 9009 を返す偽物なので
#        必ず「実際にコードが動くか」で判定する。
# 注意2: Inkscape・GIMP・Blender などのアプリは自前の python.exe を同梱しており、
#        それが PATH の先頭に来ていることがある。実体のパスは返ってくるので
#        「WindowsApps でなければ本物」という判定では見抜けない。
#        そこへ pip install すると他アプリの環境を汚すため、使ってはならない。
#        → py ランチャーを最優先し、python/python3 は標準の導入先のみ採用する。
function Test-StandardPythonPath {
    param([string]$Exe)
    if (-not $Exe) { return $false }
    if ($Exe -match 'WindowsApps') { return $false }
    # python.org / winget が入れる標準の場所だけを本物とみなす
    return ($Exe -match '\\Programs\\Python\\Python3') -or
           ($Exe -match '\\Program Files\\Python3') -or
           ($Exe -match '\\Program Files \(x86\)\\Python3') -or
           ($Exe -match '^[A-Za-z]:\\Python3')
}

function Get-PythonExe {
    param([string]$Command, [string[]]$PreArgs = @())
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $exe = & $Command @PreArgs -c "import sys; print(sys.executable)" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $exe) { return $null }
    return $exe.Trim()
}

function Find-UsablePython {
    # 1) py ランチャーを最優先する。
    #    py は python.org / winget の正規インストールだけを登録するため、
    #    他アプリ同梱の python を掴むことがない。
    $exe = Get-PythonExe -Command 'py' -PreArgs @('-3')
    if (-not $exe) { $exe = Get-PythonExe -Command 'py' }
    if ($exe -and ($exe -notmatch 'WindowsApps')) { return $exe }

    # 2) python / python3 は「標準の導入先」に限って採用する
    foreach ($c in @('python', 'python3')) {
        $exe = Get-PythonExe -Command $c
        if (-not $exe) { continue }
        if (Test-StandardPythonPath $exe) { return $exe }
        if ($exe -notmatch 'WindowsApps') {
            Write-Warning "$c は別のアプリに同梱された Python を指しています: $exe"
            Write-Warning "ここには入れません（他アプリの環境を壊さないため）。正規の Python を探します。"
        }
    }

    # 3) PATH に無くても既定の場所に入っている場合を拾う
    $guesses = @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "$env:ProgramFiles\Python3*\python.exe"
    )
    foreach ($g in $guesses) {
        $hit = Get-ChildItem $g -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Update-PathFromRegistry {
    $m = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($m, $u) | Where-Object { $_ }) -join ';'
}

# --- 1. Python 本体 ---------------------------------------------------------
$py = Find-UsablePython

if ($py) {
    Write-Step "Python は使用可能です: $py"
} else {
    Write-Step "使用可能な Python が見つかりません。"
    if ($CheckOnly) { Write-Step "CheckOnly のため何もしません。"; exit 1 }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning @'
winget が使えないため自動インストールできません。
次のいずれかを手動で行ってください:
  A) https://www.python.org/downloads/windows/ から Python 3.13 をダウンロードし、
     インストーラの「Add python.exe to PATH」に必ずチェックを入れて実行する
  B) 情報システム担当に winget（アプリ インストーラー）の有効化を依頼する
'@
        exit 1
    }

    Write-Step "winget で $WingetId をユーザー領域にインストールします（管理者権限不要）..."
    & winget install --id $WingetId --source winget --scope user `
        --accept-package-agreements --accept-source-agreements --silent
    $wingetExit = $LASTEXITCODE

    Update-PathFromRegistry
    $py = Find-UsablePython

    if (-not $py) {
        Write-Warning "インストール後も Python を検出できません（winget 終了コード: $wingetExit）。"
        Write-Warning "PATH が未反映の可能性があります。PC を再起動するか、Python を手動インストールしてください。"
        exit 1
    }
    Write-Step "インストール完了: $py"
}

# --- 2. ライブラリ ----------------------------------------------------------
$missing = @()
foreach ($p in $Packages) {
    # 配布名とインポート名が違うものを吸収する
    $import = switch ($p) {
        'python-docx' { 'docx' }
        'python-pptx' { 'pptx' }
        default       { $p -replace '-', '_' }
    }
    & $py -c "import $import" 2>$null
    if ($LASTEXITCODE -ne 0) { $missing += $p }
}

if ($missing.Count -eq 0) {
    Write-Step "必要なライブラリはすべて導入済みです。"
} else {
    Write-Step ("不足しているライブラリ: " + ($missing -join ', '))
    if ($CheckOnly) { Write-Step "CheckOnly のため何もしません."; exit 1 }

    Write-Step "pip でインストールします..."
    & $py -m pip install --upgrade pip --quiet
    & $py -m pip install --upgrade @missing
    if ($LASTEXITCODE -ne 0) { Write-Warning "pip インストールに失敗しました。"; exit 1 }
    Write-Step "ライブラリの導入が完了しました。"
}

# --- 3. 結果 ----------------------------------------------------------------
Write-Host ""
Write-Host "PYTHON_EXE=$py"
Write-Step "セットアップ完了。抽出スクリプトは上記の PYTHON_EXE で実行してください。"
Write-Step "コマンドラインでは python ではなく py を使ってください（別アプリ同梱の python を避けるため）。"
exit 0
