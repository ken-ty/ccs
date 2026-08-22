#!/usr/bin/env bats
#
# hub のうち、外部プロセスを起動しなくても確かめられる部分。
#
# **名前の衝突と保護が中心。** `hub` という名前のリポジトリを持っている人が
# 詰まないこと、hub をうっかり畳めないことは、実際に立てなくても検証できる。

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_stub_deps
	export CCS_CONFIG_FILE="${CCS_TEST_TMP}/config"
	export CCS_HUB_HOME="${CCS_TEST_TMP}/hub"
}

teardown() {
	ccs_teardown_sandbox
}

# --- 予約語としての hub ----------------------------------------------------

@test "new: hub は予約語なので、リポジトリとしては開かない" {
	run "$CCS_BIN" new hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs hub up"* ]] || return 1
}

@test "resolve: hub も同じく止まる" {
	run "$CCS_BIN" resolve hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"予約語"* ]] || return 1
}

@test "予約語の案内には、名前を変える手段が書いてある" {
	# **他人の環境では hub というリポジトリがありうる。** 逃げ道を必ず示す。
	run "$CCS_BIN" new hub
	[[ "$output" == *"CCS_HUB_SLUG"* ]] || return 1
	[[ "$output" == *"<owner>/hub"* ]] || return 1
}

@test "hub の名前を変えると、hub は普通のリポジトリ名に戻る" {
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/someone/hub"
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/someone/hub"

	CCS_HUB_SLUG=orchestrator run "$CCS_BIN" resolve hub
	[ "$status" -eq 0 ]
	[[ "$output" == hub*"/hub" ]] || return 1
}

@test "hub の名前を変えると、新しい名前が予約語になる" {
	CCS_HUB_SLUG=orchestrator run "$CCS_BIN" new orchestrator
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs hub up"* ]] || return 1
}

@test "hub と同じ名前のリポジトリは <owner>-<repo> の slug になる" {
	# `cc/hub` は hub のものなので、他のリポジトリに使わせない。
	# 使わせると、立てた瞬間に hub の生死判定が壊れる。
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/someone/hub"
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/someone/hub"

	run "$CCS_BIN" resolve someone/hub
	[ "$status" -eq 0 ]
	[[ "$output" == someone-hub*"/hub" ]] || return 1
}

# --- 保護 -----------------------------------------------------------------

@test "kill: hub は畳めない" {
	run "$CCS_BIN" kill hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"hub"* ]] || return 1
	[[ "$output" == *"ccs hub restart"* ]] || return 1
	[[ "$output" == *"ccs hub down"* ]] || return 1
}

@test "kill: hub は --force でも畳めない" {
	# **ここは逃げ道を用意しない。** 落とすと、スマホから操作する経路が消える。
	run "$CCS_BIN" kill --force hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs hub restart"* ]] || return 1
}

@test "kill: 名前を変えた hub も守られる" {
	CCS_HUB_SLUG=orchestrator run "$CCS_BIN" kill orchestrator
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs hub restart"* ]] || return 1
}

# --- サブコマンドの入口 ----------------------------------------------------

@test "hub: サブコマンド無しは 2 で、何が打てるかを出す" {
	run "$CCS_BIN" hub
	[ "$status" -eq 2 ]
	[[ "$output" == *"ccs hub up"* ]] || return 1
	[[ "$output" == *"ccs hub status"* ]] || return 1
}

@test "hub: 知らないサブコマンドは 2" {
	run "$CCS_BIN" hub bogus
	[ "$status" -eq 2 ]
}

@test "hub up: 知らないオプションは 2" {
	run "$CCS_BIN" hub up --bogus
	[ "$status" -eq 2 ]
}

@test "hub status: 立っていなければ absent（終了コード 12）" {
	run "$CCS_BIN" hub status
	[ "$status" -eq 12 ]
	[[ "$output" == *"absent"* ]] || return 1
	[[ "$output" == *"ccs hub up"* ]] || return 1
}

@test "hub status --json: 機械可読で、状態と設定が入る" {
	run "$CCS_BIN" hub status --json
	[ "$status" -eq 12 ]
	printf '%s' "$output" | jq -e . >/dev/null
	[ "$(printf '%s' "$output" | jq -r '.state')" = 'absent' ]
	[ "$(printf '%s' "$output" | jq -r '.slug')" = 'hub' ]
	[ "$(printf '%s' "$output" | jq -r '.remoteControl')" = 'auto' ]
}

@test "hub status: 止めていれば paused（終了コード 14）" {
	mkdir -p "$CCS_HUB_HOME"
	: >"${CCS_HUB_HOME}/paused"
	run "$CCS_BIN" hub status
	[ "$status" -eq 14 ]
	[[ "$output" == *"paused"* ]] || return 1
	[[ "$output" == *"ccs hub up --force"* ]] || return 1
}

@test "hub up: 止めていれば何もせず 14" {
	mkdir -p "$CCS_HUB_HOME"
	: >"${CCS_HUB_HOME}/paused"
	run "$CCS_BIN" hub up
	[ "$status" -eq 14 ]
	[[ "$output" == *"ccs hub up --force"* ]] || return 1
}

@test "hub up --quiet: 止めていても黙る（自動起動が毎回吠えないため）" {
	mkdir -p "$CCS_HUB_HOME"
	: >"${CCS_HUB_HOME}/paused"
	run "$CCS_BIN" hub up --quiet
	[ "$status" -eq 14 ]
	[ -z "$output" ]
}

# --- 自動起動の設定 --------------------------------------------------------

@test "hub agent: off なら生成せず、直し方を出す" {
	CCS_HUB_AUTOSTART=off run "$CCS_BIN" hub agent --print
	[ "$status" -eq 1 ]
	[[ "$output" == *"CCS_HUB_AUTOSTART"* ]] || return 1
	[[ "$output" == *"ccs hub up"* ]] || return 1
}

@test "hub agent: --autostart で一時的に上書きできる" {
	CCS_HUB_AUTOSTART=off run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"hub up --quiet"* ]] || return 1
}

@test "hub agent: 知らない --autostart は 2" {
	run "$CCS_BIN" hub agent --print --autostart sometimes
	[ "$status" -eq 2 ]
}

@test "hub agent --print: ラベルと間隔が設定どおりに入る" {
	CCS_HUB_AGENT_LABEL=com.example.myhub CCS_HUB_AGENT_INTERVAL=120 \
		run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"com.example.myhub"* ]] || [[ "$output" == *"com-example-myhub"* ]] || return 1
	[[ "$output" == *"120"* ]] || return 1
}

@test "hub agent --print: login モードでは間隔を入れない" {
	run "$CCS_BIN" hub agent --print --autostart login
	[ "$status" -eq 0 ]
	[[ "$output" != *"StartInterval"* ]] || return 1
	[[ "$output" != *"OnUnitActiveSec"* ]] || return 1
}

@test "hub agent --print: 出力に ccs の絶対パスが入る" {
	# 自動起動は PATH の通っていない環境から呼ばれることがある。
	run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"${CCS_BIN}"* ]] || return 1
}

# 焼き込んだ PATH を 1 行として取り出す。**plist と systemd unit で書き方が違う**
# ので（<string>… と Environment=PATH=…）、共通して入っている最低限のシステム
# パスを目印にする。ここを OS で分岐させると、テストが片方の OS でしか走らない。
ccs_generated_path_line() {
	printf '%s\n' "$1" | grep -F '/usr/bin:/bin:/usr/sbin:/sbin' | head -1
}

@test "hub agent --print: 依存の在処を PATH に焼き込む" {
	# **launchd / systemd は対話シェルの設定を読まない。** PATH を ~/.zshrc で
	# 足している環境では、-lc でログインシェルにしても tmux が見つからず、
	# ccs hub up が依存不足で即死する（実測）。生成側が解決できた場所を渡す。
	run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	_line=$(ccs_generated_path_line "$output")
	[ -n "$_line" ]
	[[ "$_line" == *"${CCS_STUB_BIN}"* ]] || return 1
}

@test "hub agent --print: launchd には EnvironmentVariables で渡す" {
	# **uname を差し替えて、走っている OS に依らず両方の分岐を通す。**
	# ここを本物の uname に任せると、片方の分岐が CI でしか（あるいは
	# 手元でしか）検証されない ── 実際に macOS で書いたテストが Linux の
	# CI で落ちた。
	ccs_stub uname 'echo Darwin'
	run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"<key>EnvironmentVariables</key>"* ]] || return 1
	[[ "$output" == *"<key>PATH</key>"* ]] || return 1
	[[ "$(ccs_generated_path_line "$output")" == *"${CCS_STUB_BIN}"* ]] || return 1
}

@test "hub agent --print: systemd には Environment=PATH= で渡す" {
	ccs_stub uname 'echo Linux'
	run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"Environment=PATH="* ]] || return 1
	[[ "$(ccs_generated_path_line "$output")" == *"${CCS_STUB_BIN}"* ]] || return 1
}

@test "hub agent --print: PATH には最低限のシステムパスも残る" {
	run "$CCS_BIN" hub agent --print --autostart on
	[[ "$output" == *"/usr/bin:/bin:/usr/sbin:/sbin"* ]] || return 1
}

@test "hub agent --print: 同じディレクトリの依存を重複させない" {
	# tmux も jq も同じスタブ置き場にいる状態を作る。
	ccs_stub jq 'exit 0'
	CCS_JQ_BIN="${CCS_STUB_BIN}/jq" run "$CCS_BIN" hub agent --print --autostart on
	_line=$(ccs_generated_path_line "$output")
	_count=$(printf '%s' "$_line" | awk -v d="$CCS_STUB_BIN" 'BEGIN{n=0} {n=gsub(d,d)} END{print n}')
	[ "$_count" -eq 1 ]
}

@test "hub agent: 知らない --unit は 2" {
	run "$CCS_BIN" hub agent --print --unit bogus
	[ "$status" -eq 2 ]
}

@test "hub agent: --print 無しなら入れ方の手順を出す" {
	run "$CCS_BIN" hub agent --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs hub agent --print"* ]] || return 1
}
