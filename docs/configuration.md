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
| `CCS_HUB_AUTOSTART` | `on` | 自動起動を `login` だけにする / 入れない（`off`）。**既定の `on`（ログイン時 + 5 分ごと）が推奨** |
| `CCS_HUB_AGENT_INTERVAL` | `300` | 監視の間隔（秒）。**短くても負荷にならない** ── healthy なときの `ccs hub up` は claude を起動せず 0.06 秒で終わる |
| `CCS_HUB_AGENT_LABEL` | `local.ccs.hub` | launchd のラベル。組織の命名規約に合わせるとき |
| `CCS_REMOTE_CONTROL` | `auto` | Remote Control を使わない環境では `off`、全セッションに付けたいなら `on` |
| `CCS_PREFIX` | `cc/` | 既に `cc/` を別の用途で使っているとき |
| `CCS_SCRATCH_ROOT` | `~/.cc-scratch` | 使い捨て作業枠の置き場所 |
| `CCS_SCRATCH_SLOTS` | `8` | 使い捨て枠の本数。**有限であること自体が歯止め** |
| `CCS_RESTORE_MAX_AGE` | `7` | `ccs restore` が黙って拾う会話ログの古さの上限（日）。`0` で無制限。**列挙にだけ効く**（名指しは古くても戻す） |
| `CCS_RESTORE_LAST_WINDOW` | `300` | `ccs restore --last` が「一緒に落ちた組」とみなす幅（秒）。**停止は一瞬ではない**（実測で 13 本が 45 秒ばらけた）。広げると手で畳んだものを巻き込み、狭めると取りこぼす |
| `CCS_RESTORE_BOOT_EPOCH` | （空） | 起動時刻（epoch 秒）。空なら OS に訊く（`kern.boottime` / `/proc/stat`）。**読めない環境のための逃げ道**であり、テストが再起動を模す差し替え点でもある |

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

### 自動起動の間隔を変える場合

**ユニットを出し直して入れ直すまで効かない。** `ccs hub agent` は値を
plist / timer に焼き込むので、設定ファイルや env を変えただけでは、既に置いた
ユニットは変わらない。手順は [hub §常時起動](hub.md#間隔を変える)。

### Remote Control を使わない場合

`CCS_REMOTE_CONTROL=off` にする。`--remote-control` を渡さなくなり、hub の
生死判定も RC を要求しなくなる。**off にしないと、RC が付かない環境では
`no-rc` と判定して永久に立て直し続ける。**

## 待ち時間と歯止め

| キー | 既定 | 意味 |
| --- | --- | --- |
| `CCS_NEW_TIMEOUT` | `30` | 起動してからレジストリに載るまで待つ秒数 |
| `CCS_ADOPT_TIMEOUT` | `20` | `ccs adopt` が、元のセッションが終わるのを待つ秒数。待ちきれなくても**何もしない**（元は生きたまま）ので長めでよい |
| `CCS_HUB_RC_TIMEOUT` | `45` | Remote Control の登録が付くまで待つ秒数 |
| `CCS_HUB_BACKOFF_WINDOW` | `600` | 再起動の暴走を見る窓（秒） |
| `CCS_HUB_BACKOFF_MAX` | `3` | その窓で許す再起動の回数 |

## 版と更新

置き場所と、自動更新の振る舞い。詳しくは **[版と更新](versioning.md)**。

| キー | 既定 | 何を変えるか |
| --- | --- | --- |
| `CCS_INSTALL_ROOT` | `~/.local/share/ccs` | 版の置き場所（`versions/` と記録がここに入る） |
| `CCS_BIN_DIR` | `~/.local/bin` | symlink を置く場所。**PATH が通っているところ**にする |
| `CCS_AUTO_UPDATE` | `on` | `off` にすると自動では切り替えず、**検知して報告するだけ**になる |
| `CCS_UPDATE_INTERVAL` | `3600` | 検知でネットワークを使う間隔（秒）。`hub up` は 5 分ごとに走るが、fetch はこの間隔に 1 回 |
| `CCS_KEEP_VERSIONS` | `5` | 残す版の数。**2 未満にはならない** ── 巻き戻し先が消えては困る |

### 自動更新を止める場合

無人で切り替わるのが困る環境では `off` にする。検知そのものは続くので、
古くなったことは `ccs doctor` と `hub.log` に出る。

```
CCS_AUTO_UPDATE=off
```

## 差し替え点（テストと特殊な環境向け）

| キー | 既定 |
| --- | --- |
| `CCS_CLAUDE_BIN` | `claude` |
| `CCS_TMUX_BIN` | `tmux` |
| `CCS_GHQ_BIN` | `ghq` |
| `CCS_GIT_BIN` | `git` |
| `CCS_JQ_BIN` | `jq` |
| `CCS_PS_BIN` | `ps` |
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
