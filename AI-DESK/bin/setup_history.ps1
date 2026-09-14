#Requires -Version 5.1
<#
  setup_history.ps1  --  ネットワークドライブの上で使う Claude Code の、履歴の一覧を出るようにする

  ============================================================================
   AI へ: このファイルを渡されて「実行して」と頼まれたら、次のとおりにしてください
  ============================================================================
    1. まず、調べるだけの実行をして、出力をそのままユーザーに見せる。
         powershell -NoProfile -ExecutionPolicy Bypass -File "<このファイルのパス>" -CheckOnly
       対象は、いまの作業フォルダです。この PC の履歴にある、ネットワークドライブ上の
       フォルダをまとめて調べるときは、-All も付けます。
    2. 「まだ対処されていません」と出たら、下の「やること」を短く伝え、
       ユーザーの承諾を得てから、-CheckOnly を外して同じように実行する。
    3. 「直しました」と出たら、VS Code の Claude Code で、履歴の一覧を開き直すよう伝える。
       出てこなければ、Ctrl+Shift+P →「Developer: Reload Window」を案内する。
    4. 「対処できません」と出たら、出力をそのまま伝える。
       自分でジャンクションを作ったり、フォルダを移動・削除したりしない。
    このスクリプトが書き込むのは、ユーザーのフォルダの .claude\projects\ の中だけです。
    作業フォルダ（ネットワークドライブの側）には、何も書きません。

  症状:
    ネットワークドライブ（Z: など）の上のフォルダで Claude Code を使うと、
    VS Code の Claude Code の履歴（過去の会話）の一覧に、過去のセッションが出てこない。
    ターミナルの claude --resume では出る。

  原因（Claude Code 側の不具合です。Windows の問題ではありません）:
    Claude Code は履歴を <ユーザーのフォルダ>\.claude\projects\<名前>\ に保存する。
    <名前> は、作業フォルダのパスの英数字以外を - にしたもの。
      保存するとき            : Z:\... をそのまま使う                              → Z--...
      VS Code が一覧を探すとき: 実体のパス（\\サーバー\共有\...）に直してから使う → --サーバー-共有-...
    探す先のフォルダが無いので、一覧が空になる。

  やること:
    「一覧が探す名前」で「実際の保存先」を指すジャンクション（同じフォルダへの別の入口）を1本作る。
    保存先のフォルダがまだ無ければ、空のフォルダを先に作る。
    ファイルの移動・削除・上書きは一切しない。管理者権限は要らない。
    Claude Code 側で不具合が直っても、同じフォルダを指す入口が1つあるだけなので害はない。

  使い方:
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\setup_history.ps1" -CheckOnly
        いまの作業フォルダを調べるだけ
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\setup_history.ps1"
        いまの作業フォルダを直す
    オプション:
        -Path "Z:\フォルダ"   いまの作業フォルダの代わりに、指定したフォルダを対象にする
        -All                  この PC の履歴にある、ネットワークドライブ上のフォルダをすべて対象にする
        -Quiet                何も表示せず、常に終了コード 0 で終わる（自動実行用）

  PC ごと・フォルダごとに1回必要です（履歴は PC ごとに保存されるため）。何度実行しても同じ結果になります。
  AI-DESK では、配布物の設定により、セッションを始めるたびに -Quiet で自動実行されます。

  終了コード: 0=対処済み・対処不要・直した / 1=まだ対処されていない・対処できない
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,         # 調べるだけ。何も作らない
    [string]$Path,              # 対象の作業フォルダ。既定は、いまの作業フォルダ
    [switch]$All,               # この PC の履歴にある、ネットワークドライブ上のフォルダをすべて対象にする
    [switch]$Quiet,             # 何も表示せず、常に終了コード 0 で終わる（自動実行用）
    [string]$ProjectsRoot       # 履歴の置き場所。既定は <ユーザーのフォルダ>\.claude\projects
)

$ErrorActionPreference = 'Stop'

trap {
    if ($Quiet) { exit 0 }
    Write-Warning ('予期しないエラーで止まりました: ' + $_.Exception.Message)
    exit 1
}

function Write-Info {
    param([string]$Message)
    if (-not $Quiet) { Write-Host "[setup_history] $Message" }
}

function Write-Problem {
    param([string]$Message)
    if (-not $Quiet) { Write-Warning $Message }
}

function Exit-Script {
    param([int]$Code)
    if ($Quiet) { exit 0 }
    exit $Code
}

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

function Get-NetworkRoot {
    # ドライブ文字（Z など）がネットワークドライブなら、その \\サーバー\共有 を返す。違えば $null。
    param([string]$Letter)

    try {
        $info = New-Object System.IO.DriveInfo($Letter)
        if ($info.DriveType -ne [System.IO.DriveType]::Network) { return $null }
    }
    catch {
        return $null
    }

    $drive = Get-PSDrive -Name $Letter -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($drive -and $drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\')) {
        return $drive.DisplayRoot.TrimEnd('\')
    }
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Letter + ":'") -ErrorAction SilentlyContinue
    if ($disk -and $disk.ProviderName -and $disk.ProviderName.StartsWith('\\')) {
        return $disk.ProviderName.TrimEnd('\')
    }
    return $null
}

function Get-ResultLabel {
    param([string]$Result)
    switch ($Result) {
        'ok'      { return '正常（対処済み・対処不要）' }
        'created' { return '直しました' }
        'todo'    { return 'まだ対処されていません' }
        default   { return '対処できません' }
    }
}

function Repair-Folder {
    # 1つの作業フォルダについて調べ、必要ならジャンクションを作る。
    # 戻り値: 'ok'（対処済み・対処不要） / 'created'（直した） / 'todo'（まだ対処されていない） / 'fail'（対処できない）
    param([string]$FullPath)

    Write-Info "作業フォルダ      : $FullPath"

    if ($FullPath -notmatch '^([A-Za-z]):\\') {
        Write-Info 'ドライブ文字（Z: など）で始まる場所ではないため、この問題は起きません。'
        return 'ok'
    }
    $uncRoot = Get-NetworkRoot $Matches[1]
    if (-not $uncRoot) {
        Write-Info 'ネットワークドライブではないため、この問題は起きません。'
        return 'ok'
    }

    $uncPath = $uncRoot + $FullPath.Substring(2)
    $savedName = ConvertTo-ProjectName $FullPath
    $lookupName = ConvertTo-ProjectName $uncPath
    $saved = Join-Path $script:ProjectsRootPath $savedName
    $lookup = Join-Path $script:ProjectsRootPath $lookupName

    Write-Info "ネットワーク上    : $uncPath"
    Write-Info "履歴の保存先      : $saved"
    Write-Info "一覧が探しに行く先: $lookup"

    if ($savedName.Length -gt 200 -or $lookupName.Length -gt 200) {
        Write-Problem 'パスが長すぎるため、この方法では対処できません。'
        Write-Problem '200文字を超える名前は、Claude Code が別の規則で縮めて保存するためです。'
        return 'fail'
    }

    $lookupItem = Get-Item -LiteralPath $lookup -Force -ErrorAction SilentlyContinue
    if ($lookupItem) {
        if ($lookupItem.LinkType -eq 'Junction' -or $lookupItem.LinkType -eq 'SymbolicLink') {
            $target = [string](@($lookupItem.Target)[0])
            if ($target -and ([System.IO.Path]::GetFullPath($target).TrimEnd('\') -ieq
                              [System.IO.Path]::GetFullPath($saved).TrimEnd('\'))) {
                Write-Info '対処済みです（一覧が探しに行く先は、履歴の保存先を指しています）。'
                return 'ok'
            }
            Write-Problem "一覧が探しに行く先は、別の場所を指すリンクになっています: $target"
            Write-Problem '対処できません。このスクリプトは変更しません。中身を確かめてから、手で判断してください。'
            return 'fail'
        }

        # リンクではない、本物のフォルダがある
        $savedCount = Get-JsonlCount $saved
        Write-Info "一覧が探しに行く先に、すでに本物のフォルダがあります（履歴 $(Get-JsonlCount $lookup) 件）。"
        Write-Info 'Claude Code 側で不具合が直り、そちらにも保存されるようになった可能性があります。'
        if ($savedCount -gt 0) {
            Write-Problem "履歴の保存先にも $savedCount 件あり、そちらは一覧に出ません。"
            Write-Problem '対処できません。このスクリプトは、フォルダの中身を移したり消したりしないためです。'
            return 'fail'
        }
        Write-Info '履歴の保存先に履歴は無いため、対処は不要です。'
        return 'ok'
    }

    if ($CheckOnly) {
        Write-Info "まだ対処されていません（履歴の保存先にある履歴: $(Get-JsonlCount $saved) 件）。"
        return 'todo'
    }

    try {
        if (-not (Test-Path -LiteralPath $script:ProjectsRootPath -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $script:ProjectsRootPath -Force
        }
        if (-not (Test-Path -LiteralPath $saved -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $saved
            Write-Info '履歴の保存先がまだ無いため、空のフォルダを作りました。'
        }
        $null = New-Item -ItemType Junction -Path $lookup -Target $saved
    }
    catch {
        Write-Problem ('ジャンクションを作れませんでした: ' + $_.Exception.Message)
        return 'fail'
    }

    $check = Get-Item -LiteralPath $lookup -Force -ErrorAction SilentlyContinue
    if (-not $check -or $check.LinkType -ne 'Junction') {
        Write-Problem "ジャンクションを作ったはずですが、確かめられませんでした: $lookup"
        return 'fail'
    }
    Write-Info 'ジャンクションを作りました。'
    return 'created'
}

function Find-NetworkProjectFolder {
    # 履歴の置き場所から、ネットワークドライブ上の作業フォルダを探す。
    # フォルダ名からは元のパスを戻せない（英数字以外がすべて - になっている）ため、
    # 履歴ファイルに記録された作業フォルダ（cwd）を読み、そこから作った名前が
    # フォルダ名と一致するものだけを採る。
    param([string]$Root)

    $found = @{}
    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($dir.LinkType) { continue }
        if ($dir.Name -match '^([A-Za-z])--') { $letter = $Matches[1] } else { continue }
        if (-not (Get-NetworkRoot $letter)) { continue }

        $files = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -Force -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 5)
        foreach ($file in $files) {
            $lines = @(Get-Content -LiteralPath $file.FullName -TotalCount 50 -Encoding UTF8 -ErrorAction SilentlyContinue)
            foreach ($line in $lines) {
                foreach ($m in [regex]::Matches([string]$line, '"cwd":"((?:[^"\\]|\\.)*)"')) {
                    try { $cwd = [string](ConvertFrom-Json -InputObject ('"' + $m.Groups[1].Value + '"')) } catch { continue }
                    if ((ConvertTo-ProjectName $cwd) -ieq $dir.Name) { $found[$dir.Name] = $cwd; break }
                }
                if ($found.ContainsKey($dir.Name)) { break }
            }
            if ($found.ContainsKey($dir.Name)) { break }
        }
    }
    return @($found.Values | Sort-Object)
}

# --- 履歴の置き場所 ----------------------------------------------------------

if ($ProjectsRoot) {
    $script:ProjectsRootPath = $ProjectsRoot
}
else {
    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $script:ProjectsRootPath = Join-Path $configDir 'projects'
}

$openAgain = 'VS Code の Claude Code で、履歴の一覧を開き直してください。' +
             '出てこなければ、Ctrl+Shift+P →「Developer: Reload Window」でウィンドウを読み込み直してください。'

# --- -All: この PC の履歴にある、ネットワークドライブ上のフォルダをすべて ---------

if ($All) {
    $folders = @(Find-NetworkProjectFolder -Root $script:ProjectsRootPath)
    if ($folders.Count -eq 0) {
        Write-Info 'この PC の履歴に、ネットワークドライブ上のフォルダは見つかりませんでした。'
        Exit-Script 0
    }

    $results = @()
    foreach ($folder in $folders) {
        if (-not $Quiet) { Write-Host '' }
        $results += [pscustomobject]@{ Folder = $folder; Result = (Repair-Folder -FullPath $folder) }
    }

    if (-not $Quiet) { Write-Host '' }
    Write-Info '===== まとめ ====='
    foreach ($r in $results) {
        Write-Info ('{0}: {1}' -f (Get-ResultLabel $r.Result), $r.Folder)
    }
    if (@($results | Where-Object { $_.Result -eq 'created' }).Count -gt 0) {
        Write-Info $openAgain
    }
    if (@($results | Where-Object { $_.Result -eq 'todo' }).Count -gt 0) {
        Write-Info '-CheckOnly を付けずに実行すると、「まだ対処されていません」のものを直します。'
    }
    $bad = @($results | Where-Object { $_.Result -eq 'todo' -or $_.Result -eq 'fail' }).Count
    if ($bad -gt 0) { Exit-Script 1 }
    Exit-Script 0
}

# --- 1つのフォルダ（既定は、いまの作業フォルダ） ------------------------------

if (-not $Path) {
    $Path = (Get-Location).ProviderPath
}
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Problem "フォルダが見つかりません: $Path"
    Exit-Script 1
}
$full = [System.IO.Path]::GetFullPath($Path)
if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }

$result = Repair-Folder -FullPath $full
Write-Info ('結果: ' + (Get-ResultLabel $result))

switch ($result) {
    'ok'      { Exit-Script 0 }
    'created' {
        Write-Info $openAgain
        Write-Info '（この PC で、このフォルダを使うのは、これで大丈夫です。別の PC では、そこでも1回実行が要ります）'
        Exit-Script 0
    }
    'todo'    {
        Write-Info '-CheckOnly を付けずに実行すると、ジャンクションを作ります。'
        Exit-Script 1
    }
    default   { Exit-Script 1 }
}
