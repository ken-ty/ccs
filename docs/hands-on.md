# 手を動かして確かめる

**実機で 1 周する手順。** 上から順に打てば、`ccs` が本当に動くかを自分の目で確認できる。

各手順には「期待される出力」と「違ったときに見るところ」を付けた。
**期待される出力は、すべてこのマシンで実際に上から順に走らせて得たもの**
（UUID と時刻だけは毎回変わる）。信頼確認の 30 秒待ちも、`/exit` のあとに
ペインがシェルへ戻ることも、実機で確認した上で書いている。

所要時間はおよそ 15 分。**途中でやめても、最後の「元に戻す」だけやれば跡は残らない。**

---

## 0. 前提を確かめる

```bash
tmux -V && jq --version && claude --version && which ccs
```

**期待される出力**（版は前後してよい）:

```
tmux 3.7b
jq-1.8.1
2.1.226 (Claude Code)
/Users/apple/.local/bin/ccs
```

??? question "`ccs` が見つからない"
    symlink を張る。

    ```bash
    ln -sf ~/ghq/github.com/ken-ty/ccs/bin/ccs ~/.local/bin/ccs
    ```

??? question "`tmux` か `jq` が無い"
    ```bash
    brew install tmux jq
    ```
    `ccs` は依存が無いと**終了コード 4** で落ち、導入方法を出す。それも試してよい:
    `CCS_JQ_BIN=nope ccs ls`

---

## 1. 触る前の状態を控える

**あとで「元に戻ったか」を確かめるため。** 何も変わっていないことを最後に確認する。

```bash
tmux ls; ls ~/.cc-scratch 2>&1 | head -3; jq -r '.projects | length' ~/.claude.json
```

**期待される出力**（まだ tmux を使っていなければ）:

```
no server running on /private/tmp/tmux-501/default
ls: /Users/apple/.cc-scratch: No such file or directory
55
```

!!! note "数字は控えておく"
    最後の数字（`.projects` の件数）を覚えておく。**手順 9 以外では増えないはず。**

---

## 2. 何も起きないことを確かめる

`resolve` は**副作用が無い**。まずここで、打ち間違いが安全に分かることを見る。

```bash
ccs resolve x01
```

**期待される出力**:

```
x01	/Users/apple/ghq/github.com/ken-ty/x01
```

続けて、曖昧なときに**勝手に選ばない**ことを見る。

```bash
ccs resolve IceCubesApp
```

**期待される出力**（終了コードは 1）:

```
ccs: IceCubesApp に当てはまるリポジトリが複数あります:

  Dimillian/IceCubesApp
  ken-ty/IceCubesApp

<owner>/<repo> の形で指定し直してください。
```

**ここまでで tmux セッションは 1 つも立っていない。** 確かめる:

```bash
tmux ls
```

→ `no server running ...` のまま。

---

## 3. 立てる

```bash
ccs new x01
```

**期待される出力**（1 行の JSON。`sessionId` は毎回変わる）:

```json
{"slug":"x01","sessionId":"0ecd87dd-…","path":"/Users/apple/ghq/github.com/ken-ty/x01","tmux":"cc/x01","transcript":"/Users/apple/.claude/projects/-Users-apple-ghq-github-com-ken-ty-x01/0ecd87dd-….jsonl","created":true,"running":true}
```

見るところ:

- `created` が `true`
- `running` が `true`
- 数秒で返る（30 秒待たされたら手順 3 の下の「うまくいかないとき」へ）

??? failure "30 秒待って「登録されませんでした」と言われた"
    `ccs` はペインの中身を見せてくれる。だいたいは次のどれか:

    - **信頼確認で止まっている** → `ccs attach x01` して「1. Yes, I trust this folder」
    - **ログインが切れている** → `ccs attach x01` して `/login`
    - それ以外 → ペインの内容をそのまま読む

    **`ccs` はこのときセッションを消さない。** 何に詰まったかを見られるようにするため。
    諦めるときは `ccs kill x01`。

---

## 4. ハブから見えることを確かめる（ここが核心）

**`ccs` を作った理由はこの 1 点。** 立てたセッションに、このハブから指示を送れること。

ここで使う [`ListAgents`](agent-tools.md#listagents) と
[`SendMessage`](agent-tools.md#sendmessage) はシェルのコマンドではないので、
ターミナルではなくこのチャットで頼む。

> ListAgents で今あるセッションを見せて

**期待される結果**: 一覧に `x01` が `interactive · idle` として現れる。

```
Peer sessions (7):
  x01 [80bd9b]  ·  interactive  ·  idle  ·  started 17s ago
  …
```

続けて、実際に仕事を頼んでみる:

> x01 のセッションに「このリポジトリの README の見出しだけ列挙して」と頼んで、結果を教えて

**期待される結果**: 数十秒で、x01 側が調べた内容が返ってくる。

!!! success "ここが通れば、狙っていたものは動いている"
    ターミナルを 1 度も開かずに、新しいセッションを立てて仕事を頼み、結果を回収できた。

---

## 5. 乗り込んで、抜ける

```bash
ccs attach x01
```

**期待される動き**: Claude Code の画面に切り替わる。左下に `x01` と出ている。

**抜けるとき**: `Ctrl-b` を押してから `d`（detach）。**`Ctrl-c` や `exit` ではない。**

!!! warning "detach と kill は違う"
    `Ctrl-b d` で抜けてもセッションは生き続ける。**それが tmux を使っている理由。**
    畳みたいときだけ `ccs kill` を使う。

抜けたあと、生きていることを確かめる:

```bash
ccs ls
```

**期待される出力**:

```
SLUG  STATUS    SESSION ID                            PATH
x01   idle      0ecd87dd-cdb0-4835-add0-23e4c14b9b5f  ~/ghq/github.com/ken-ty/x01
```

---

## 6. 二度立てても増えないことを確かめる

```bash
ccs new x01
```

**期待される出力**: 手順 3 と**同じ `sessionId`** で、`created` が `false`。

```json
{"slug":"x01","sessionId":"0ecd87dd-…",…,"created":false,"running":true}
```

打ち方を変えても同じになることも見る:

```bash
ccs new ken-ty/x01
```

→ これも `created:false`、同じ `sessionId`。

**tmux セッションが 1 本のままであること**:

```bash
tmux ls
```

→ `cc/x01: 1 windows …` の 1 行だけ。

---

## 7. 止まったセッションの見え方

claude だけを終了させて、ペインが残っている状態を作る。

```bash
ccs attach x01
```

→ Claude Code の中で `/exit`（または `Ctrl-d`）。**ペインはシェルに戻る。**
→ `Ctrl-b d` で抜ける。

```bash
ccs ls
```

**期待される出力**:

```
SLUG  STATUS    SESSION ID                            PATH
x01   stopped   0ecd87dd-cdb0-4835-add0-23e4c14b9b5f  ~/ghq/github.com/ken-ty/x01
```

見るところ: **`stopped` になっても `SESSION ID` が出ている。**
この UUID が同じ会話に戻る手掛かりで、`ccs restore` もこれを使う。

この状態で `ccs new x01` を打つと、**成功扱いにせず**復帰コマンドを出す:

```
ccs: cc/x01 のペインは残っていますが、claude は動いていません。

  乗り込んで、同じ会話を再開する:
    ccs attach x01
    claude --resume 0ecd87dd-cdb0-4835-add0-23e4c14b9b5f
  畳んで立て直す:     ccs kill x01 && ccs new x01
```

---

## 7.1 止まったセッションを戻す

`ccs ls` が `stopped` と言っている状態のまま、**同じ会話で立て直す。**

```bash
ccs restore
```

**期待される出力**（既定は見せるだけ。何も起きない）:

```
立て直せるセッション:
  x01   2026-08-22 13:45  0ecd87dd-cdb0-4835-add0-23e4c14b9b5f  <会話の名前>

実行するには: ccs restore --yes
別の会話を選ぶ: ccs restore <slug> --list
```

```bash
ccs restore --yes
ccs ls
```

見るところ: **`SESSION ID` が戻す前と同じで、`STATUS` が `stopped` でなくなっている。**
ここが違っていたら、戻ったように見えて別の会話が立っている。

`ccs attach x01` で乗り込むと、**前の会話がそのまま続いている**（スクロールバックに
前のやり取りがある）。アプリの一覧では**元の名前のまま**戻る ── `restore` は
`-n` を渡さないので、会話に付いていた名前が消えない。

!!! warning "戻した会話は動き出すことがある"
    落ちる直前に続きがあった会話は、resume した瞬間に続きを走らせる。
    `ccs` から止める手段は無いので、1 本ずつ戻したいときは名指しする
    （`ccs restore x01 --yes`）。詳細は [restore.md](restore.md#既定は見せるだけ)。

**tmux ごと消えた場合**（再起動の再現）も同じ手順で戻る。`ccs kill x01` で畳んでから
`ccs restore` を打つと、`x01` も候補に出る ── ghq 配下でも **`ccs` が立てた印**があれば
拾うため（[印とは](restore.md#印とは)）。

```bash
ccs restore --yes         # まとめて
ccs restore x01 --yes     # 名指し
```

---

## 8. 掃除する

まず**見せるだけ**:

```bash
ccs gc
```

**期待される出力**:

```
止まっているセッション（畳む対象）:
  x01                  claude --resume 0ecd87dd-cdb0-4835-add0-23e4c14b9b5f

実行するには: ccs gc --yes
```

見るところ: **何も消えていない。** `tmux ls` で確かめてよい。

内容を確認してから実行:

```bash
ccs gc --yes
```

**期待される出力**:

```
止まっているセッション（畳む対象）:
  x01                  claude --resume 0ecd87dd-…

畳みました: cc/x01
```

```bash
ccs ls
```

**期待される出力**:

```
立っているセッションはありません。

  立てる: ccs new <target>
```

---

## 9. 使い捨ての作業枠（何本でも立つ）

!!! info "ここで `~/.claude.json` に行が増える"
    枠を信頼済みにするのは **`ccs` 自身**（[#6](https://github.com/ken-ty/ccs/issues/6)、
    2026-08-18 の決定）。手順 1 で控えた `.projects` の件数が、立てた枠のぶんだけ増える。

```bash
ccs new --tmp
```

**期待される出力**（stderr に 1 行、stdout に JSON）:

```
ccs: 空の使い捨て作業枠なので信頼済みにしました: /Users/apple/.cc-scratch/1
{"slug":"tmp-1","sessionId":"…","path":"/Users/apple/.cc-scratch/1",…,"created":true}
```

**信頼確認は出ない。** 枠は `ccs` が作った空のディレクトリなので、確認が守ろうとしている
「知らないコード」がそこに無い。

続けてもう 1 本立てて、**枠が増える**ことを確かめる:

```bash
ccs new --tmp
ccs ls
```

**期待される出力**: `tmp-1` と `tmp-2` が両方 `idle` で出る。ここが詰まると
「使い捨てを何本も立てる」という枠の存在理由そのものが成り立たない。

短い綴りの `ccs new tmp` も同じ結果になる。ただし ghq に `tmp` という名前のリポジトリが
あるときだけは、どちらを指したか決められないので候補を出して止まる。

!!! note "枠の割り当て方は変わる予定"
    `~/.cc-scratch/1`・`~/.cc-scratch/2` という固定 8 枠は、**セッションごとに一意な
    ディレクトリを作る形へ変わる**（[ADR-0001](adr/0001-scratch-workspace-identity.md)）。
    この手順で確かめているのは「使い捨ての場所が何本でも立ち、信頼確認が出ないこと」なので、
    そこは変わらない。**変わるのはパスと slug の見た目**で、そのときはこの手順書も直す。

---

## 10. 元に戻す

```bash
ccs kill tmp-1
ccs kill tmp-2
ccs gc --yes
```

**期待される出力**: 空になった枠のディレクトリも `gc` が消す。

```
消しました: ~/.cc-scratch/1
消しました: ~/.cc-scratch/2
```

親のディレクトリだけ残るので、それも消す:

```bash
rmdir ~/.cc-scratch
ccs ls; ls ~/.cc-scratch
```

**期待される出力**:

```
立っているセッションはありません。

  立てる: ccs new <target>
ls: /Users/apple/.cc-scratch: No such file or directory
```

!!! note "`tmux ls` にセッションが残っていても異常ではない"
    ここで確かめたいのは「**`ccs` の跡が残っていないこと**」なので、`tmux ls` ではなく
    `ccs ls` で見る。`ccs ls` は `cc/` が付いたセッションだけに絞るため、
    自分で開いた作業用の tmux セッションを巻き込まない。

    `tmux ls` を打つと、手順 8 で畳まなかったセッションや、この手順の外で立てた
    ものがそのまま出る。**tmux サーバは 1 本でも残っていれば動き続ける**ので、
    `no server running …` が出るのは全部畳んだときだけ。

    ```
    $ tmux ls
    cc/x01: 1 windows (created Tue Aug 18 03:08:39 2026)
    ```

    これは「手順 7〜8 で畳んだ `x01` を、そのあと立て直したまま残している」状態。
    畳むなら `ccs kill x01`、残すならそのままでよい。

`ccs` 自体を外すなら:

```bash
rm ~/.local/bin/ccs
```

??? note "`~/.claude.json` について"
    手順 9 で増えた `hasTrustDialogAccepted` の行は残る。枠を次に使うときに確認が
    出なくなるだけで、害は無いので消さなくてよい。気になるなら
    `jq 'del(.projects["'"$HOME"'/.cc-scratch/1"])'` で消せるが、**このファイルは
    Claude Code の状態がまとめて入った 100KB 級のもの**なので、書き戻す前に
    中身を確かめること。

---

## 11. hub を 1 周する（**一部実施**）

!!! info "launchd の経路だけ実測した（2026-08-22 / macOS 15・Homebrew）"
    アプリ側の見え方（名前・`offline` の残り方・`--resume` での RC 張り直し）は
    **まだ**。fake claude では確かめられないので、ここは未チェックのまま残す。

```bash
ccs hub up            # JSON が返り、bridge が空でないこと
ccs hub status        # state healthy、終了コード 0
ccs ls                # hub が一覧に出ること
```

確かめたいこと:

- [ ] スマホ / デスクトップのアプリの一覧に **`hub` という名前で**出るか
      （会話を数往復させても名前が変わらないか）
- [ ] `ccs hub restart` のあと、アプリの一覧に**新しい hub が出て、古いものが
      offline で残り続けないか**
- [ ] `ccs hub restart --resume` で同じ会話に戻り、そのとき Remote Control が
      張り直されるか
- [ ] `remoteControlAtStartup: true` を設定している環境で、`--remote-control` の
      明示指定が二重登録にならないか
- [x] **launchd から起動した `ccs hub up` が、手元と同じ tmux サーバに入るか**

### 11.1 launchd の経路（実測済み）

```bash
ccs hub agent --print > ~/Library/LaunchAgents/local.ccs.hub.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ccs.hub.plist
tmux kill-server      # tmux サーバごと落として、電源断と同じ状態を作る
```

**結果: 入る。** `launchctl` が起動した `ccs hub up` は
`/private/tmp/tmux-501/default` ── 手元のシェルの `tmux ls` が見るのと同じ
ソケット ── に `cc/hub` を作り、`ccs ls` にも 1 本だけ出た。`bridge` も付いた。

**ただし、素の `-lc` では PATH が足りずに死ぬ。** 最初の設置では
`~/.cc-hub/agent.log` に依存不足だけが積まれた。

```console
$ tail ~/.cc-hub/agent.log
ccs: 必要なコマンドが見つかりません: tmux
```

launchd が渡す PATH は `/usr/bin:/bin:/usr/sbin:/sbin` 相当で、`-lc` を付けても
読まれるのは `/etc/zprofile`（`path_helper`）と `~/.zprofile` まで。**`~/.zshrc`
は対話シェル専用なので読まれない。** Homebrew の既定の入れ方は
`~/.zshrc` に `brew shellenv` を書くので、`/opt/homebrew/bin` がそこで落ちる。

```console
$ env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -lc 'command -v tmux'
（何も出ない）
```

これを受けて `ccs hub agent` は、**生成時に解決できた依存の在処を
`EnvironmentVariables` に焼き込む**ようにした。焼き込んだあとで
`tmux kill-server` → `launchctl bootstrap` を通したところ、上のとおり復帰した。

!!! warning "ユニットは生成した環境に紐づく"
    焼き込みなので、Homebrew の場所を変えたり `claude` を入れ直したりしたら
    **`ccs hub agent --print` で出し直して置き換える**。

!!! note "`hub down` のまま放置しない"
    `paused` がある間は自動起動も止まる。確認が終わったら `ccs hub up --force`。

元に戻す:

```bash
launchctl bootout gui/$(id -u)/local.ccs.hub
rm ~/Library/LaunchAgents/local.ccs.hub.plist
ccs hub down && rm -rf ~/.cc-hub     # 中身を確かめてから
```

---

## 通ったかどうかの一覧

- [ ] 0. 依存が揃っている
- [ ] 2. `resolve` が副作用なしで答え、曖昧なときは勝手に選ばない
- [ ] 3. `ccs new` が数秒で JSON を返す
- [ ] **4. ハブの `ListAgents` に現れ、`SendMessage` で仕事を頼めた** ← ここが本命
- [ ] 5. `Ctrl-b d` で抜けてもセッションが生きている
- [ ] 6. 二度立てても増えない（`created:false`、同じ `sessionId`）
- [ ] 7. `stopped` でも `SESSION ID` が出る
- [ ] 7.1 `ccs restore` が同じ `sessionId` で立て直し、会話の名前も変えない
- [ ] 8. `gc` が既定では何も消さない
- [ ] 9. 使い捨ての作業枠が、信頼確認なしで 2 本とも立った
- [ ] 10. 元に戻せた
- [ ] 11. hub（**未実施**。fake claude では確かめられない部分）

**4 が通れば、この道具が解こうとしていた問題は解けている。**
他が引っかかっても、それは使い勝手の話。

---

## うまくいかないときの見どころ

| 症状 | 見るところ |
| --- | --- |
| `ccs new` が 30 秒待って失敗する | ペインの中身が出るのでそれを読む。信頼確認かログイン切れが大半 |
| [`ListAgents`](agent-tools.md#listagents) に出てこない | `ccs ls` で `idle` か確かめる。`stopped` なら claude が落ちている（[使い分け](agent-tools.md#ccs-ls-との使い分け)） |
| `attach` から抜けられない | `Ctrl-b` → `d`。`Ctrl-c` ではない |
| `ccs new --tmp` が「枠が全部埋まっています」 | `ccs gc` で状況を見る。中身のある枠は `ccs` が消さないので自分で確認する |
| `ccs new tmp` が「同名のリポジトリもあります」 | ghq に `tmp` がある。作業枠なら `--tmp`、リポジトリなら `<owner>/tmp` |
| `ccs kill` が「作業中です」で止まる | 意図した動き。`ccs attach` で様子を見てから `--force` |
| `ccs restore` に戻したいものが出てこない | ghq の外に立てたものは列挙しない（名指しで戻す）。**印の無い会話**（アプリ / VS Code から開いたもの）も出ない。古い会話は既定で 7 日まで（`--all`）。[印とは](restore.md#印とは) |
| `ccs hub up` が `no-rc`（10）で終わる | Remote Control が付いていない。`ccs config` で `CCS_REMOTE_CONTROL` を見る。使わない環境なら `off` |
| `ccs hub up` が `needs-attention`（15）で止まる | 再起動を繰り返している。`ccs hub attach` と `~/.cc-hub/hub.log` を見る |
| 終了コードの意味 | 0 成功 / 1 失敗 / 2 使い方の誤り / 4 依存が無い / 10〜15 は hub の状態（[hub](hub.md#状態)） |

それでも分からなければ、**このチャットにそのまま貼ってほしい。**
`ccs` が出すメッセージは、次の手が分かるように書いてある。
書いていなかったとしたら、それはこちらの直すべき点。
