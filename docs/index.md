# ccs

ハブ 1 本から、tmux 上に複数の Claude Code セッションを立て・見つけ・畳むための CLI。

## これは何を解くのか

Claude Code のセッションを増やしたいとき、これまでは**人がターミナルを開いて `claude` を打つ**
必要があった。セッションの中にいるエージェントからは新しいセッションを開けない。

`ccs` はそこだけを埋める。ハブ（Remote Control を張った 1 本）から `ccs new` を呼べば、
tmux の上に新しいセッションが立ち、**そのままハブの `ListAgents` に現れて指示を送れる**。
ターミナルを閉じても tmux が残すので、セッションは生き続ける。

## 薄い

セッション管理でやりたいことの大半は、Claude Code 2.1.x が既に持っている
（[実測](design.md#2-実測でわかったこと証拠つき)）。

| やりたいこと | 担当 |
| --- | --- |
| 全セッションの一覧・状態 | `claude agents --json`（組み込み） |
| ハブ → 子セッションへの指示 | `ListAgents` / `SendMessage`（組み込みツール） |
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
| `ccs attach <slug>` | 乗り込む |
| `ccs kill [--force] <slug>` | 畳む |
| `ccs gc [--yes]` | 止まったセッションと空の作業枠を掃除する |
| `ccs resolve <target> [--json]` | 立てる前に、どこに解決されるかを見る |

## 要件

- `tmux`
- `jq`
- `claude` 2.1.x 以降（`--session-id` と `claude agents --json` に依存する）
- macOS / Linux。**Windows は対象外**（POSIX sh 前提）

## この先

- [はじめてのセッション](tutorial.md) — 入れて、立てて、畳むまで（実機の画面つき）
- [手を動かして確かめる](hands-on.md) — 自分の目で 1 周する手順
- [設計調査](design.md) — なぜこの形なのか。実測の証拠つき
- [参照資料](references.md) — 調査で当たったもの
