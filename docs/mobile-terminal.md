# スマホから ccs の端末を触る — 方式の比較

調査日: 2026-08-22 / macOS 26.x (`kenty-work-mac`) / tmux 3.7b / Tailscale 1.98.9。
関連: [#19](https://github.com/ken-ty/ccs/issues/19)、[why.md §4](why.md#その独立には代償がある--アプリからターミナルが見えない)、
ROADMAP の P1 / P2。

**この文書は比較であって決定ではない。** 選んだら [ADR](adr/README.md) に 1 本立てる。

> **表記**: 「実測」と書いた行はこの調査で実際にコマンドを叩いて確かめたもの。
> 確かめていないものは「未検証」と明記する。
>
> **2026-08-22 改訂**: 初版の「ttyd はキーバーを足せない」は**誤り**だった
> （`-I, --index` がある。§3.1）。松と竹を統合し、Tailscale 管理画面の案を §3.4 に足した。

---

## 0. 先に結論

| | |
| --- | --- |
| **推奨** | **梅（何も作らない）— Tailscale SSH + Termius。2026-08-25 に iPhone から実地で成立した（§10）** |
| **外出先アクセスの最短路** | **完了。`tailscale switch b2fa` + `tailscale up` で ACL の壁は消えた**（§2.4 実測）。残るは Tailscale SSH の有効化と iPhone の参加 |
| **ただし全案が 1 点で止まっている** | **tailnet の ACL が `kenty-work-mac` への通信を 1 つも許していない**（実測。§2） |
| **ACL が外れるまでの穴埋め** | **`ccs peek <slug>`（ROADMAP P1）。ネットワーク作業ゼロで今日から動く**（§3.0） |
| **`ccs` 側に要る変更** | `ccs peek` と、tmux の `window-size` の既定（§6.3）。それだけ |

「シンプルでいい」に照らすと、**作るべきものはほとんど無い。**
足りないのはコードではなく **ACL の 1 行** で、それは tonegawa さんの管轄にある。

---

## 1. 要件の切り分け — 「見る」と「打つ」は別物

Ken の要望は 3 つに分かれる。難易度も危険度も違うので、混ぜない。

| # | やりたいこと | 難易度 | 危険度 | 備考 |
| --- | --- | --- | --- | --- |
| R | ペインの**いまの画面を見る** | 低 | 低 | `tmux capture-pane` 一発。1 フレーム 1.5〜1.9 KB（実測） |
| R+ | 画面が**勝手に更新される**（ライブ） | 中 | 低 | ポーリングか `pipe-pane`。R との差は「更新の仕組み」だけ |
| W | **キーを送る** | 中 | **高** | 送った先はフルシェル。経路が漏れたらマシンごと取られる |

**R だけなら今日成立する**（§3.0）。W は経路（§5）とキーボード（§6）の両方が要る。
そして R+ と W をまとめて満たすと、それは「ターミナル」そのものになる。

### 1.1 W にはもう 1 つ、`ccs` 固有の分岐がある

`ccs` のペインは **1 window / 1 pane** で、中で `claude` が走っている（実測。§4）。
つまり **「シェルに打つ」場所が存在しない。** 打てるのは Claude Code の TUI に対してだけ。

これは [design.md §3](design.md#3-参考にした既存実装) が明示的に退けた
「`tmux send-keys` によるプロンプト注入」に当たる。**この方針は変えない。**

代わりにこうする:

```
Claude と会話する   → SendMessage（既存。アプリから届く）
シェルを叩く        → その tmux セッションに新しい window を切って、そこに送る
Claude の TUI を操作 → Esc / shift+Tab のような「制御キー」だけ。文章は送らない
```

**`tmux new-window -t cc/tmp-3` で 2 枚目を作れば、同じ作業ディレクトリのシェルが手に入る。**
プロンプト注入にならず、Claude の走っているペインも壊さない。ここが設計上の要。

---

## 2. 【最大の制約】tailnet の ACL が、この Mac への通信を 1 つも許していない

**すべての方式がここで止まる。先に書く。**

Ken の Mac は tailnet `tail67c417.ts.net` に居る。この tailnet の ACL は
[tori-create-7991/asakusa-t](https://github.com/tori-create-7991/asakusa-t) の Terraform が管理していて、
中身は grants が 3 本だけ（実測、`infra/terraform/tailscale/policy.hujson.tftpl`）。

| src | dst | 許可 |
| --- | --- | --- |
| `group:members` | `tag:server` | tcp:443, tcp:8443 |
| `group:admins` | `tag:server` | tcp:22 |
| `tag:ci` | `tag:server` | tcp:22 |

**dst が全部 `tag:server`（＝共有 Mac mini）。タグの無い個人端末宛の grant が 1 本も無い。**

コントロールプレーンがこの Mac へ配っているパケットフィルタを見ると、そのとおりになっている（実測）:

```console
$ tailscale debug netmap | jq -c '{PacketFilter, SSHPolicy}'
{"PacketFilter":[],"SSHPolicy":{"rules":[]}}
```

**空。** tailnet の中の誰も、この Mac のどのポートにも届かない。Tailscale SSH の
ポリシーも空なので、SSH も通らない。

さらに **Ken の iPhone は現在この tailnet に入っていない**（実測。peer は
`asakusamac-mini` 1 台のみ）。

### 2.1 これが意味すること

- 「Tailscale が入っているから tailnet 内に閉じれば済む」という前提は **いま成り立っていない**
- ttyd も自作サーバも SSH も、**動かす前に届かない**
- 直すには ACL に grant を足すしかない。ACL は tonegawa さんの Terraform 管轄で、
  `admin_emails` / `member_emails` を渡す `terraform.tfvars` は gitignore され
  tonegawa さんが持っている（[[my-asakusa-macmini]] スキル）

### 2.2 頼むべき「1 行」

**共有機 (`tag:server`) の統制には一切触らない形で書ける。** これが依頼を通しやすくする。

```jsonc
// grants に 1 本足すだけ。tag:server 宛の 3 本は変更しない
{
  "src": ["autogroup:member"],
  "dst": ["autogroup:self"],   // 「自分が持っている、タグの付いていない端末」だけ
  "ip":  ["*"],
},
```

`autogroup:self` は **その src ユーザ自身が所有する untagged なノード**にしか当たらない。
Ken の Mac ↔ Ken の iPhone は通り、`tag:server` は対象外なので mini の露出は増えない。

Tailscale SSH を使うなら、加えて `ssh` ブロックが要る:

```jsonc
"ssh": [
  { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"],
    "users": ["autogroup:nonroot"] },
],
```

> **未検証**: `grants` 構文で `dst: ["autogroup:self"]` が受理されるか（`acls` 構文では
> 一般的な書き方）。適用は tonegawa さんしかできないので、こちらでは試せていない。

### 2.3 tonegawa さん待ちにしない逃げ道 — **自分の tailnet は既に存在する**

**いま有効な tailnet は tonegawa さんのもので、Ken の tailnet は別に用意済みだった**（実測）。

```console
$ tailscale switch --list
ID    Tailnet                Account
b2fa  ken-ty.github          ken-ty@github
f426  rito.aither@gmail.com  kentokuracs@gmail.com*
```

| profile | tailnet | Ken の立場 | 用途 |
| --- | --- | --- | --- |
| `f426`（**いま有効**） | `rito.aither@gmail.com` = `tail67c417.ts.net` | `group:members`（間借り） | 共有 Mac mini。**ACL は tonegawa さんの Terraform** |
| `b2fa` | **`ken-ty.github`** | **Owner** | **ここなら ACL も Tailscale SSH も SSH Console も全部 Ken が決められる** |

**§2 の ACL 問題は、profile を切り替えるだけで消える。**

```console
$ tailscale switch b2fa
```

**新規作成すら要らない。誰の承認も要らない。**

- Mac（`kenty-work-mac` = **MacBook Pro / Mac15,6**、実測）と iPhone を `ken-ty.github` に入れる
- Tailscale の macOS / iOS は複数プロファイルを持てて切り替えられる。ただし
  **同時に有効なのは 1 つ**なので、Ken のプロファイルに居る間は
  `asakusamac-mini`（Gatus / Open WebUI）が見えなくなる
- mini は Web しか使っていないので、実害は小さいと見ている

**§2.2 の「tonegawa さんに 1 行頼む」は、もう検討しなくてよい。**

#### 2.3.1 失うもの — 外出先からの mini の Web だけ

- **`ssh macmini` / `macmini-admin` は mDNS（`asakusanoMac-mini.local`）宛て。**
  tailnet を切り替えても**家の LAN では今までどおり動く**
- 失うのは **外出先からの Gatus / Open WebUI**（tailnet の 443 / 8443）だけ
- 戻したいときは `tailscale switch f426`

#### 2.3.2 【要注意】MacBook は蓋を閉じるとスリープする

**外出先アクセスの前提は「Mac が起きていること」。** ここが一番壊れやすい。

`pmset -g custom` を見ると **AC / バッテリーとも `sleep 0`（実測）** で、
idle sleep は既に無効。だが **`sleep 0` は蓋を閉じたときのスリープには効かない。**

| 対処 | 備考 |
| --- | --- |
| 蓋を開けたまま置く | 一番確実。何もしなくてよい |
| `sudo pmset -b disablesleep 1` | 蓋を閉じてもスリープしなくなる。**sudo が要るので人が実行する** |
| クラムシェル（外部電源 + 外部ディスプレイ） | 常設なら |

**mini は IaC が `pmset -a sleep 0 autorestart 1` を入れているが、MacBook はそうではない。**
同じ「常時稼働」と考えないこと。

**自分の tailnet なら、もう 1 つおまけが付く。**
Tailscale の管理画面には **SSH Console**（ブラウザ内で動く WebAssembly の SSH。beta）があり、
**アプリを一切入れずにブラウザだけで端末が出る。**
ただし **tailnet の Owner / Admin 権限が要る**ので、
**いまの共有 tailnet では Ken は使えない**（Ken は `group:members`）。
自分の tailnet を作れば Owner になるので使える。

ソフトキーボードの問題（§6.1）は残るので日常使いには向かないが、
**「アプリを入れていない端末からの緊急の 1 手」としては強い。**

> **未検証**: `ken-ty.github` の tailnet に現在どのノードが入っていて ACL がどうなっているか。
> **profile を切り替えないと見えない**（切り替えると現在の tailnet が落ちるので、Ken の判断待ち）。
> SSH Console が iOS Safari で実用に足りるか（beta かつ Esc が打てない見込み）。

### 2.4 【解決】profile を切り替えたら制約が消えた（2026-08-25 実測）

`tailscale switch b2fa` → `tailscale up` の後、同じ netmap を見るとこうなった。

| | `f426`（tonegawa さん） | **`b2fa`（`ken-ty.github`）** |
| --- | --- | --- |
| `PacketFilter` | **`[]`（空。誰も届かない）** | **1 本。tailnet 全域 → 全ポート（既定 ACL）** |
| `SSHPolicy.rules` | **`[]`** | **1 本（`holdAndDelegate` = check モード）** |
| Ken の cap | `members` | **`cap/is-owner` + `cap/is-admin`** |
| MagicDNS | `tail67c417.ts.net` | **`tail71c81f.ts.net`** |

**§2 の「最大の制約」は消えた。ACL を人に頼む必要は無い。**
Owner なので SSH Console（§3.4）も条件を満たす。

#### 2.4.1 残っている 3 つ

| # | 何 | いま | 要る操作 |
| --- | --- | --- | --- |
| 1 | ~~Tailscale SSH が無効~~ | **解決。`RunSSH: true`**（2.4.2） | GUI 版を捨てて Homebrew の `tailscaled` へ移行した |
| 2 | **HTTPS 証明書が未有効** | `CertDomains: null` | 管理画面 → DNS → HTTPS Certificates。**`tailscale serve` を使う竹案でのみ必要。梅案には不要** |
| 3 | ~~iPhone がこの tailnet に居ない~~ | **解決。`iphone-14` が参加済み**（2026-08-25） | — |
| 4 | **SSH ポリシーは check ではなかった**（下記） | `accept` の rule が自分の端末ぶん自動で生えている | **たぶん何もしなくてよい。** 実地で確かめる |
| 5 | ~~不要ノードが 2 つ~~ | **解決**（2026-08-25 に削除済み） | — |
| 6 | ~~鍵の期限~~ | **解決。両ノードとも Expiry disabled** | — |

#### 2.4.5 SSH ポリシーは自動で `accept` になっていた

iPhone が参加した後の netmap を見ると、**rule が 3 本に増えていた**（実測）。

```
1. accept          → 100.65.153.3   (kenty-work-mac-1  = 自分)
2. accept          → 100.120.191.88 (iphone-14)
3. holdAndDelegate → 上の両方        (既定 ACL の check ルール)
```

**SSH ポリシーは先頭から順に評価され、最初に一致した rule が効く。**
iPhone は 2 番目の `accept` に当たるので、**3 番目の check には落ちない。**

つまり **ブラウザ認証は要らない見込み**で、初版に書いた「12 時間ごとに Safari を往復」は
**当たらない可能性が高い**。同じ利用者が持つ端末どうしには accept が自動で生えるらしい
（Tailscale 側の実装は未確認）。

**2026-08-25 に実地で確認した。ブラウザ認証は出なかった。** 予測どおり。

#### 2.4.2 【確定】macOS では Tailscale SSH のサーバが動かない

```console
$ tailscale set --ssh
The Tailscale SSH server does not run in sandboxed Tailscale GUI builds.
```

**`RunSSH` は `false` のまま。** このビルドは App Store 版ではなく standalone
（`io.tailscale.ipn.macsys`、実測）だが、**GUI ビルドである時点で対象外。**

| 効き方 | 内容 |
| --- | --- |
| 経路 | **影響なし。** ACL は tcp:22 を含む全ポートを許可している（§2.4） |
| 認証 | Tailscale の identity に寄せられない。**macOS の sshd で鍵を管理する** |
| **SSH Console（§3.4）** | **使えない。** あれは Tailscale SSH が前提。**管理画面案はこの Mac では消える** |

**代わりに macOS の Remote Login を使う。** いま **sshd は動いていない**
（`lsof -iTCP:22 -sTCP:LISTEN` が空、`com.openssh.sshd` 未ロード。実測）。

```sh
sudo systemsetup -setremotelogin on     # または システム設定 → 一般 → 共有 → リモートログイン
```

**sudo が要るので人が実行する。** 有効化したら、Tailscale の IP / MagicDNS 名
（`kenty-work-mac.tail71c81f.ts.net`）宛てに普通の SSH で入れる。

#### 2.4.3 【実施】GUI を捨てて Homebrew の `tailscaled` へ移行した（2026-08-25）

**初版では「採らない」と書いたが、Ken の判断で移行した。結果として正解だった。**

```console
$ tailscale version   # client / daemon が一致（GUI 時代はバージョン警告が出ていた）
1.102.3
$ tailscale debug prefs | jq -c '{RunSSH}'
{"RunSSH":true}
```

| 手順 | 実行 |
| --- | --- |
| バックアップ | `sudo cp -a /Library/Tailscale /Library/Tailscale.bak` |
| 削除 | `sudo rm -rf /Applications/Tailscale.app /usr/local/bin/tailscale` |
| 常駐 | `sudo brew services start tailscale`（`homebrew.mxcl.tailscale`） |
| ログイン | `tailscale up --ssh` |

**`macOS の Remote Login は不要になった。** `sudo systemsetup -setremotelogin on` は
Full Disk Access が要って弾かれていたが、Tailscale SSH が動くので回避できた。

**副作用が 3 つ。すべて移行の必然。**

1. **ノードが二重になった。** Homebrew 版は state を `/var/root/.local/share/tailscale/`
   に新規作成するのでノード鍵が別物になり、**新しいマシンとして登録された**。
   名前が衝突して `kenty-work-mac-1` になっている。旧ノードを消してから
   `tailscale set --hostname=kenty-work-mac` で戻す
2. **`rito.aither@gmail.com` の profile が消えた。** 復活には再認証が要り、
   そのとき tonegawa さんの tailnet に新しいデバイスが 1 台増える
3. **`brew upgrade tailscale` に手作業が要る。** `sudo brew services` で起動したため、
   brew が案内する `sudo rm` を手で実行する必要がある

> **`/Library/Tailscale` と `/Library/Tailscale.bak` は消さない。**
> `rito.aither@gmail.com` 側の profile が残っているのはそこだけ。

#### 2.4.4 鍵の有効期限が最大の運用リスク

```console
$ tailscale status --json | jq -r '.Self.KeyExpiry'
2027-02-21T13:10:31Z
```

**Tailscale のノード鍵は既定で約 180 日で切れ、切れると tailnet から落ちる。**
外出先アクセスの土台がこれで死ぬ。

**実例が同じ tailnet にある** — `c-0017`（Closer 案件で使っていた Linux）は
`Expired Jun 16, 2026` になっている。

**`kenty-work-mac-1` と `iphone-14` は管理画面で Disable key expiry にする。**
常時稼働の遠隔アクセス機に期限を残す理由が無い。

---

## 3. 方式の比較

以下 3 案はすべて **§2 の ACL が外れていること**が前提。
外れていない今日でも動く「第 0 案」を先に置く。

### 3.0 【第 0 案】`ccs peek` — 何も繋がなくても「見る」だけは今日成立する

**新しいネットワーク経路を 1 本も作らずに R を満たせる。** ROADMAP の P1 そのもの。

```
iPhone の Claude アプリ
   └─ Remote Control（Mac からの outbound。ACL も開放も要らない）
        └─ cc/hub の Claude
             └─ Bash: ccs peek tmp-3
                  └─ tmux capture-pane -p -t cc/tmp-3
                       └─ テキストが会話に返ってくる
```

`ccs hub status` は `healthy` で `bridge` も付いている（実測）。**この経路は既に生きている。**

| | |
| --- | --- |
| 必要なコンポーネント | `ccs peek <slug> [-n <行数>]` サブコマンド 1 つ（`capture-pane` の薄いラッパー） |
| スマホ側の体験 | チャットに 80×24 のコードブロックが出る。更新は「もう一回聞く」。リンクはタップできる |
| 実装量 | **数十行 + テスト。** ccs の 4 責務を増やさない（既存 tmux セッションを読むだけ） |
| 危険度 | **ほぼゼロ。** 新しいリスナーも待ち受けポートも増えない |
| 限界 | ライブでない。**打てない。** 「端末を触っている感」は無い |

**注意**: ペインの中身が Remote Control を通って Anthropic のクラウドを経由する。
RC を使っている時点で会話は既にそうなっているが、**端末の生の出力（パス・環境変数・
コマンド履歴）が新たに流れる**点は自覚しておく。

---

### 3.1 【訂正】ttyd は「キーバーを足せない」— これは誤りだった

**2026-08-22 の初版でこう書いた:**

> ttyd の画面は単一バイナリに埋め込まれた index.html なので、キーバーを足すには
> ttyd を改造することになる

**間違い。** ttyd には公式に **`-I, --index <path>`（Custom index.html path）** があり、
**フロントエンドを丸ごと自分のものに差し替えられる**（[man ttyd(1)](https://man.archlinux.org/man/extra/ttyd/ttyd.1.en)）。
`-t, --client-option` で xterm.js の設定をサーバ側から渡す口もある。

**この訂正で、松と竹の区別が消えた。** 下の 3.2 に統合する。

---

### 3.2 竹 — ttyd をバックエンドにして、**フロントだけ自作する**

```
iPhone Safari（ホーム画面に追加 → standalone PWA）
  └─ https://kenty-work-mac.tail67c417.ts.net/    ← Tailscale Serve（TLS + tailnet 認証）
       └─ 127.0.0.1:7681
            ttyd -i 127.0.0.1 -W -I ~/ccs-mobile/index.html tmux new-session -A -s mobile
                 └─ 本物の pty。tmux がそのまま動く
```

**自分で書くのは `index.html` 1 枚だけ。** pty も tmux の attach もスクロールバックも
コピーモードも **ttyd が本物でやる**。

| | |
| --- | --- |
| コンポーネント | `brew install ttyd` / `index.html` 1 枚 / launchd 1 本 / `tailscale serve` 1 行 / **ACL 1 行** |
| 実装量 | **HTML + JS 1 枚（100〜200 行）。** サーバのコードは書かない |
| 危険度 | 中。`-W` はフルシェル。**127.0.0.1 bind + Serve 前置が必須** |

**フロントを持つと、松の致命傷が 2 つとも消える。**

1. **キーバーを置ける。** Esc / Ctrl / Tab / shift+Tab / 矢印 / Ctrl-C。§6.1 の要件を素直に満たす
2. **リサイズを送らなければ window が潰れない。** ttyd のプロトコルでは
   **クライアントが cols/rows を送る側**。自作フロントが resize を送らない
   （または 80×24 固定で送る）なら、tmux の window は縮まない。
   §6.3 の `window-size` 設定と二重に効かせられる

さらに Ken の言う「表示コントロール」がここで効く。**他人のページでは絶対にできない部分。**

- フォントサイズのスライダー、ピンチズーム（CSS transform）
- 80 桁固定 + 横パン / 横向きロック
- セッション一覧（`ccs ls --json`）をタップで切り替え。**tmux の prefix を打たせない**
- 「1 行組んでから送信」と「キー直送」の切り替え（§6.5 の遅延対策）

> **未検証**: resize を送らないとき ttyd が pty をどのサイズで作るか（既定 80×24 の想定）。
> **10 分で確かめられる。**

**旧・竹（`capture-pane` を自前 WS で流す案）は退ける。** ttyd を使えば
スクロールバックとコピーモードが本物で手に入る。自前実装ではそこが落ちていた。

---

### 3.3 梅 — 何も作らない（Tailscale SSH + iOS の SSH クライアント）

```
iPhone の Termius / Blink Shell
  └─ ssh apple@kenty-work-mac.tail67c417.ts.net -t 'ccs attach tmp-3'
       └─ 本物の pty。tmux がそのまま動く
```

| | |
| --- | --- |
| コンポーネント | **ACL 1 行（+ ssh ブロック）。それだけ。** Mac 側は `tailscale set --ssh` |
| スマホ側の体験 | SSH クライアントのキーバーをそのまま使う。**一番難しい部分を完成品に任せる** |
| 実装量 | **ゼロ。** ccs は `attach` を既に持っている |
| 危険度 | 低〜中。tailnet 内に閉じる。**自作の認証コードが 1 行も無い**のが効く |

弱点と対処:

| 弱点 | 対処 |
| --- | --- |
| attach で window がリサイズされる | `set -g window-size largest`（§6.3）。ccs の既定に入れる |
| セッション一覧が tmux の prefix 頼み | **slug ごとに SSH ホストを登録する。** アプリのホスト一覧がそのまま盤面になる |
| 表示の作り込みができない | できない。アプリが持っているものが上限 |

#### 3.3.1 クライアントの選定 — **Termius が shift+Tab を明示的に持っている**

**§9 の未検証 #1 は解決した**（2026-08-22、公式 changelog で確認）。

Termius の iOS changelog に、そのままの記述がある:

> **v6.3.0 (2025-08-25)** — Added **Shift+Tab** to the additional keyboard in Terminal,
> **enabling actions for Claude Code and other AI tools**
>
> **v6.3.1 (2025-09-08)** — Added an ability to bind Shift+Tab to a volume button

**Claude Code を名指しで対応した唯一のクライアント。** これで §6.1 の必須キーが全部揃う。

| クライアント | 料金 | Mosh | Esc/Ctrl | shift+Tab | 備考 |
| --- | --- | --- | --- | --- | --- |
| **Termius** | **SSH は無料**（同期・多デバイスが有料） | ○ | ○ | **◎ 公式対応** | 音量ボタンに割当も可。Win/Mac/Linux 版もある |
| **Blink Shell** | Blink+ **$19.99/年**（14 日試用）。GPL なので自前ビルドは無料 | **◎ ネイティブ** | ○ Smart Keys（Caps/Shift タップを Esc に割当可） | 未確認 | **Tailscale 連携の公式ドキュメントを持つ**。端末エミュレータの質は最上位 |
| **Prompt 3**（Panic） | 有料 | ○（+ Eternal Terminal） | ○ | 未確認 | Secure Enclave / YubiKey |
| **Secure ShellFish** | 約 $30 買い切り | △ | ○ | 未確認 | **Files.app 統合**が売り |
| iSH / a-Shell | 無料 | × | ○ | 未確認 | ローカル環境から `ssh` を打つ。逃げ道として有効 |

**まず Termius（無料）で試し、端末の質に不満が出たら Blink へ。**

> **Blink も Termius も Tailscale を内蔵しない。** どちらも
> **Tailscale の公式 iOS アプリが別途必要**（Blink の
> [Tailscale + Mosh ドキュメント](https://docs.blink.sh/integrations/tailscale+mosh)に明記）。

#### 3.3.2 Mosh を使う — 回線の遅延に効く唯一の手

**§6.5 で「打鍵の遅れはどの方式でも同じ」と書いたが、Mosh だけは例外。**

ローカルエコーを予測表示し、IP が変わっても切れない。
自宅の 5G CPE は負荷時の上り遅延が中央 308ms（実測）なので、ここが一番効く。

- Termius / Blink / Prompt 3 はいずれも Mosh に対応
- Mac 側に `mosh-server` が要る（`brew install mosh`）
- Mosh は **UDP 60000-61000**。§2.2 の grant は `ip: ["*"]` なので追加の穴は要らない

**Web 案（3.2）では Mosh が使えない。** これは梅の固有の強み。

---

### 3.4 Tailscale の管理画面（SSH Console）で済ませる案

**「既製の端末が既にブラウザにあるのだから、それでいいのでは」という筋。正しい直感で、
利点も本物。ただし 3 点で引っかかる。**

Tailscale の管理画面には [SSH Console](https://tailscale.com/docs/features/tailscale-ssh/tailscale-ssh-console)
がある。WebAssembly でブラウザの中に Tailscale クライアント・WireGuard・
ユーザスペースのネットワークスタック・SSH クライアントを丸ごと積んで動く。

**利点（他のどの案にも無い）:**

- **スマホに何もインストールしない。** SSH クライアントも Tailscale アプリも要らない
- **スマホが tailnet に入らなくていい。** ブラウザの中の wasm が一時ノードになる。
  §2.2 の ACL 依頼から「Ken の iPhone を tailnet に入れる」部分が丸ごと消える

**引っかかる点:**

| # | 何 | 効き方 |
| --- | --- | --- |
| 1 | **tailnet の Owner / Admin 権限が要る** | Ken は `group:members`。**いまの共有 tailnet では使えない。** 自分の tailnet（§2.3）を作れば Owner になるので使える |
| 2 | **beta** | 仕様が動く。壊れたときに直す手が無い |
| 3 | **ソフトキーボードの問題が素のまま残る** | Esc が打てない（§6.1）。**走っている Claude を止められない** |

そして **ACL の変更は結局要る**（Tailscale SSH は port 22 の grant と `ssh` ブロックの
両方を見る）。ここは省けない。

#### 3.4.1 ラッパーで仮想キーボードと表示を足せるか → **できない**（実測）

**管理画面を iframe に入れて上からキーバーを重ねる、はブラウザが拒否する。**

```console
$ curl -sI https://login.tailscale.com/admin/machines | grep -o "frame-ancestors '[^']*'"
frame-ancestors 'none'
```

CSP の `frame-ancestors 'none'`。**iframe に入らない。** 仮に入っても、
**cross-origin の document に合成キーイベントは注入できない**（同一生成元ポリシー）。
これは実装の難易度ではなく、**ブラウザが構造的に禁じている**。

残る道は 2 つ。どちらも「自分でフロントを持つ」より高くつく。

| 道 | 何が要るか | 判定 |
| --- | --- | --- |
| **Safari Web Extension** でコンテンツスクリプトを刺す | Xcode プロジェクト + App Store 配布か開発者証明書。**beta の Tailscale の DOM 構造に依存する** | **不採用。** 3.2 が HTML 1 枚で済むのに、こちらは配布まで必要 |
| Tailscale の wasm クライアント（[tsconnect](https://github.com/tailscale/tailscale/tree/main/cmd/tsconnect)）で**管理画面を自作する** | そのページをどこかにホストする必要がある。**「スマホから届く場所が無い」という §2 の問題に戻る** | 不採用。鶏と卵 |

**結論: この Mac では管理画面 SSH Console は使えない。**
**Tailscale SSH が前提**だが、macOS の GUI ビルドではサーバが動かない（§2.4.2 実測）。
Linux ノード（`c-0017` など）を tailnet に足したときには有効な手なので、
**選択肢としては残すが、MacBook Pro の経路にはならない。**

---

### 3.5 一覧

| | 第 0 案 `ccs peek` | 竹 ttyd + 自作フロント | 梅 SSH クライアント | 管理画面 SSH Console |
| --- | --- | --- | --- | --- |
| 見る / ライブ | 静止画 | ◎ | ◎ | ◎ |
| 打つ | △ hub 経由 | ○ | ◎ | △ Esc が打てない |
| 実装量 | 数十行 | **HTML 1 枚** | **ゼロ** | **ゼロ** |
| ACL 変更 | **不要** | 要る | 要る | 要る |
| スマホに入れるもの | 無し | 無し（PWA） | アプリ 2 本 | **無し** |
| スマホが tailnet に入る必要 | 無し | **要る** | **要る** | **不要** |
| キーバー | — | ◎ 自作 | ◎ Termius | **×** |
| 表示コントロール | × | **◎ 自由** | △ アプリ依存 | × |
| Mosh（遅延対策） | — | × | **◎** | × |
| 権限の壁 | 無し | 無し | 無し | **Owner/Admin 必須** |
| 保守 | 小 | 中（自分の HTML） | **ゼロ** | ゼロ（beta 追従は要る） |

---
## 4. 実測メモ — いまの tmux はどうなっているか

設計の前提として確かめたもの（2026-08-22）。

- **セッションは 17 本**（`cc/` 接頭辞、hub 含む）。`ccs ls --json` は
  `slug` / `status` / `sessionId` / `path` / `tmux` を返す
- **全部 1 window / 1 pane。** 唯一 `cc/x01` が 106×34 で、これは人が attach した跡。
  他は全部 **80×24**（未 attach の既定）
  → **「狭い画面で tmux のペインをどう扱うか」という問題は、いまのところ存在しない。**
  効いてくるのは分割ではなく**桁数**（§6.2）
- `tmux -V` = 3.7b / `window-size` = **latest** / `history-limit` = 2000 / `default-terminal` = tmux-256color（すべて実測）
- `~/.tmux.conf` は無い。**tmux の既定のまま**
- `capture-pane -p` は 1502 バイト、`-e`（エスケープ付き）で 1915 バイト。
  Claude Code の TUI は 256 色と OSC 8 ハイパーリンクを使っている（実測）
- macOS の Application Firewall は有効（block-all ではない）。
  **127.0.0.1 に bind すればダイアログは出ない**ので、Serve 前置の構成は
  「留守中に承認ダイアログで止まる」事故を踏まない

---

## 5. 認証と露出

### 5.1 tailnet に閉じる。外には出さない

**Tailscale Funnel も Cloudflare Tunnel もポート開放も採らない。** 理由:

- 待ち受けているのは **フルシェル**。tmux の中には Claude Code が居て、`~/.claude` の
  認証情報も ghq 配下の全リポジトリも同じ権限で触れる。**認証を 1 回間違えたら
  マシンごと持っていかれる**
- 自宅回線は 5G CPE で、そもそも**ポート開放という選択肢が無い**
  （キャリアのコア網の内側。[[my-tokura-house-network]]）。
  外に出すなら必ず「外部サービスにトンネルを張る」形になり、**その事業者が経路上に乗る**
- Tailscale Serve なら **TLS 終端も認証も tailnet が持っている**。
  自作の認証コードを 1 行も書かない、が最大の安全策

### 5.2 露出の設計

| 層 | どうする |
| --- | --- |
| bind | **`127.0.0.1` のみ。** LAN にも出さない（macOS の firewall ダイアログも回避できる） |
| 経路 | `tailscale serve` が tailnet → loopback に proxy する |
| 認証 | tailnet のデバイス認証。アプリ側に認証を実装しない |
| 認可 | ACL で `autogroup:self` に閉じる。**共有機 `tag:server` の grants は触らない** |
| 鍵 | 端末が失われたら Tailscale の管理画面からそのノードを失効させる。**これが唯一の失効手段になる**ので、パスワードやトークンをアプリ側に持たせない |

### 5.3 家の LAN 直結は「無し」でよいか

同じ Wi-Fi に居るなら `192.168.3.4:7681` に直接繋げる。ACL も要らない。
だが **外出先で使えないなら要件を満たさない**し、LAN に口を開けると
127.0.0.1 bind の利点（firewall ダイアログが出ない・LAN 上の他の端末に見えない）を捨てることになる。
**採らない。**

---

## 6. スマホの UX — ここが実際の使い勝手を決める

### 6.1 ソフトキーボードは「あれば嬉しい」ではなく成立条件

Claude Code のペインの最下行には、実測でこう出ている:

```
auto mode on (shift+tab to cycle) · esc to interrupt · ⌥⏎ for agents
```

**iOS のソフトキーボードには Esc も Ctrl も Tab も矢印も無い。**
つまり次が出せない端末は、`ccs` のセッションを触れない。

| キー | 何に要るか | 優先度 |
| --- | --- | --- |
| **Esc** | 走っている Claude を止める | **必須。これが無いと危険** |
| **Ctrl** | Ctrl-C / Ctrl-D / Ctrl-B（tmux prefix） | **必須** |
| **↑ ↓** | 履歴、Claude の選択肢の移動 | **必須** |
| **Tab** | 補完、Claude の選択肢 | 高 |
| **shift+Tab** | permission mode の切替 | 中（無くても死なない） |
| **⌥⏎ / Esc+Enter** | 改行を入れずに送る系 | 低 |

**竹**は自分でバーを置くので全部出せる。**梅**は SSH クライアントのバー頼み（§3.3 の未検証）。
**素の ttyd フロントと Tailscale の管理画面は出せない。**

### 6.2 狭い画面 — 問題は「分割」ではなく「桁数」

いまのセッションは全部 1 pane（§4）なので、**ペイン分割の UI は要らない。**
効いてくるのはこっち。

- 80 桁を iPhone の縦画面に収めると 6〜7pt 相当。**読めない**
- 現実的な選択肢は 3 つ。**どれか 1 つに決め打つ**
  1. **横向き固定 + 80 桁。** 一番素直。Claude Code の TUI は 80 桁で組まれている
  2. **縦 + 横スクロール。** 80 桁のまま、指で横に流す。折り返さないので TUI が壊れない
  3. **縦 + 狭い幅で再描画。** window を 45 桁くらいに縮める。**Mac 側の表示も潰れる**（§3.1）。採らない
- **竹なら「読むときだけ折り返す」ができる**（`capture-pane -J` で折り返しを解いてから
  自分で整形する）。ライブの TUI では崩れるので、**ログを読み返すとき専用のモード**として持つ

### 6.3 tmux のリサイズ事故を先に塞ぐ

**これは方式に関係なく効く。`ccs` 側の話。**

いまは `window-size latest`（実測）。**最後に繋いだクライアントの大きさに window が合う。**
スマホが繋いだ瞬間に、Mac で開いていた画面まで一緒に潰れる。

```sh
# ccs new が立てる tmux セッションに対して
tmux set -t "cc/<slug>" window-size largest
```

`largest` なら、小さいクライアントは大きい window の一部を覗く形になる。
**スマホが入っても Mac 側は変わらない。** 代わりにスマホは全体が見えないので、
「見る」用途では `manual` + `-x 80 -y 24` 固定のほうが素直かもしれない。

> **未検証**: `largest` と `manual` のどちらがスマホで実用的か。**実機で 5 分試せば決まる。**

### 6.4 セッション一覧（tmp-N）からの遷移

**スマホで tmux の prefix（Ctrl-b s）を打たせない。** 入口を `ccs ls` にする。

| 案 | やり方 |
| --- | --- |
| 竹 | `GET /api/sessions` → `ccs ls --json` をリスト表示。タップで WS を張り替えるだけ |
| 梅 | **slug ごとに SSH ホストを登録する。** 接続先 `-t 'ccs attach tmp-3'` を並べれば、アプリのホスト一覧がそのまま盤面になる。セッションが増えたら手で足す（`ccs ls` を見て） |
| 第 0 案 | hub に「一覧出して」と言う。`ccs ls` の出力がそのまま返る |

**梅の「手で足す」は欠点に見えるが、`ccs` のセッションは長生きするので実際には滅多に増えない**
（いまの 17 本は 4 日ぶん）。

### 6.5 回線 — 帯域ではなく遅延が効く

自宅は 5G の CPE。**上り 21〜23 Mbps、負荷時の上り遅延が中央 308ms / 最大 2294ms**
（実測値は [[my-tokura-house-network]]）。**Mac → スマホの向きは家の「上り」。**

- **帯域は問題にならない。** 1 フレーム 2 KB（実測）× 2 Hz = 4 KB/s。上りの 0.2%
- **効くのは打鍵の遅れ。** 端末は文字単位でエコーするので、家が何かアップロードしている
  最中は 1 文字ごとに 300ms 以上待たされうる。**これは回線由来なのでどの方式でも同じ**
- **竹だけが緩和できる。** 「1 行組み立ててから送信」なら、往復は 1 行に 1 回で済む。
  ただしその代償として、Claude の TUI の 1 キー操作（y/n の選択など）には向かない。
  **キーバーの直送と行送信を両方持つ**のが正解

---

## 7. 推奨と、その順序

### 7.1 推奨は **梅（Tailscale SSH + iOS の SSH クライアント）**

「シンプルでいい」に照らすと、**答えは「作らない」。**

1. **書くコードがゼロ。** `ccs attach` は既にある。保守するものが増えない
2. **一番難しい部分（キーバー）を完成品に任せられる。** §6.1 は自作すると地味に重い。
   しかも **Termius は Claude Code の shift+Tab を名指しで実装済み**（§3.3.1）
3. **認証を自分で書かない。** §5 のとおり、待ち受けているのはフルシェル。
   自作の認証コードは、それ自体が最大のリスク
4. **`ccs` の 4 責務（[design.md §1](design.md#1-結論)）を膨らませない。**
   足すのは `window-size` の既定だけ

### 7.2 ただし着手の順序はこうなる

| 順 | やること | 待ちか | 理由 |
| --- | --- | --- | --- |
| 1 | **`ccs peek <slug>` を入れる**（第 0 案 / ROADMAP P1） | **待ち無し** | ACL と無関係に「見る」が今日成立する。ROADMAP に既にある項目 |
| 2 | **`window-size` の既定を決めて `ccs new` に入れる**（§6.3） | **待ち無し** | どの方式でも要る。実機で 5 分 |
| 3 | ~~iOS の SSH クライアントのキーバーを確かめる~~ | — | **解決。Termius が Claude Code 向けに shift+Tab を公式対応（§3.3.1）。App Store から入れておく** |
| 4 | **ACL の 1 行を tonegawa さんに依頼する**（§2.2） | **待ち** | 共有機に触らない形で頼めるので通りやすいはず |
| 5 | 4 が通らない / 遅いなら **自分の tailnet を作る**（§2.3） | 待ち無し | 他人の承認に依存しない逃げ道 |
| 6 | 経路が通ったら **梅を 30 分試す** | — | 駄目なら竹へ |

**竹は「梅を実際に使って不満が出てから」。**
セッション一覧のタップ遷移も、フォントサイズも、**欲しくなってから作れば間に合う。**

ただし **§3.1 の訂正で竹の値段が下がった**（サーバを書かず `ttyd -I` に HTML 1 枚）ので、
梅で不満が出たときの移行はかなり軽い。**「表示を自分で作り込みたい」が動機なら竹一択**
（アプリも管理画面も、他人のページなので手が入らない — §3.4.1）。

**素の ttyd と管理画面（SSH Console）は本命にしない。** どちらも Esc が打てず
（§6.1）、**走っている Claude を止められない**ため。
ただし管理画面は「何も入れていない端末からの緊急の 1 手」として残る（§3.4）。

### 7.3 要件の確定（2026-08-24、Ken）

**優先順位が決まった。**

| # | 要件 | 効き方 |
| --- | --- | --- |
| 1 | **外出先からアクセスしたい**（最優先） | **経路が本題。** §2 の ACL を解くのが全て。UI は後 |
| 2 | **複数ターミナルを同時に操作したい** | 1 本を切り替える設計から、**並べる設計**へ |
| 3 | **固定 6 枠でよい** | 動的な一覧が要らない。**フロントが劇的に簡単になる** |
| 4 | **端末は iPhone**（タブレットではない） | 6 面を同時表示は捨てる。**タブ 6 枚 + 1 面表示** |

#### 7.3.1 経路は「自分の tailnet」で確定する

要件 1 が最優先なら、**共有 tailnet の ACL 依頼は待ちが読めないので採らない。**
§2.3 の自分の tailnet に倒す。

**mini を失う影響は小さい**ことを確かめた:

- `ssh macmini` / `macmini-admin` は **mDNS（`asakusanoMac-mini.local`）宛て**なので、
  tailnet のプロファイルを切り替えても**家の LAN では今までどおり動く**
- 失うのは **外出先からの Gatus / Open WebUI** だけ（tailnet の 443 / 8443）

#### 7.3.2 「固定 6」を `ccs` の枠の話に持ち込まない

**[ADR-0001](adr/0001-scratch-workspace-identity.md) が固定 8 枠をやめたばかり**
（Accepted / 2026-08-20）。理由は枠の番号とセッション名がズレること、
汚れた枠が二度と配られないこと。

**モバイル側の「固定 6」は画面の都合であって、作業ディレクトリの割り当てではない。**
混ぜると ADR-0001 が捨てた罠をそのまま踏む。

```
ccs の枠   … セッションごとに一意（ADR-0001）。動的でよい
スマホの 6 … 画面に出す tab の本数。人が 6 個ピン留めするだけ
```

`CCS_SCRATCH_SLOTS` を 6 にする必要は無い。**触らない。**

#### 7.3.3 6 ターミナルをどう出すか

| | 今日（コードゼロ） | その先（HTML 1 枚） |
| --- | --- | --- |
| 方式 | **Termius に 6 ホスト登録** — 接続先を `-t 'ccs attach tmp-3'` にして 6 個並べる | `ttyd -I` の自作フロントに **タブ 6 枚**。1 本の WebSocket のまま、タブは `tmux switch-client -t cc/<slug>` を送るだけ |
| 同時接続 | **Termius の無料 Starter でマルチタブ・split view が使える**（[公式](https://termius.com/pricing)）。6 セッション並走に課金は要らない | 1 接続で 6 面。切替は即時（再接続なし） |
| 切替 | アプリのタブ | 自作のタブバー |
| 表示制御 | アプリ任せ | フォント・桁数・向きを自分で持てる |

**まず Termius。** 6 ホストを登録するだけで要件 1〜4 が全部埋まる。
不満（表示制御・切替の速さ）が出たら ttyd 版へ。

---

## 10. 【実証】2026-08-25、iPhone から通った

**梅案は机上ではなく実地で成立した。** 設計の未検証はすべて潰れた。

```
Last login: Tue Aug 25 22:09:37 on ttys009
apple@kenty-work-mac ~ % echo hoge
hoge
```

### 10.1 通った構成

| 層 | 実際の値 |
| --- | --- |
| tailnet | `ken-ty.github`（Ken が Owner） |
| Mac | `kenty-work-mac-1` / `100.65.153.3`、Homebrew の `tailscaled` 1.102.3、`RunSSH: true` |
| iPhone | `iphone-14` / `100.120.191.88`、**Tailscale**（iOS アプリ） |
| クライアント | **Termius**（iOS アプリ） |
| 認証 | **パスワードも鍵も設定していない。** Tailscale SSH が持つ |
| 初回のみ | ホスト鍵（ECDSA）の確認ダイアログ → Continue |

### 10.2 確定したこと

1. **Tailscale SSH はサードパーティの SSH クライアントで通る。** Termius から
   パスワードも鍵も無しで入れた。**§2.4.2 で macOS の Remote Login に倒す必要は無かった**
2. **ブラウザ認証（check モード）は出なかった。** §2.4.5 の読みどおり、
   同じ利用者の端末どうしには `accept` の rule が先に当たる
3. **Termius のキーバーに必要なキーが全部並ぶ**（実機のスクリーンショットで確認）:
   **`shift tab` / `?` / `/` / `|` / `esc` / `tab` / `ctrl` / `alt` / `^`**
   → **§6.1 の「成立条件」を素の状態で満たしている。**
   おまけに `Ask AI to generate a command` の入力欄まで付いている

### 10.3 実際に踏んだ罠

| 罠 | 症状 | 対処 |
| --- | --- | --- |
| **MagicDNS 名のタイプミス** | `tail171c81f`（`1` が 1 つ多い）と打って `Address resolution finished with error: unknown node or service` | **Tailscale アプリのコピーボタンから貼る。** 手で打たない。IP (`100.65.153.3`) のほうが安全 |

**接続できない原因の 1 番目は名前のタイプミス。** `tail71c81f` のような文字列は
目視で検算できない。

### 10.4 蓋スリープ対策は Amphetamine で解決

`sudo pmset -a disablesleep 1` は使わず、**Amphetamine**（Mac App Store）を導入した。
sudo も要らず、GUI から状態が見えるのでこちらのほうが素直。

### 10.5 スマホ側の入口 — `ccs attach`（slug を省く）

**`ccs attach` を引数なしで打つと、いまあるセッションが番号付きで出る。**
ソフトキーボードで slug を打つのは高くつくし、`ccs ls` を見てから打ち直す往復も同じ。

```
 7) tmp-1                  waiting
 8) tmp-2                  idle
...
番号 (Enter で中止):
```

**セッションの顔ぶれが変わっても壊れない**ので、「固定 6 枠」を `ccs` 側に持ち込まずに
（§7.3.2）スマホ側の要求を満たせる。複数同時に触るときは **Termius のタブ**を並べ、
それぞれで別の番号を選ぶ。

**新しい概念は増やしていない。** これは `ccs ls` + `ccs attach` の言い換えで、
出す情報は `ccs ls` と同じものを絞ったもの。決めるのは人。
端末が無ければ（スクリプトやハブから引数なしで呼ばれたら）**従来どおり 2 で落ちる** —
黙って入力を待って固まるより、その場で落ちるほうが原因に辿り着ける。

---

## 8. やらないこと（スコープ外）

| やらない | 理由 |
| --- | --- |
| **複数ユーザ対応** | 使うのは Ken だけ。ACL を `autogroup:self` に閉じる前提と矛盾する |
| **外部公開**（Funnel / Cloudflare Tunnel / ポート開放） | §5.1。フルシェルを外に出さない。回線的にも不可能 |
| **ファイル転送・アップロード** | `scp` / `rsync` がある。Web に足すと露出面だけ増える |
| **録画・リプレイ** | 会話の記録は `~/.claude/projects/**.jsonl` に既にある |
| **プッシュ通知** | [design.md §8.1](design.md) で「hub の異常は hub.log にだけ書く。外部送信はしない」と決めている。ここを崩さない |
| **Claude の TUI へのプロンプト注入** | [design.md §3](design.md)。会話は `SendMessage`。送るのは制御キーと、別 window のシェルにだけ（§1.1） |
| **ペインの分割操作 UI** | いまのセッションは全部 1 pane（実測 §4）。存在しない問題 |
| **`ccs` 本体に Web サーバを入れる** | 4 責務に 5 つ目を足さない。竹をやるなら別リポジトリか `contrib/` |
| **自作の認証** | §5.2。tailnet に任せる |
| **Windows 対応** | ccs が対象外にしている |

---

## 9. 未検証の一覧（採用前に潰すもの）

**§10 のとおり、1〜5 と 7 は 2026-08-25 に解決した。以下は履歴。**

| # | 何 | どう確かめるか | 重み |
| --- | --- | --- | --- |
| ~~1~~ | ~~iOS の SSH クライアントが **shift+Tab** を出せるか~~ | **解決。Termius v6.3.0 が Claude Code 向けに公式対応（§3.3.1）** | — |
| 2 | `grants` で `dst: ["autogroup:self"]` が通るか | tonegawa さんに適用してもらう | **高**（全案の前提） |
| 3 | Tailscale Serve の 443 が、その grant で許可されるか | 2 の後に `curl` | 高 |
| 4 | `window-size` は `largest` と `manual` のどちらが実用的か | 実機で 5 分 | 中 |
| 5 | 自分の tailnet に移したとき mini が見えない不便がどれくらいか | 切り替えて 1 日使う | 中 |
| 6 | launchd から立てたプロセスが手元と同じ tmux サーバに入るか | ROADMAP H7 と同じ論点。まとめて確かめる | 中（竹のみ） |
| 8 | **ttyd が resize を受け取らないとき pty をどのサイズで作るか** | `ttyd -I` で resize を送らないフロントを当てて `tmux list-panes` | 中（竹の要） |
| 7 | Claude アプリが `ccs peek` の 80 桁コードブロックを読める形で出すか | hub に 1 回聞く | 低 |

---

## 10. 関連

- 制約の出どころ: [why.md §4](why.md#その独立には代償がある--アプリからターミナルが見えない)
- 送信の方針: [design.md §3](design.md#3-参考にした既存実装)（`send-keys` によるプロンプト注入を採らない）
- 責務の境界: [design.md §1](design.md#1-結論)（自作するのは 4 つだけ）
- バックログ: ROADMAP の P1 / P2、[#19](https://github.com/ken-ty/ccs/issues/19)
- tailnet と共有機の事情: `agent-skills-store` の `my-asakusa-macmini`
- 回線の実測値: `agent-skills-store` の `my-tokura-house-network`
- **NAT の質（2026-08-25 実測）**: `tailscale netcheck` が `UDP: true` /
  `MappingVariesByDestIP: false`（Easy NAT）/ `Nearest DERP: Tokyo`。
  **DERP 中継ではなく直結できる見込み**で、体感遅延に効く
- [Termius iOS changelog](https://docs.termius.com/changelog/ios)（shift+Tab の出どころ）
- [Blink の Tailscale + Mosh ドキュメント](https://docs.blink.sh/integrations/tailscale+mosh)
- [Tailscale SSH Console](https://tailscale.com/docs/features/tailscale-ssh/tailscale-ssh-console)（Owner/Admin 限定）
