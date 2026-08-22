# hub — 常時 1 本だけ立てておくセッション

`ccs hub` は、**スマホや別のマシンから唯一触る 1 本**を立て、落ちても戻ってくる
ようにするためのサブコマンド群。

```
ccs hub up [--force] [--quiet]   立てる（生きていれば何もしない）
ccs hub status [--json]          状態を見る（終了コードで分岐できる）
ccs hub restart [--resume]       立て直す（--resume で同じ会話に戻る）
ccs hub down                     止める（自動起動も止まる）
ccs hub attach                   乗り込む
ccs hub agent [--print]          自動起動の設定を出す
```

## なぜ hub だけ特別扱いなのか

Claude Code のアプリ（スマホ・デスクトップ）から届くのは、**いま生きている
セッション**だけ。hub が死ぬと、`ccs` を叩く経路そのものが消える。

```
スマホ ──▶ hub（生きている限り操作できる）──▶ ccs new / ls / kill
             │
             └─ 死ぬと、ここから先に手が届かない
```

普通のセッションなら、死んでいても人がターミナルの前で立て直せばいい。hub は
**「ターミナルの前にいないとき」のための入口**なので、同じ理屈が使えない。
だから hub にだけ、次の 3 つが付いている。

| | |
| --- | --- |
| 冪等な `up` | 生きていれば何もしない。死んでいれば立て直す。**何度呼んでも安全** |
| 自動起動 | launchd / systemd から `ccs hub up` を定期実行する |
| 保護 | `ccs kill` と `ccs gc` の対象外。うっかり畳めない |

## 立てる

```console
$ ccs hub up
{"slug":"hub","state":"healthy","sessionId":"…","previousSessionId":"","path":"/Users/you/.cc-hub","tmux":"cc/hub","bridge":"session_…","transcript":"…","created":true}
```

初回は作業ディレクトリ（既定 `~/.cc-hub`）を作り、次の 2 つを置く。
**どちらも既にあれば上書きしない。**

| ファイル | 中身 |
| --- | --- |
| `CLAUDE.md` | hub の役割と禁止事項。「自分では作業しない」「自分を畳まない」 |
| `.claude/settings.json` | `ccs kill` / `ccs gc` / `tmux kill-*` を確認つきにし、`ccs hub down` を禁じる |

!!! note "権限のパターンは `ccs` という名前を前提にしている"
    `Bash(ccs kill:*)` のような書き方なので、別名やフルパスで呼ぶと素通りする。
    自分の呼び方に合わせて書き足してよい（ccs は上書きしない）。

!!! note "`bridge` が空でないことを確かめている"
    `ccs hub up` は、レジストリに載っただけでは「立った」と見なさない。
    **Remote Control の登録（`bridgeSessionId`）が付くまで待つ。**
    付いていないセッションはアプリの一覧に出ない ＝ スマホからは死んでいるのと同じ。

## 状態

`ccs hub status` は状態を 1 語で返し、**終了コードでも同じことを言う**。
自動起動やスクリプトから分岐できるようにするため。

| state | 意味 | `ccs hub up` の対処 | 終了コード |
| --- | --- | --- | --- |
| `healthy` | 生きていて、Remote Control も付いている | 何もしない | 0 |
| `no-rc` | claude は生きているが RC が付いていない | 立て直す | 10 |
| `stopped` | ペインは残っているが claude が死んでいる | 立て直す | 11 |
| `absent` | tmux セッションごと無い | 立てる | 12 |
| `needs-login` | ペインに認証要求が出ている | **何もしない**（人を待つ） | 13 |
| `paused` | `ccs hub down` で止めてある | 何もしない | 14 |
| `needs-attention` | 短時間に再起動を繰り返している | **何もしない**（人を待つ） | 15 |

```console
$ ccs hub status
slug        hub
state       healthy
tmux        cc/hub
path        ~/.cc-hub
sessionId   0ecd87dd-cdb0-4835-add0-23e4c14b9b5f
bridge      session_01HoUqrukR64rupP8oiyHZG8
RC          auto
```

## 立て直す / 止める

**`ccs kill hub` は使えない**（`--force` でも拒否する）。hub を落とすことは
「畳む」ではなく「作り直す」なので、動詞を分けてある。

| したいこと | コマンド |
| --- | --- |
| 調子が悪いので作り直す（会話は捨てる） | `ccs hub restart` |
| 作り直して、同じ会話を続ける | `ccs hub restart --resume` |
| しばらく止めておく（自動起動も止める） | `ccs hub down` |
| 止めたものを再開する | `ccs hub up --force` |

!!! info "既定はまっさら"
    `restart` も、自動起動による立て直しも、**新しい会話で立てる**。
    落ちた原因が会話の側（context が溢れた、状態が壊れた）だったとき、
    同じ会話を復元すると同じ理由で落ち続けるため。

    直前の `sessionId` は `~/.cc-hub/state.json` の `previousSessionId` に
    残るので、続きが要るときは `ccs hub restart --resume` で戻れる。

## 常時起動（**推奨の初期設定**）

`ccs hub up` は冪等なので、**定期的に叩くだけで死活監視になる**。設定ファイルは
`ccs hub agent` が出す。

**推奨は「ログイン時 + 5 分ごと」（既定の `CCS_HUB_AUTOSTART=on`）。** hub を
使うなら、立てたその日にこれも入れる ── 入れないと、hub が死んだ瞬間に
スマホから `ccs` を叩く経路が消え、**ターミナルの前に戻るまで気づけない**。

### なぜ 5 分ごとを勧めるのか

**健全なときの `ccs hub up` は claude を起動しない。** 見ているのは tmux の
セッション一覧と `~/.claude/sessions/*.json` だけで、API も叩かなければ
claude プロセスも作らない。実測（macOS 15 / Apple Silicon）:

```console
$ time ccs hub up --quiet        # state が healthy のとき
0.02s user 0.03s system  →  0.057 total
```

5 分ごとに走っても消えるのは 0.06 秒の CPU だけ。**ログも増えない**（健全な
ときは何も書かない）。立て直しが暴走したときは[歯止め](#暴走の歯止め)が別に
効くので、繰り返しが課金に化けることもない。

対して `login`（起動時 1 回だけ）にすると、次が戻らなくなる。

| 落ち方 | `on`（5 分ごと） | `login`（起動時だけ） |
| --- | --- | --- |
| 電源断・再起動のあとログインした | 戻る | 戻る |
| claude がクラッシュした（`stopped`） | **戻る** | 戻らない |
| Remote Control が外れた（`no-rc`） | **戻る** | 戻らない |
| context が溢れて落ちた | **戻る** | 戻らない |

下の 3 つは**ターミナルの前にいないときに起きる**。そのときの入口を確保するのが
hub の目的そのものなので、定期実行はその保険にあたる。

| `CCS_HUB_AUTOSTART` | 生成されるもの |
| --- | --- |
| `on`（既定・**推奨**） | ログイン時 + `CCS_HUB_AGENT_INTERVAL` 秒ごと（既定 300 秒） |
| `login` | ログイン時だけ |
| `off` | 生成しない。`ccs hub agent` は理由を出して終了する |

### 入れる（macOS / launchd）

打ち方が分からなくなったら `ccs hub agent`（`--print` なし）が手順を出す。

**1. hub を立てる。** 自動起動を入れる前に、手で 1 回立って `bridge` が
付くことを確かめておく。ここが通らない状態で自動起動を入れると、5 分ごとに
同じ失敗を繰り返すだけになる。

```console
$ ccs hub up
{"slug":"hub","state":"healthy",…,"bridge":"session_…","created":true}
```

**2. ユニットを書き出して読み込む。**

```console
$ ccs hub agent --print > ~/Library/LaunchAgents/local.ccs.hub.plist
$ launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ccs.hub.plist
```

**3. 入ったことを確かめる。** 3 つとも見る。1 つでも欠けていたら入っていない。

```console
$ launchctl list | grep ccs        # ラベルが出て、直近の終了コードが 0
-	0	local.ccs.hub

$ ccs hub status                   # healthy（終了コード 0）
$ ccs ls                           # hub が 1 本だけ出る
```

**4. わざと落として、戻ることを確かめる。** ここまでやって初めて「常時起動が
入った」と言える。`ccs hub down` ではなく `tmux kill-server` を使う ──
`down` は「止めておけ」という意思表示なので、自動起動は正しく無視する。

```console
$ tmux kill-server                 # 電源断と同じ状態を作る
$ ccs hub status                   # absent（12）
… 5 分以内 …
$ ccs hub status                   # healthy（0）に戻る
```

待てないなら `launchctl kickstart -k gui/$(id -u)/local.ccs.hub` で即座に 1 回
走らせられる。

### 入れる（Linux / systemd --user）

どちらを出すかは `uname` で決める。**systemd は service と timer の 2 ファイルに
分かれる**ので、書き出すときは `--unit` で片方ずつ出す（そのままリダイレクト
すると 1 ファイルに混ざって壊れる）。

```console
$ mkdir -p ~/.config/systemd/user
$ ccs hub agent --print --unit service > ~/.config/systemd/user/local-ccs-hub.service
$ ccs hub agent --print --unit timer   > ~/.config/systemd/user/local-ccs-hub.timer
$ systemctl --user enable --now local-ccs-hub.timer
```

確かめ方は macOS と同じ（`systemctl --user list-timers` に出るか、
`ccs hub status` が healthy か、`ccs ls` に 1 本だけか）。

!!! tip "ログアウトしても走らせたいなら"
    systemd の user unit は既定でログアウト時に止まる。`loginctl enable-linger
    $USER` で残る。**ただし、そこで立つ hub は誰も見ていない claude なので、
    認証切れに気づくのが遅れる**ことは承知しておく。

### 間隔を変える

`CCS_HUB_AGENT_INTERVAL`（秒）。**ユニットを出し直して入れ直すまで効かない**
── 焼き込みなので、設定を変えただけでは既に置いた plist / timer は変わらない。

```console
$ CCS_HUB_AGENT_INTERVAL=1800 ccs hub agent --print > ~/Library/LaunchAgents/local.ccs.hub.plist
$ launchctl bootout gui/$(id -u)/local.ccs.hub
$ launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ccs.hub.plist
```

一時的に中身だけ見たいときは `ccs hub agent --print --autostart on`。
**設定を書き換えなくても確かめられる。**

### 外す

```console
$ launchctl bootout gui/$(id -u)/local.ccs.hub
$ rm ~/Library/LaunchAgents/local.ccs.hub.plist
```

```console
$ systemctl --user disable --now local-ccs-hub.timer
$ rm ~/.config/systemd/user/local-ccs-hub.{service,timer}
```

!!! warning "生成したユニットには PATH を焼き込んである"
    **launchd / systemd は対話シェルの設定を読まない。** `-lc` でログインシェルに
    しても、PATH を `~/.zshrc` で足している環境（Homebrew の既定の入れ方がこれ）
    では `tmux` も `claude` も見つからず、`ccs hub up` が依存不足で即死する。

    そこで `ccs hub agent` は、**生成した時点で解決できた依存の在処**を
    `EnvironmentVariables` / `Environment=PATH=` として書き出す。つまり
    **ユニットは生成した環境に紐づく**ので、Homebrew の場所を変えたり
    `claude` を入れ直したりしたら、**出し直して置き換える**こと。

!!! note "入れた直後に確かめること"
    launchd から起動した `ccs` が手元と同じ tmux サーバに入ることは
    [実測した](hands-on.md#111-launchd-の経路実測済み)（macOS 15 / Homebrew）。ただし
    環境に依るので、**入れた直後に `ccs hub status` と `ccs ls` を両方見る**。
    別のサーバに入っていれば、hub が 2 本あるように見える（`ccs ls` に出ない
    hub ができる）。立たないときは `~/.cc-hub/agent.log` に理由が出ている。

!!! danger "自動起動が埋められない穴が 1 つある"
    launchd の user agent も systemd の user unit も、**ログインセッションが
    始まって初めて走る**。電源を入れただけで誰もログインしていない状態では、
    hub は立たない。

    macOS で FileVault を有効にしていると、起動時に人がパスワードを打つまで
    ログインが始まらない ＝ **無人の電源投入からは復帰できない**。埋めるなら
    自動起動の話ではなく、「電源を落とさない（スリープにする）」か
    「常時稼働の別マシンを hub のホストにする」かの選択になる。

## 認証切れ

ログインが切れると、claude は起動しても認証を求めて止まる。**この状態は自動では
直せない**ので、`ccs hub up` は状態を `needs-login` と判定して**立て直さずに終わる**。
立て直しても同じ画面で止まるだけで、API を叩き続けるだけになるため。

```console
$ ccs hub up
ccs: hub の認証が切れています。**自動では直せません。**

  乗り込んで /login する: ccs hub attach
```

判定はペインの文字（`/login`、`login expire`、`invalid api key` など）を見ている。
直したあとは、次の定期実行がそのまま拾う。

## 暴走の歯止め

直すつもりで立て直したものが、また落ちて、また立て直す ── これを 5 分ごとに
繰り返すと、**課金とレート制限に直結する**。

`CCS_HUB_BACKOFF_WINDOW` 秒（既定 600）の間に `CCS_HUB_BACKOFF_MAX` 回（既定 3）
以上**自動で**立て直していたら、`ccs hub up` は何もせず `needs-attention`（15）で
終わる。人が見るまで止まったままになる。

数えるのは自動復帰だけ。`ccs hub restart` は人がその場にいる証拠なので数えない
── 数えると、手で 3 回直した直後に自動復帰が止まってしまう。

```console
$ ccs hub up
ccs: hub の再起動が続いているため止めています（直近 600 秒で 3 回以上）。

  何が起きているか見る: ccs hub attach / tail ~/.cc-hub/hub.log
  それでも立てる:       ccs hub up --force
```

## 記録

| ファイル | 中身 |
| --- | --- |
| `~/.cc-hub/state.json` | `sessionId` / `previousSessionId` / `startedAt` / `restarts`（**自動で立て直した**直近 20 件。人が打った `ccs hub restart` は数えない） |
| `~/.cc-hub/hub.log` | JSONL。`start` / `restart` / `paused` / `resumed` / `needs-login` / `no-rc` / `backoff` / `failed` |
| `~/.cc-hub/agent.log` | 自動起動（launchd）の stdout / stderr |

**健全なときは何も書かない。** 5 分ごとに「異常なし」を積むと、肝心の異常が
埋もれるため。`hub.log` が JSONL なのは、hub 自身に読ませて「昨夜なぜ落ちたか」を
聞けるようにするため。

```console
$ tail -3 ~/.cc-hub/hub.log
{"ts":"2026-08-19T02:14:07Z","event":"restart","detail":"sessionId=8f1c…"}
{"ts":"2026-08-19T05:41:22Z","event":"needs-login","detail":"ペインに認証要求が出ています"}
{"ts":"2026-08-19T09:02:10Z","event":"start","detail":"sessionId=1b7d…"}
```

## 保護

| 操作 | 扱い |
| --- | --- |
| `ccs kill <hub>` | **拒否**（`--force` でも）。`ccs hub restart` / `ccs hub down` を案内する |
| `ccs gc` | hub は対象外。止まっていても畳まない（自動起動が戻すため） |
| `ccs kill <自分自身>` | `--force` が要る。ハブのエージェントが自分を指した事故を防ぐ |
| hub 自身の `ccs kill` / `ccs gc` | `~/.cc-hub/.claude/settings.json` で確認つきにしてある |
| hub 自身の `ccs hub down` | 同ファイルで禁止（自分を止められると、誰も起こせない） |

## 名前とアプリでの見え方

`ccs hub up` は `claude` に **`--remote-control <slug>` を明示的に渡す**。

渡さない場合、アプリ側に出る名前は ccs の管轄外になる。実測でも、`ccs` が
`-n` で付けた名前は起動後に変わっていた（レジストリの `formerNames` に
`tmp-1` → `新しい名前` → `朝会夕会` の遷移が残っている。自動命名と手での
リネームのどちらもありうる）。hub は「アプリの一覧から毎回選ぶもの」なので、
名前が動くと見失う。

Remote Control を使わない・使えない環境では `CCS_REMOTE_CONTROL=off` にする。
`--remote-control` を渡さなくなり、生死判定も RC を要求しなくなる
（要求したままだと、`no-rc` と判定して永久に立て直し続ける）。

## まだ実測できていないこと

**正直に書いておく。** 次は fake claude では検証できず、本物で確かめる必要がある。

1. `--remote-control <名前>` で付けた名前が、会話が進んでも維持されるか
2. `remoteControlAtStartup: true` を設定している環境で、`--remote-control` の
   明示指定が二重登録にならないか
3. `claude --resume <uuid>` で Remote Control が張り直され、アプリの一覧に戻るか
4. 再起動を繰り返したときに、アプリ側に古い hub の `offline` エントリが積み上がらないか

**launchd から起動した `ccs` が手元と同じ tmux サーバに入るか**は
[実測済み](hands-on.md#111-launchd-の経路実測済み)（2026-08-22、macOS 15 / Homebrew）。入る。
ただし PATH を渡さないと、そこへ辿り着く前に依存不足で死ぬ。

手順は [手を動かして確かめる](hands-on.md) に追記していく。
