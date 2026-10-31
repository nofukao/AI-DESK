---
name: push前の見直し
description: AI-DESK-DEV（Public リポジトリ）で、git push する前に、これから push するコミットを AI が見直し、問題が無ければ push する。「push して」「push前の見直し」「push してよいか見て」「push の前に確認して」「公開前の確認」と言われたとき、作業を commit・マージして push するとき、pre-push フックに push を止められたと言われたときに使う。実在の固有名詞・業務データ・秘密情報が紛れていないか、開発規則が守られているかを調べ、問題が無ければ見直し済みとして記録してから push する。
---

# push前の見直し

このリポジトリは **Public** です。push したものは、すぐに誰でも見られ、実質的に取り消せません。
push はあなたが行います（`CLAUDE.md` 7）。**その直前に見直して「push してよい／だめ」を判断**し、
問題が無いときだけ push します。

**問題が無いときだけ**、見直したコミットを `.git\info\ai-reviewed` に記録します。
`.git\hooks\pre-push` は、ここに記録されていないコミットの push を止めます。

---

## 0. 道具がそろっているか

| ファイル | 役割 |
|---|---|
| `.git\info\public-check-words.txt` | 探す実在の語。1行1語で、文字どおりに探す（大文字・小文字は区別しない） |
| `.git\info\public-check-regex.txt` | 探す型。1行1つの正規表現 |
| `.git\hooks\pre-push` | `ai-reviewed` に無いコミットの push を止める |

どれも `.git\` の中にあるので、**追跡も push もされません。** clone し直すと消えます。

- **語の一覧と型には、実在の語が入っています。** 追跡されるファイルやコミットメッセージに写さないでください
  （チャットでユーザーに見せるのは構いません）
- **空行とコメントを書かないでください。** `git grep -f` は空行を「何にでも当たる語」として扱います

### 無かったら、作り直す

- **語の一覧と型**: 追跡外の文書（`docs\初期構築プロンプト.md`、`docs\(参考_人間が読むもの)AI-DESK-DEV構築手順書.md`、`_参考\`）から、
  実在の個人名・組織の略称・取引先名・テナント名・実在のタスク名・事業フォルダのパス・ローカルのユーザー名・業態を表す語を拾い、
  **ユーザーに確かめてから**書く。文書が無ければ、ユーザーに聞く
- **フック**: この文書の末尾の「付録」の内容を、`.git\hooks\pre-push` に**改行 LF** で書く

**作り直すまでは、見直しを「済み」にしないでください。**

---

## 1. 範囲を決める

```bash
git fetch origin
git status -sb
```

- push するのは、ふつうは**いまのブランチ**です。ユーザーが別のブランチを言ったら、そちらにします
- 比べる相手（以下 `BASE`）は、そのブランチの upstream（`git rev-parse --abbrev-ref @{upstream}`）。無ければ `origin/main`
- **範囲は `BASE..HEAD`**（まだ GitHub に無いコミット）。空なら「push するものはありません」と伝えて終わります
- `git merge-base --is-ancestor BASE HEAD` が失敗するときは、push が拒否されるか、強制 push が要る状態です。
  **見直しを止めて**、ユーザーに伝えます
- commit していない変更があれば、「これは push されません」と一言添えます

## 2. コミットとファイルの一覧を出す

```bash
git log --format='%h %an <%ae> %s' BASE..HEAD
git diff --name-status BASE HEAD
```

## 3. 機械的に調べる

**範囲のすべてのコミット**を調べます。途中のコミットも push されるからです
（最後の版で消えていても、履歴に残って誰でも見られます）。

```bash
R=$(git rev-list BASE..HEAD)
W=.git/info/public-check-words.txt
X=.git/info/public-check-regex.txt
```

### 3-1. 実在の語（ファイルの中身） — 当たったら「だめ」

```bash
git -c core.quotepath=false grep -n -I -i -F -f $W $R -- .
git -c core.quotepath=false grep -n -I -E -f $X $R -- .
```

### 3-2. 実在の語（コミットメッセージ） — 当たったら「だめ」

```bash
git log --format=%B BASE..HEAD | grep -n -i -F -f $W
git log --format=%B BASE..HEAD | grep -n -E -f $X
```

### 3-3. 作者・コミッターのメール — 公開済みに無いものがあれば、ユーザーに確かめる

```bash
git log --format='%ae%n%ce' BASE..HEAD | sort -u        # これから出るもの
git log --format='%ae%n%ce' origin/main | sort -u       # もう公開されているもの
```

### 3-4. メールアドレス・秘密情報の型（足した行） — 当たったら中身を見て判断

```bash
git diff BASE HEAD | grep -E '^\+[^+]' | grep -n -E \
  -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  -e 'sk-[A-Za-z0-9]{10}|ghp_|gho_|github_pat_|AKIA[0-9A-Z]{12}|xox[bp]-|-----BEGIN' \
  -e '(api[_-]?key|password|passwd|secret|token)[[:space:]]*[:=]' \
  -e '[0-9]{2,4}-[0-9]{2,4}-[0-9]{4}|〒'
```

### 3-5. 業務ファイル — あれば「だめ」（ユーザーに確かめる）

足したファイルに、`.xlsx` `.xls` `.docx` `.doc` `.pptx` `.pdf` `.jtd` `.exe` や、1MB を超えるものが無いか。

```bash
git diff --name-status --diff-filter=A BASE HEAD
```

### 3-6. 文字コード — 違っていたら直す

変わったファイルの先頭3バイト（`head -c 3 <file> | od -An -tx1`）を見ます。

- `.ps1` は `ef bb bf`（BOM 付き）であること
- `.md` `.txt` `.json` `.py` `.gitignore` は `ef bb bf` で**ない**こと

### 3-7. 版番号 — 片方だけなら直す

`AI-DESK/.ai-desk/VERSION` と `CHANGELOG.md` の、**片方だけ**が変わっていないか。
両方変わっていれば、番号が一致しているか（`CLAUDE.md` 6）。

### 3-8. 配布物の追跡漏れ — あればユーザーに確かめる

```bash
git status --ignored --porcelain AI-DESK/
```

`!!` の行に、配布するつもりのファイルが無いか（`.gitignore` の `!` 行の足し忘れ。`CLAUDE.md` 4）。

## 4. 目で読む

```bash
git diff BASE HEAD
```

3 で見つけられるのは、**一覧にある語だけ**です。差分を最初から最後まで読み、次を探してください。

- 一覧に無い実在の名前（新しい取引先・人・物件・タスク名）、実在の事業フォルダのパス
- 業務データそのもの（金額・契約条件・議事録の中身など）
- 社内だけで通じる情報（社内のサーバー名・URL など）
- 例として書いた名前・パスが、架空のもの（`山田太郎`、`yamada`、`株式会社サンプル商事`、`\\サーバー\共有` など）になっているか

新しい実在の語を見つけたら、**ユーザーに確かめてから** `public-check-words.txt` に1行足します。

## 5. 結論を出す

- **問題が無い** → 6. へ進みます
- **問題がある** → **push しません。** 最初の1行で「push してはいけない」と言い、
  当たった場所（コミット、`ファイル:行`）と、直し方の案を示します
- **公開してよいか迷うものがある** → push せずに、ユーザーに聞きます

**だめなときは、自分で直さないでください。** まだ push していないコミットを直すには、
履歴の書き換え（`--amend`、`rebase`）が要ることがあります。直し方をユーザーと決めてからにします。

## 6. 問題が無いときだけ、記録して push する

```bash
git rev-parse HEAD >> .git/info/ai-reviewed
git push              # upstream が無いブランチは git push -u origin <ブランチ>
git status -sb        # GitHub と一致したか
```

- **`--force`（`-f`）と `--no-verify` は使いません。** push が拒否されたら、そこで止めてユーザーに伝えます
- **ユーザーが見直しだけを頼んだとき**（「push してよいか見て」など）は、push せずに「push してよい」と伝えます
- 報告は、**最初の1行で結論**（push した／しなかった）を言い、範囲（ブランチ、コミット数）、
  ファイルの一覧、3 と 4 で見たことを続けます
- 記録したあとにコミットを足したり直したりすると HEAD が変わり、push はまた止まります。そのときは見直し直します
- **main にマージしてから push する場合は、マージしたあとに見直します。** マージで新しいコミットができるためです

---

## 付録: `.git\hooks\pre-push`

改行は **LF** で書きます（CRLF だと動かないことがあります）。

```sh
#!/bin/sh
# AI-DESK-DEV: AI が見直したコミットでなければ、push を止める。
#
# 見直しの記録は .git/info/ai-reviewed（「push前の見直し」スキルが、問題なしのときに書く）。
# このファイルは追跡されない。clone し直したら、スキルの手順で作り直す。
# 急ぐときは git push --no-verify で通せる。

reviewed="$(git rev-parse --git-dir)/info/ai-reviewed"
zero=0000000000000000000000000000000000000000

while read local_ref local_sha remote_ref remote_sha; do
  # ブランチの削除は、見直し不要
  [ "$local_sha" = "$zero" ] && continue

  if [ -f "$reviewed" ] && tr -d '\r' < "$reviewed" | grep -qx "$local_sha"; then
    continue
  fi

  short=$(git rev-parse --short "$local_sha")
  echo "" >&2
  echo "pre-push: BLOCKED - $local_ref ($short) has not been reviewed by AI." >&2
  echo "push を止めました: $local_ref（$short）は、AI の見直しが済んでいません。" >&2
  echo "Claude Code で「push前の見直し」と言い、問題なしと報告されてから push してください。" >&2
  echo "（急ぐときは git push --no-verify で通せます）" >&2
  exit 1
done
exit 0
```
