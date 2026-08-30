# ccs

ハブ 1 本から、tmux 上に複数の Claude Code セッションを立て・見つけ・畳むための CLI。

## これは何を解くのか

Claude Code のセッションを増やしたいとき、これまでは**人がターミナルを開いて `claude` を打つ**
必要があった。セッションの中にいるエージェントからは新しいセッションを開けない。

`ccs` はそこだけを埋める。ハブ（Remote Control を張った 1 本）から `ccs new` を呼べば、
tmux の上に新しいセッションが立ち、**そのままハブの
[`ListAgents`](agent-tools.md#listagents) に現れて指示を送れる**。
ターミナルを閉じても tmux が残すので、セッションは生き続ける。

詳しくは **[なぜ ccs が要るのか](why.md)** — 素のセッションで何が起きないかの実測と、
tmux・CLI を選んだ理由。

## 薄い

セッション管理でやりたいことの大半は、Claude Code 2.1.x が既に持っている
（[実測](design.md#2-実測でわかったこと証拠つき)）。

| やりたいこと | 担当 |
| --- | --- |
| 全セッションの一覧・状態 | `claude agents --json`（組み込み） |
| ハブ → 子セッションへの指示 | [`ListAgents` / `SendMessage`](agent-tools.md)（組み込みツール） |
| tmux ペインとの対応づけ | Claude 自身が記録する |
| セッション ID の固定 | `claude --session-id <uuid>`（組み込み） |
| skills が見えること | `~/.claude/skills` がユーザレベルなので cwd に依らない |
| **セッションの新規作成** | **ccs** |
| **workspace trust ダイアログの回避** | **ccs** |
| **ghq / 一時ディレクトリの解決** | **ccs** |
| **命名規約と後片付け** | **ccs** |

**`ccs` が持つのは下 4 つだけ。**

## コマンド

| | |
| --- | --- |
| `ccs new <target> [-- <初期プロンプト>]` | セッションを立てる |
| `ccs ls [--json]` | 立っているものを一覧する |
| [`ccs ls -l [--json]`](board.md) | 盤面 ── 直近の依頼 / RSS / 最終更新も出す |
| `ccs attach [<slug>]` | 乗り込む（slug を省くと番号で選ぶ） |
| `ccs agents [-l] [--json]` | **このマシンの claude を俯瞰する**（管轄外は SLUG が `-`。`ccs ls` には混ぜない） |
| `ccs adopt <target> [--pid <pid>]` | **ccs 管轄外のセッションを引き取る**（元を閉じ、同じ会話を `cc/<slug>` で開き直す） |
| `ccs kill [--force] <slug>` | 畳む |
| `ccs kill --self [--force]` | そのセッション自身を畳む（アプリのアーカイブでは残るため）。**ccs 管轄外のセッションからも使える** |
| `ccs gc [--yes]` | 止まったセッション・空の作業枠・不要になった worktree を掃除する |
| [`ccs restore [--yes] [--json]`](restore.md) | 止まった／消えたセッションを同じ会話で立て直す |
| `ccs resolve <target> [--json]` | 立てる前に、どこに解決されるかを見る |
| `ccs config [--json]` | 効いている設定と、その出どころを見る |
| [`ccs version [--short]`](versioning.md) | どの版が走っているかを見る（コミットまで） |
| [`ccs doctor`](versioning.md) | 何の版が入っていて、最新かを見る |
| [`ccs hub …`](hub.md) | 常時 1 本のハブを立て、落ちても戻るようにする |

## 手元にいないときのために

スマホから触るなら、**ハブ 1 本が常に生きていること**が前提になる。アプリから
届くのは生きているセッションだけなので、ハブが死ぬと `ccs` を叩く経路ごと消える。

`ccs hub up` は冪等（生きていれば何もしない）なので、launchd / systemd から
定期的に呼ぶだけで死活監視になる。**推奨は「ログイン時 + 5 分ごと」**（既定の
`CCS_HUB_AUTOSTART=on`）── healthy なときは claude を起動せずに 0.06 秒で
終わるので、頻度を落とす利得がない。

```bash
ccs hub up                                                    # まず手で 1 回立てる
ccs hub agent --print > ~/Library/LaunchAgents/local.ccs.hub.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ccs.hub.plist
```

Linux（systemd）の手順、確かめ方、外し方は
**[hub を常時立てる](hub.md#常時起動推奨の初期設定)**。

## 自分の環境に合わせる

既定値は作者の環境に合わせてある。**困るところは設定で変えられる** ──
`hub` という名前のリポジトリを持っているなら hub の名前を、Remote Control を
使わないならその要求を、自動起動が要らないならそれ自体を。

いま効いている値は `ccs config`、キーの一覧は **[設定](configuration.md)**。

!!! warning "`ccs attach` は同じマシンからしか使えない"
    `ccs` のセッションは tmux が pty を持つため、**Claude アプリからは端末の画面が見えない**。
    外出先でアプリしか持っていない状況では端末に届かない。
    事情と回避策は [なぜ ccs が要るのか §4](why.md#その独立には代償がある--アプリからターミナルが見えない)、
    追跡は [#19](https://github.com/ken-ty/ccs/issues/19)。

## 要件

- `tmux`
- `jq`
- `claude` 2.1.x 以降（`--session-id` と `claude agents --json` に依存する）
- macOS / Linux。**Windows は対象外**（POSIX sh 前提）

## この先

- [はじめてのセッション](tutorial.md) — 入れて、立てて、畳むまで（実機の画面つき）
- [hub を常時立てる](hub.md) — 手元にいないときの入口を、落ちても戻る形にする
- [設定](configuration.md) — 名前・置き場所・自動起動を自分の環境に合わせる
- [ハブの組み込みツール](agent-tools.md) — 立てたあと、どう指示を送るか
- [手を動かして確かめる](hands-on.md) — 自分の目で 1 周する手順
- [設計調査](design.md) — なぜこの形なのか。実測の証拠つき
- [決定記録 (ADR)](adr/README.md) — 何を決めて、何を捨てたか。覆った決定もここに残る
- [参照資料](references.md) — 調査で当たったもの
