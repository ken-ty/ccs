# ccs — Claude Code セッションを tmux で立てる薄いラッパー

ハブ 1 本から、tmux 上に複数の Claude Code セッションを立て・見つけ・畳むための CLI。

**現在は設計のみ。実装はまだ無い。** → [docs/design.md](docs/design.md)

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
ccs new <target> [-- <初期プロンプト>]   # target: リポジトリ名 | ghq パス | "tmp"
ccs ls [--json]                          # cc/ 接頭辞のセッションだけを整形して出す
ccs attach <slug>                        # 人間が乗り込む
ccs kill <slug>                          # ペインごと畳む
ccs gc                                   # 死んだペイン・空の一時ディレクトリを掃除

ccs resolve <target> [--json]            # <target> がどこに解決されるかを見る
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

ハブ（Remote Control を張ったセッション）から `ccs new` で立て、あとは組み込みの
`SendMessage` で指示し、`ListAgents` で状態を見る。ターミナルを閉じても tmux が残すので、
セッションは生き続ける。

## 要件

- `tmux`
- `jq` — `claude agents --json` を読むため
- `claude` 2.1.x 以降 — `--session-id` と `claude agents --json` に依存する
- macOS / Linux。**Windows は対象外**（POSIX sh 前提）

## v1 の範囲

段取り 1〜3（`new` / `ls` / `attach` / `kill` / `gc`、一時ディレクトリの固定枠、
`cross-session-hub` スキルの改訂）まで。`resume` と worktree 対応は v1 に含めない。
理由と派生する縛りは [docs/design.md §6](docs/design.md#6-決定事項2026-08-17)。

## 関連

- スキル側（ハブがいつ・どう呼ぶかの判断）は `agent-skills-store` の `cross-session-hub`
- 調査で参照した資料は [docs/references.md](docs/references.md)
