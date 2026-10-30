#Requires -Version 5.1
<#
  guard-write.ps1  --  AI が書き込める場所を、決まった場所だけに限る

  Claude Code の hook（PreToolUse）として、.claude\settings.json から呼ばれます。
  AI がファイルを書く直前（Edit / Write / NotebookEdit）に書き込み先を調べ、
  次のどれにも当たらなければ、その書き込みを止めます。

    <インスタンスのルート>\<タスクフォルダ>\ の中の、決まった名前のもの（下記）
    <インスタンスのルート>\PROFILE.md
    <インスタンスのルート>\.claude\skills\ の中

  インスタンスのルートは、このスクリプトの2つ上のフォルダです（.ai-desk\VERSION があること）。
  タスクフォルダは、次のどちらかです。
    ルート直下のフォルダ
    ルート直下の保管フォルダ（名前が _保管 で始まるもの）の、直下のフォルダ
  どちらの場合も、次の名前はタスクフォルダではありません。
    名前が . で始まるもの（.claude、.ai-desk など） / bin / 00_タスクテンプレート / out（out2 なども） /
    名前が _保管 で始まるもの（保管フォルダそのもの。保管フォルダの中に、保管フォルダは作れません）
  保管フォルダの直下に置けるのは、タスクフォルダだけです（ファイルは置けません）。

  タスクフォルダの中で書いてよい名前は、次だけです。**場所だけでなく、名前でも判定します。**

    00_ で始まるファイル           タスク全体のもの（00_作業記録.md、育てるファイルの 00_議事録.md など）
    NNA_ / NNB_ で始まるファイル   その回の依頼（A）と成果物（B）
    NNB_ で始まるフォルダの中      1回で3つ以上出すときの、まとめ先
    材料\ の中                     スクリプト・中間データ・バックアップ・育てるファイルの控え

    ただし 00_TASK.md は書けません。人が書く依頼の原本だからです。
    AI が書く依頼の記録は NNA_依頼内容.md の方です。

  名前でも判定するのは、タスクフォルダの中に、人が置いたもの（00_TASK.md、
  参考に置いた資料など）が混ざるためです。場所だけで判定すると、それらを上書きできてしまいます。

  ネットワークドライブの上の AI-DESK では、Z:\... と \\サーバー\共有\... の2つの書き方が
  混ざることがあります。その場合は、両方を \\サーバー\共有\... の形に揃えてから比べます。

  止め方: 理由を標準エラーと標準出力（JSON）に書き、終了コード 2 で終わります。
  書き込み先を判定できないとき、このスクリプトの中でエラーが起きたときも、止める側に倒します。

  限界（Claude Code の仕様によるもの）:
    - PowerShell が起動できない、時間切れになった、といった場合は、書き込みは止まりません
    - 見張れるのは、AI が直接書くファイルだけです。
      シェルのコマンドや、Python などのプログラムが書くファイルは見張れません
    - 名前は見ますが、回次の番号が正しいか（第2回なのに 01B_ になっていないか）は見ません

  このスクリプトは、ファイルの作成・変更・削除を一切行いません。
  配布物です。インスタンスの中で直さないでください（次の更新で上書きされます）。
#>

$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Root = $null

# 名前の決まり（大文字・小文字は問いません）
$script:OutNamePattern     = '^out[0-9]*$'       # 1.1.0 までの出力先。いまは使いません
$script:TaskFilePattern    = '^00_'              # タスク全体の記録
$script:RoundFilePattern   = '^[0-9]{2,}[AB]_'   # その回の依頼（A）と成果物（B）
$script:RoundFolderPattern = '^[0-9]{2,}B_'      # 1回で3つ以上出すときの、まとめ先
$script:MaterialFolderName = '材料'              # スクリプト・中間データ・バックアップ
$script:TaskMdPattern      = '^00_task\.md$'     # 人が書く依頼の原本。AI は書けません
$script:ArchivePattern     = '^_保管'             # 保管フォルダ。タスクフォルダをまとめて置く入れ物

function Write-Utf8 {
    param([System.IO.Stream]$Stream, [string]$Text)
    $bytes = $Utf8NoBom.GetBytes($Text)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Stop-Write {
    # 書き込みを止めて終わる。$Reason は AI に見せる文章です。
    param([string]$Reason)

    $rootText = if ($script:Root) { $script:Root } else { '<インスタンスのルート>' }
    $message = 'AI-DESK の書き込み制限で、この書き込みを止めました。' + $Reason +
        ' 書けるのは、この AI-DESK（' + $rootText + '）の中の次だけです。' +
        '「<タスクフォルダ>\ の中の（保管フォルダ _保管…\ の中のタスクフォルダも同じ）、' +
        '00_ で始まるファイル・NNA_ / NNB_ で始まるファイル・' +
        'NNB_ で始まるフォルダの中・材料\ の中（ただし 00_TASK.md を除く）」' +
        '「PROFILE.md」「.claude\skills\ の中」。' +
        '別のツール、シェルのコマンド、プログラムで書き直そうとせず、このことをユーザーに報告してください。'

    $decision = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $message
        }
    }
    try {
        Write-Utf8 -Stream ([Console]::OpenStandardOutput()) -Text ($decision | ConvertTo-Json -Depth 3 -Compress)
        Write-Utf8 -Stream ([Console]::OpenStandardError()) -Text $message
    }
    catch {
        # 理由を書けなくても、終了コード 2 で止まる
    }
    exit 2
}

function ConvertTo-FullPath {
    # Claude Code から渡されたパスを、Windows の絶対パスに直す。判定できない形なら $null。
    param([string]$PathText, [string]$BaseDir)

    if ([string]::IsNullOrWhiteSpace($PathText)) { return $null }
    $p = $PathText.Trim()

    # /c/Users/... の形（Git Bash などの表記）を C:\Users\... に直す
    if ($p -match '^/([A-Za-z])(/.*)?$') {
        $rest = if ($Matches[2]) { $Matches[2] } else { '/' }
        $p = $Matches[1] + ':' + $rest
    }
    $p = $p.Replace('/', '\')

    # C:foo のような、ドライブの中の相対パスは判定しない
    if ($p -match '^[A-Za-z]:(?!\\)') { return $null }

    # 2文字目より後ろの : （file.md:stream のような代替データストリームなど）は判定しない
    if ($p.Length -gt 2 -and $p.IndexOf(':', 2) -ge 0) { return $null }

    if (-not [System.IO.Path]::IsPathRooted($p)) {
        if ([string]::IsNullOrWhiteSpace($BaseDir)) { return $null }
        $p = [System.IO.Path]::Combine($BaseDir, $p)
    }
    elseif ($p.StartsWith('\') -and -not $p.StartsWith('\\')) {
        # \Users\... のような、ドライブを省いたパスは判定しない
        return $null
    }

    return [System.IO.Path]::GetFullPath($p)
}

function ConvertTo-UncPath {
    # ネットワークドライブ（Z: など）で始まるパスを、\\サーバー\共有\... の形に直す。
    # それ以外は、そのまま返す。
    param([string]$FullPath)

    if ($FullPath -match '^([A-Za-z]):\\') {
        $drive = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($drive -and $drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\')) {
            return $drive.DisplayRoot.TrimEnd('\') + $FullPath.Substring(2)
        }
    }
    return $FullPath
}

function Test-TaskFolderName {
    # この名前は、タスクフォルダになれるか（ルート直下でも、保管フォルダの直下でも同じ）
    param([string]$Name)

    if ($Name.StartsWith('.')) { return $false }
    if ($Name -ieq 'bin') { return $false }
    if ($Name -ieq '00_タスクテンプレート') { return $false }
    if ($Name -imatch $script:OutNamePattern) { return $false }
    if ($Name -imatch $script:ArchivePattern) { return $false }
    return $true
}

function Get-TaskFolderDepth {
    # ルートからの並びのうち、何番目までがタスクフォルダか（1 か 2）。
    # タスクフォルダが無ければ、止める理由の補足（文字列。補足が無ければ空）を返す。
    param([string[]]$Parts)

    $first = $Parts[0]
    if (Test-TaskFolderName $first) { return 1 }
    if (-not ($first -imatch $script:ArchivePattern)) { return '' }

    # 保管フォルダ（_保管…）の中
    if ($Parts.Count -lt 3) {
        return ('「' + $first + '」は保管フォルダです。保管フォルダの直下には、タスクフォルダしか置けません。')
    }
    $second = $Parts[1]
    if ($second -imatch $script:ArchivePattern) {
        return '保管フォルダの中に、保管フォルダは作れません。'
    }
    if (-not (Test-TaskFolderName $second)) {
        return ('「' + $second + '」は、タスクフォルダに使えない名前です。')
    }
    return 2
}

function Get-NameDecision {
    # タスクフォルダの中の、名前だけの判定。
    # 書いてよければ $null を、止めるべきなら理由の文を返す。
    param([string[]]$Parts)   # タスクフォルダ名を除いた、その中での並び

    if ($null -eq $Parts -or $Parts.Count -eq 0) {
        return 'タスクフォルダそのものは、ファイルではありません。'
    }

    $head = $Parts[0]

    if ($Parts.Count -eq 1) {
        # タスクフォルダの直下に置くファイル
        if ($head -imatch $script:TaskMdPattern) {
            return '「00_TASK.md」は、人が書く依頼の原本です。AI は書けません。' +
                   'その回に頼まれたことは「NNA_依頼内容.md」に書いてください。'
        }
        if ($head -imatch $script:TaskFilePattern) { return $null }
        if ($head -imatch $script:RoundFilePattern) { return $null }
        return 'タスクフォルダの直下に置けるのは、「00_」で始まる名前（00_作業記録.md など）と、' +
               '「01A_」「01B_」のように回次と A / B で始まる名前だけです。' +
               '「NNA_依頼内容.md」「NNB_内容を表す日本語名_YYYY-MM-DD.拡張子」の形にしてください。'
    }

    # タスクフォルダの直下にあるフォルダの、中
    if ($head -ieq $script:MaterialFolderName) { return $null }
    if ($head -imatch $script:RoundFolderPattern) { return $null }
    if ($head -imatch $script:OutNamePattern) {
        return 'この版では「out」を使いません。成果物は、タスクフォルダの直下に ' +
               '「NNB_内容を表す日本語名_YYYY-MM-DD.拡張子」の名前で出してください。'
    }
    return 'タスクフォルダの中に置けるフォルダは、「材料」と、' +
           '1回で3つ以上出すときの「NNB_タイトル_YYYY-MM-DD」だけです。'
}

function Get-WriteDecision {
    # 書いてよければ $null を、止めるべきなら理由の文を返す。
    param([string]$Root, [string]$Target)

    # 片方が Z:\...、もう片方が \\サーバー\共有\... の形なら、両方を \\サーバー\共有\... に揃える
    if ($Root.StartsWith('\\') -ne $Target.StartsWith('\\')) {
        $Root = ConvertTo-UncPath $Root
        $Target = ConvertTo-UncPath $Target
    }

    $prefix = $Root.TrimEnd('\') + '\'
    if (-not $Target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ('書き込み先 ' + $Target + ' は、この AI-DESK の外です。')
    }

    $parts = @($Target.Substring($prefix.Length).Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return ('書き込み先 ' + $Target + ' は、ファイルではありません。') }

    $first = $parts[0]

    if (($parts.Count -eq 1) -and ($first -ieq 'PROFILE.md')) {
        # そのまま、下のリンクの検査へ
    }
    elseif (($parts.Count -ge 3) -and ($first -ieq '.claude') -and ($parts[1] -ieq 'skills')) {
        # そのまま、下のリンクの検査へ
    }
    else {
        $depth = Get-TaskFolderDepth -Parts $parts
        if ($depth -is [string]) {
            return ('書き込み先 ' + $Target + ' は、書いてよい場所ではありません。' + $depth)
        }
        $rest = @($parts | Select-Object -Skip $depth)
        $nameReason = Get-NameDecision -Parts $rest
        if ($nameReason) {
            return ('書き込み先 ' + $Target + ' は、書いてよい名前ではありません。' + $nameReason)
        }
    }

    # 途中に、別の場所へのリンクが無いか。
    # タスクフォルダの中にジャンクションやシンボリックリンクがあると、見た目はタスクフォルダの中でも、
    # 実際には別の場所（資料フォルダなど）に書き込まれるためです。
    $current = $prefix.TrimEnd('\')
    foreach ($part in $parts) {
        $current = [System.IO.Path]::Combine($current, $part)
        if (-not ([System.IO.Directory]::Exists($current) -or [System.IO.File]::Exists($current))) { break }
        $item = Get-Item -LiteralPath $current -Force
        if ($item.LinkType) {
            return ('書き込み先の途中に、別の場所へのリンク（' + $item.LinkType + '）があります: ' + $current)
        }
    }

    return $null
}

# 試験のために、関数だけを読み込んだとき（. で読み込んだとき）は、ここで終わる
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    # --- 1. インスタンスのルート -------------------------------------------------

    $rootFull = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
    $script:Root = $rootFull.TrimEnd('\')
    $versionFile = [System.IO.Path]::Combine($script:Root, '.ai-desk', 'VERSION')
    if (-not [System.IO.File]::Exists($versionFile)) {
        $script:Root = $null
        Stop-Write 'このスクリプトの置き場所から、AI-DESK のルート（.ai-desk\VERSION）が見つかりません。'
    }

    # --- 2. Claude Code からの入力（標準入力の JSON、UTF-8） -----------------------

    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $Utf8NoBom)
    $raw = $reader.ReadToEnd()
    $data = ConvertFrom-Json -InputObject $raw

    $toolInput = $data.tool_input
    if ($null -eq $toolInput) { Stop-Write '書き込み先が読み取れませんでした。' }

    $pathText = [string]$toolInput.file_path
    if ([string]::IsNullOrWhiteSpace($pathText)) { $pathText = [string]$toolInput.notebook_path }

    $baseDir = ConvertTo-FullPath -PathText ([string]$data.cwd) -BaseDir $null
    $target = ConvertTo-FullPath -PathText $pathText -BaseDir $baseDir
    if (-not $target) { Stop-Write ('書き込み先 "' + $pathText + '" を判定できない形です。') }

    # --- 3. 書いてよい場所か -----------------------------------------------------

    $reason = Get-WriteDecision -Root $script:Root -Target $target
    if ($reason) { Stop-Write $reason }
}
catch {
    Stop-Write ('書き込み先を判定する途中でエラーが起きました（' + $_.Exception.Message + '）。')
}

exit 0
