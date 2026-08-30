# ccs — Claude Code セッションを tmux で立てる薄いラッパー

ハブ 1 本から、tmux 上に複数の Claude Code セッションを立て・見つけ・畳むための CLI。

**v1 のコマンドが揃い、常時稼働のハブ（`ccs hub`）が入った。**
→ **[ドキュメント](https://ken-ty.github.io/ccs/)** / [チュートリアル](docs/tutorial.md) / [hub](docs/hub.md) / [設定](docs/configuration.md) / [設計調査](docs/design.md)

```bash
git clone git@github.com:ken-ty/ccs.git ~/ghq/github.com/ken-ty/ccs
cd ~/ghq/github.com/ken-ty/ccs && make install
```

`make install` は `~/.local/share/ccs/versions/<版>` に置いて `~/.local/bin/ccs` を
そこへ向ける（同じマシンの `claude` と同じ形）。**PATH の `ccs` が git の作業ツリーを
指さない**のが要点 ── 指していると、走るコードは checkout の HEAD 次第で勝手に変わる。
以降は `ccs hub up` の鼓動に相乗りして自動で最新に追従する。
→ [版と更新](docs/versioning.md)

## なぜ要るのか

**素の Claude Code セッションに「新しいセッションを立てて」と頼んでも、素直には通らない。**
セッションのツールから起動したプロセスには pty が無く、対話モードの `claude` は
黙って `--print` に落ちて即死する。組み込みの `SendMessage` は既存セッション宛にしか送れず、
`Agent` ツールはサブエージェントであって独立したセッションではない。

手で tmux を叩けば立つ。ただし **trust ダイアログで固まり、`cc/` を付け忘れると
`ccs ls` からも `kill` からも漏れ、冪等でない**。`ccs` が変えるのは「立つ」ではなく
**「毎回同じ形で立ち、立った後も管理下に残る」**こと。

実測と、tmux・CLI という選択の理由は **[なぜ ccs が要るのか](docs/why.md)** に置いた。

## なぜ薄いのか

セッション管理でやりたいことの大半は、Claude Code 2.1.x が既に持っている
（[実測](docs/design.md#2-実測でわかったこと証拠つき)）。

| やりたいこと | 担当 |
| --- | --- |
| 全セッションの一覧・状態 | `claude agents --json`（組み込み） |
| ハブ → 子セッションへの指示 | `ListAgents` / `SendMessage`（組み込みツール） |
| tmux ペインとの対応づけ | Claude 自身が記録する（`~/.claude/sessions/<pid>.json`） |
| セッション ID の固定 | `claude --session-id <uuid>`（組み込み） |
| skills が見えること | `~/.claude/skills` がユーザレベルなので cwd に依らない |
| **セッションの新規作成** | **ccs** |
| **workspace trust ダイアログの回避** | **ccs** |
| **ghq / 一時ディレクトリの解決** | **ccs** |
| **命名規約と後片付け** | **ccs** |

**`ccs` が持つのは下 4 つだけ。** 一覧・通信・状態は組み込みに委譲する。
既存の tmux オーケストレータを持ってくると、いま組み込みになった部分まで二重に抱えることになる。

## 想定する使い方

```
ccs new <target> [-- <初期プロンプト>]   # target: リポジトリ名 | ghq パス
ccs new --tmp [-- <初期プロンプト>]      # 使い捨ての作業枠（"tmp" は短い綴り）
ccs ls [--json]                          # cc/ 接頭辞のセッションだけを整形して出す
ccs ls -l [--json]                       # 盤面（直近の依頼 / RSS / 最終更新）も出す
ccs agents [-l] [--json]                 # このマシンの claude を俯瞰（管轄外は SLUG が -）
ccs attach [<slug>]                      # 人間が乗り込む（slug を省くと番号で選ぶ）
ccs adopt <target> [--pid <pid>]         # ccs 管轄外のセッションを引き取る
ccs kill <slug>                          # ペインごと畳む
ccs kill --self                          # そのセッション自身を畳む（中から打つ。ccs 管轄外からも）
ccs gc                                   # 死んだペイン・空の一時ディレクトリ・不要な worktree を掃除
ccs restore [--yes] [<slug>...]          # 止まった／消えたセッションを同じ会話で立て直す
ccs restore --last [--yes]               # 前回の停止まで生きていた組だけを戻す

ccs hub up                               # ハブを立てる（生きていれば何もしない）
ccs hub status [--json]                  # ハブの状態（終了コードで分岐できる）
ccs hub restart [--resume]               # ハブを立て直す
ccs hub down                             # ハブを止める（自動起動も止まる）
ccs hub agent [--print]                  # 自動起動（launchd / systemd）の設定

ccs resolve <target> [--json]            # <target> がどこに解決されるかを見る
ccs config [--json]                      # 効いている設定と、その出どころ
ccs version [--short]                    # どの版が走っているか（コミットまで出る）
ccs doctor                               # 何の版が入っていて、最新か
```

`resolve` は副作用を持たない（使い捨て枠の確保を除く）。**立てる前に、どのリポジトリの
どのパスに当たるかを確かめられる**:

```console
$ ccs resolve x01
x01	/Users/apple/ghq/github.com/ken-ty/x01

$ ccs resolve IceCubesApp
ccs: IceCubesApp に当てはまるリポジトリが複数あります:

  Dimillian/IceCubesApp
  ken-ty/IceCubesApp

<owner>/<repo> の形で指定し直してください。
```

> **制約**: `ccs` のセッションは tmux が pty を持つため、**Claude アプリからは端末の画面が見えない**。
> `ccs attach` は同じマシンのターミナルからしか使えない。
> 詳細と回避策は [なぜ ccs が要るのか §4](docs/why.md#その独立には代償がある--アプリからターミナルが見えない)、
> 追跡は [#19](https://github.com/ken-ty/ccs/issues/19)。

ハブ（Remote Control を張ったセッション）から `ccs new` で立て、あとは組み込みの
[`SendMessage`](docs/agent-tools.md#sendmessage) で指示し、
[`ListAgents`](docs/agent-tools.md#listagents) で状態を見る。ターミナルを閉じても
tmux が残すので、セッションは生き続ける。

`ccs new` は 1 行の JSON を返す:

```console
$ ccs new agent-skills
{"slug":"agent-skills","sessionId":"92e3a7c8-…","path":"/Users/apple/ghq/github.com/ken-ty/agent-skills","tmux":"cc/agent-skills","transcript":"/Users/apple/.claude/projects/-Users-…/92e3a7c8-….jsonl","created":true}
```

立った直後から、ハブの `ListAgents` に `<slug>` として現れる（実機で確認済み）。
打ち方と `ccs ls` との使い分けは [docs/agent-tools.md](docs/agent-tools.md)。

> `transcript` は**予測したパス**で、この時点ではまだファイルが無い。本物は最初の
> やり取りが発生してから `.jsonl` を作る。

## ハブを常時立てておく

スマホや別のマシンから触るなら、**ハブ 1 本が常に生きていること**が前提になる。
アプリから届くのは生きているセッションだけなので、ハブが死ぬと `ccs` を叩く
経路ごと消える。

**推奨の初期設定は「ログイン時 + 5 分ごと」。** hub を使うなら、立てたその日に
自動起動も入れる。

```console
$ ccs hub up
{"slug":"hub","state":"healthy","sessionId":"…","tmux":"cc/hub","bridge":"session_…","created":true}

$ ccs hub agent --print > ~/Library/LaunchAgents/local.ccs.hub.plist
$ launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ccs.hub.plist

$ launchctl list | grep ccs        # 入ったか確かめる（3 つとも見る）
$ ccs hub status                   # healthy
$ ccs ls                           # hub が 1 本だけ
```

`ccs hub up` は冪等（生きていれば何もしない）なので、定期実行するだけで
死活監視になる。落ちていれば立て直し、**認証切れと再起動の暴走は自動で直さず
人を待つ**。

**5 分ごとでも負荷にならない** ── healthy なときの `ccs hub up` は claude を
起動せず、tmux とレジストリのファイルを見るだけで終わる（実測 0.06 秒）。
逆に「起動時 1 回だけ」にすると、クラッシュ・Remote Control の脱落・context
溢れで日中に落ちたときが戻らない。Linux（systemd）の手順、間隔の変え方、
外し方は [docs/hub.md](docs/hub.md#常時起動推奨の初期設定)。

`ccs kill` と `ccs gc` はハブを対象にしない。ハブを畳むのは `ccs hub down`、
作り直すのは `ccs hub restart`。

## 再起動のあとに戻す

再起動すると tmux サーバごと消える。ハブは自動起動で戻るが、**他のセッションは
誰も立て直さない。** 会話自体は `~/.claude/projects/**.jsonl` に残っているので、
同じ場所で `claude --resume <uuid>` を立てれば同じ会話に戻る。

```console
$ ccs restore                # 戻せるものを見せる（既定。何もしない）
立て直せるセッション:
  tmp-1   2026-08-22 13:45  caf95a3f-...  ドキュメント整理
  tmp-2   2026-08-22 13:45  c56885d3-...  設計メモ

実行するには: ccs restore --yes
```

拾うのは **`ccs` が立てたと分かるものだけ**（作業枠・worktree・止まったペイン・
ghq 配下で**印のある**会話）。印は「会話ログの 1 行目が `custom-title`」で、
`ccs new` が `-n <slug>` を渡すことに由来する ── デスクトップアプリや VS Code の
会話は同じ場所に溜まるが、この印が付かないので拾わない。**`ccs hub up` は restore を
しない**（自動起動から 5 分おきに走るので、人が畳んだものが生き返ってしまう）。

候補には「一緒に落ちた組」と「それ以前からの残骸」が混ざる。**前者だけに絞るのが
`--last`。**

```console
$ ccs restore --last          # 前回の停止まで生きていた組だけ（既定は dry-run）
$ ccs restore --last --yes    # 戻す
```

根拠は会話ログの mtime。**OS のシャットダウンは生きている `claude` に SIGTERM を
送り、`claude` はそこで会話ログを書き切る**ので、丸 1 日アイドルだったセッションも
停止の瞬間の mtime を持つ（実測）。手で畳んだものはその瞬間に書き込みが止まるので、
塊に乗らない。塊の切り出しには起動時刻（`kern.boottime` / `/proc/stat`）を基準点に使う。

詳細は [docs/restore.md](docs/restore.md)。

## 自分の環境に合わせる

既定値は作者の環境に合わせてある。**困るところは設定で変えられる。**

```sh
# ~/.config/ccs/config
CCS_HUB_SLUG=orchestrator   # hub という名前のリポジトリを持っている
CCS_HUB_AUTOSTART=off       # 自動起動は入れない
CCS_REMOTE_CONTROL=off      # Remote Control を使わない
```

`env > 設定ファイル > 既定値` の順で効く。いま効いている値と出どころは
`ccs config`、キーの一覧は [docs/configuration.md](docs/configuration.md)。

**ghq には依存する**（リポジトリ名から場所を引く部分）。使っていない環境では
パスで渡せばよい。

## 要件

- `tmux`
- `jq` — `claude agents --json` を読むため
- `claude` 2.1.x 以降 — `--session-id` と `claude agents --json` に依存する
- macOS / Linux。**Windows は対象外**（POSIX sh 前提）

## 範囲

`new` / `ls` / `attach` / `kill` / `gc` / `restore` / `resolve` / `config` と、`hub` 一式。
`restore` と worktree 対応は v1 の範囲外だったが、どちらも実機で詰まったので後から入れた
（[docs/design.md §6](docs/design.md#6-決定事項2026-08-17) の「v1 の範囲」と
[§10](docs/design.md#10-restore止まったセッションの立て直し2026-08-22-決定)）。

## 版

`0.0.x`。**破壊的変更を予告なく入れる。** タグもリリースも発行していない。
決まったことは [ADR](docs/adr/) にある。

## ドキュメント

```bash
make docs        # 手元で配信する（uvx 経由なので事前の pip install は要らない）
make docs-build  # 静的ビルド
```

公開先は **<https://ken-ty.github.io/ccs/>**。`main` の `docs/` 以下が変わると
[docs ワークフロー](.github/workflows/docs.yml)がビルドしてデプロイする。

## 関連

- [hub の運用](docs/hub.md) / [設定](docs/configuration.md) / [版と更新](docs/versioning.md)
- スキル側（ハブがいつ・どう呼ぶかの判断）は `agent-skills-store` の `cross-session-hub`
- 調査で参照した資料は [docs/references.md](docs/references.md)

## ライセンス

[MIT](LICENSE)。
