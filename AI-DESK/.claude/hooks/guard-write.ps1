#Requires -Version 5.1
<#
  guard-write.ps1  --  AI が書き込める場所を、決まった場所だけに限る

  Claude Code の hook（PreToolUse）として、.claude\settings.json から呼ばれます。
  AI がファイルを書く直前（Edit / Write / NotebookEdit）に書き込み先を調べ、
  次のどれにも当たらなければ、その書き込みを止めます。

    <インスタンスのルート>\<タスクフォルダ>\out\ の中
    <インスタンスのルート>\PROFILE.md
    <インスタンスのルート>\.claude\skills\ の中

  インスタンスのルートは、このスクリプトの2つ上のフォルダです（.ai-desk\VERSION があること）。
  タスクフォルダは、ルート直下のフォルダのうち、次を除いたものです。
    名前が . で始まるもの（.claude、.ai-desk など） / bin / task_template / out

  止め方: 理由を標準エラーと標準出力（JSON）に書き、終了コード 2 で終わります。
  書き込み先を判定できないとき、このスクリプトの中でエラーが起きたときも、止める側に倒します。

  限界（Claude Code の仕様によるもの）:
    - PowerShell が起動できない、時間切れになった、といった場合は、書き込みは止まりません
    - 見張れるのは、AI が直接書くファイルだけです。
      シェルのコマンドや、Python などのプログラムが書くファイルは見張れません

  このスクリプトは、ファイルの作成・変更・削除を一切行いません。
  配布物です。インスタンスの中で直さないでください（次の更新で上書きされます）。
#>

$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Root = $null

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
        ' 書けるのは、この AI-DESK（' + $rootText + '）の「<タスクフォルダ>\out\ の中」「PROFILE.md」' +
        '「.claude\skills\ の中」だけです。' +
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

    # --- 3. 書いてよい場所か ---------------------------------------------------

    $prefix = $script:Root + '\'
    if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Write ('書き込み先 ' + $target + ' は、この AI-DESK の外です。')
    }

    $parts = @($target.Substring($prefix.Length).Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { Stop-Write ('書き込み先 ' + $target + ' は、ファイルではありません。') }

    $first = $parts[0]
    $isTaskFolder = -not ($first.StartsWith('.') -or ($first -ieq 'bin') -or
                          ($first -ieq 'task_template') -or ($first -ieq 'out'))

    $allowed = (($parts.Count -eq 1) -and ($first -ieq 'PROFILE.md')) -or
               (($parts.Count -ge 3) -and ($first -ieq '.claude') -and ($parts[1] -ieq 'skills')) -or
               (($parts.Count -ge 3) -and $isTaskFolder -and ($parts[1] -ieq 'out'))

    if (-not $allowed) {
        Stop-Write ('書き込み先 ' + $target + ' は、書いてよい場所ではありません。')
    }

    # --- 4. 途中に、別の場所へのリンクが無いか -----------------------------------
    #
    # out の中にジャンクションやシンボリックリンクがあると、見た目は out の中でも、
    # 実際には別の場所（資料フォルダなど）に書き込まれるためです。

    $current = $script:Root
    foreach ($part in $parts) {
        $current = [System.IO.Path]::Combine($current, $part)
        if (-not ([System.IO.Directory]::Exists($current) -or [System.IO.File]::Exists($current))) { break }
        $item = Get-Item -LiteralPath $current -Force
        if ($item.LinkType) {
            Stop-Write ('書き込み先の途中に、別の場所へのリンク（' + $item.LinkType + '）があります: ' + $current)
        }
    }
}
catch {
    Stop-Write ('書き込み先を判定する途中でエラーが起きました（' + $_.Exception.Message + '）。')
}

exit 0
