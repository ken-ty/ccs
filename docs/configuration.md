# 設定

`ccs` の既定値は「作者の環境」に合わせてある。**他の環境で困るところは全部
設定で変えられる。**

```console
$ ccs config
KEY                      VALUE                                    SOURCE
CCS_PREFIX               cc/                                      default
CCS_CLAUDE_BIN           claude                                   default
…
CCS_HUB_SLUG             orchestrator                             config
CCS_HUB_AUTOSTART        off                                      env
…

設定ファイル: ~/.config/ccs/config
env > 設定ファイル > 既定値 の順で効きます。
```

`SOURCE` の列があるのは、**「設定したのに効かない」を自力で切り分けられる
ようにする**ため。`ccs config --json` なら機械可読に出る。

## 優先順位

**env > 設定ファイル > 既定値。**

環境変数が設定ファイルに勝つので、「一時的にこれだけ変えて試す」が成立する。

```console
$ CCS_HUB_SLUG=試作 ccs hub status   # この 1 回だけ別の hub を見る
```

## 設定ファイル

置き場所は `${XDG_CONFIG_HOME:-~/.config}/ccs/config`（`CCS_CONFIG_FILE` で移動できる）。

```sh
# ~/.config/ccs/config

CCS_HUB_SLUG=orchestrator     # hub という名前のリポジトリを持っているので変えた
CCS_HUB_HOME=~/work/hub       # 先頭の ~/ はホームに展開される
CCS_HUB_AUTOSTART=login       # ログイン時だけ立てる
CCS_SCRATCH_SLOTS=4           # 使い捨て枠は 4 本で足りる
```

- `KEY=VALUE` を 1 行に 1 つ。前後の空白は無視する
- `#` から行末はコメント（**値に `#` は書けない**）
- 値のクォート（`"…"` / `'…'`）は外される
- 値の先頭の `~/` はホームに展開される
- **知らないキーは黙って無視せず警告する**（綴り間違いに気づけるように）

!!! warning "設定ファイルはシェルとして実行されない"
    `source` する作りにしていない。設定ファイルに任意のコマンドを書けると、
    設定と実行の境界が無くなるため。`CCS_HUB_HOME=$(pwd)` と書いても、
    その文字列がそのまま入るだけ。

## よく変えるもの

| キー | 既定 | 何のために変えるか |
| --- | --- | --- |
| `CCS_HUB_SLUG` | `hub` | **`hub` という名前のリポジトリを持っているとき。** 予約語がぶつかる |
| `CCS_HUB_HOME` | `~/.cc-hub` | ホーム直下に増やしたくないとき |
| `CCS_HUB_AUTOSTART` | `on` | 自動起動を `login` だけにする / 入れない（`off`） |
| `CCS_HUB_AGENT_INTERVAL` | `300` | 監視の間隔（秒） |
| `CCS_HUB_AGENT_LABEL` | `local.ccs.hub` | launchd のラベル。組織の命名規約に合わせるとき |
| `CCS_REMOTE_CONTROL` | `auto` | Remote Control を使わない環境では `off`、全セッションに付けたいなら `on` |
| `CCS_PREFIX` | `cc/` | 既に `cc/` を別の用途で使っているとき |
| `CCS_SCRATCH_ROOT` | `~/.cc-scratch` | 使い捨て作業枠の置き場所 |
| `CCS_WORKTREE_ROOT` | `~/.cc-worktrees` | `ccs new <repo>@<branch>` が切る worktree の置き場所。**ghq root の外に置くこと**（`ghq list` が worktree をリポジトリとして拾い、名前解決が誤爆する） |
| `CCS_SCRATCH_SLOTS` | `8` | 使い捨て枠の本数。**有限であること自体が歯止め** |

### `hub` という名前のリポジトリを持っている場合

`ccs new hub` は hub の予約語とぶつかる。ccs は**勝手に選ばず**止まる。

```console
$ ccs new hub
ccs: hub は hub を指す予約語です。

  hub を立てる:           ccs hub up
  同名のリポジトリを開く: ccs new <owner>/hub
  hub の名前を変える:     設定ファイルに CCS_HUB_SLUG=<別名>
```

`<owner>/hub` で開いたときの slug は `<owner>-hub` になる。`cc/hub` は hub の
ものなので、他のリポジトリには使わせない ── 使わせると、立てた瞬間に hub の
生死判定が壊れる。

### Remote Control を使わない場合

`CCS_REMOTE_CONTROL=off` にする。`--remote-control` を渡さなくなり、hub の
生死判定も RC を要求しなくなる。**off にしないと、RC が付かない環境では
`no-rc` と判定して永久に立て直し続ける。**

## 待ち時間と歯止め

| キー | 既定 | 意味 |
| --- | --- | --- |
| `CCS_NEW_TIMEOUT` | `30` | 起動してからレジストリに載るまで待つ秒数 |
| `CCS_HUB_RC_TIMEOUT` | `45` | Remote Control の登録が付くまで待つ秒数 |
| `CCS_HUB_BACKOFF_WINDOW` | `600` | 再起動の暴走を見る窓（秒） |
| `CCS_HUB_BACKOFF_MAX` | `3` | その窓で許す再起動の回数 |

## 差し替え点（テストと特殊な環境向け）

| キー | 既定 |
| --- | --- |
| `CCS_CLAUDE_BIN` | `claude` |
| `CCS_TMUX_BIN` | `tmux` |
| `CCS_GHQ_BIN` | `ghq` |
| `CCS_GIT_BIN` | `git` |
| `CCS_JQ_BIN` | `jq` |
| `CCS_SESSIONS_DIR` | `~/.claude/sessions` |
| `CCS_TRUST_FILE` | `~/.claude.json` |
| `CCS_PROJECTS_DIR` | `~/.claude/projects` |

テストはここを差し替えることで、本物の `claude` を起動せず、本物の
`~/.claude.json` を書き換えずに済ませている。**新しく外部コマンドや外部パスに
触るときは、必ず差し替え点を足してから使う**（`AGENTS.md`）。

## 前提として変えないもの

- **ghq に依存する。** リポジトリ名から場所を引く部分は `ghq list` に任せている。
  ghq を使っていない環境では、`ccs new <path>` のようにパスで渡す
  （パス指定は ghq が無くても動く）
- **tmux と jq は必須。** 無ければ起動時に落として、入れ方を出す
