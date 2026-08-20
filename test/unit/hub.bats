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
	[[ "$output" == *"ccs hub up"* ]]
}

@test "resolve: hub も同じく止まる" {
	run "$CCS_BIN" resolve hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"予約語"* ]]
}

@test "予約語の案内には、名前を変える手段が書いてある" {
	# **他人の環境では hub というリポジトリがありうる。** 逃げ道を必ず示す。
	run "$CCS_BIN" new hub
	[[ "$output" == *"CCS_HUB_SLUG"* ]]
	[[ "$output" == *"<owner>/hub"* ]]
}

@test "hub の名前を変えると、hub は普通のリポジトリ名に戻る" {
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/someone/hub"
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/someone/hub"

	CCS_HUB_SLUG=orchestrator run "$CCS_BIN" resolve hub
	[ "$status" -eq 0 ]
	[[ "$output" == hub*"/hub" ]]
}

@test "hub の名前を変えると、新しい名前が予約語になる" {
	CCS_HUB_SLUG=orchestrator run "$CCS_BIN" new orchestrator
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs hub up"* ]]
}

@test "hub と同じ名前のリポジトリは <owner>-<repo> の slug になる" {
	# `cc/hub` は hub のものなので、他のリポジトリに使わせない。
	# 使わせると、立てた瞬間に hub の生死判定が壊れる。
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/someone/hub"
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/someone/hub"

	run "$CCS_BIN" resolve someone/hub
	[ "$status" -eq 0 ]
	[[ "$output" == someone-hub*"/hub" ]]
}

# --- 保護 -----------------------------------------------------------------

@test "kill: hub は畳めない" {
	run "$CCS_BIN" kill hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"hub"* ]]
	[[ "$output" == *"ccs hub restart"* ]]
	[[ "$output" == *"ccs hub down"* ]]
}

@test "kill: hub は --force でも畳めない" {
	# **ここは逃げ道を用意しない。** 落とすと、スマホから操作する経路が消える。
	run "$CCS_BIN" kill --force hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs hub restart"* ]]
}

@test "kill: 名前を変えた hub も守られる" {
	CCS_HUB_SLUG=orchestrator run "$CCS_BIN" kill orchestrator
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs hub restart"* ]]
}

# --- サブコマンドの入口 ----------------------------------------------------

@test "hub: サブコマンド無しは 2 で、何が打てるかを出す" {
	run "$CCS_BIN" hub
	[ "$status" -eq 2 ]
	[[ "$output" == *"ccs hub up"* ]]
	[[ "$output" == *"ccs hub status"* ]]
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
	[[ "$output" == *"absent"* ]]
	[[ "$output" == *"ccs hub up"* ]]
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
	[[ "$output" == *"paused"* ]]
	[[ "$output" == *"ccs hub up --force"* ]]
}

@test "hub up: 止めていれば何もせず 14" {
	mkdir -p "$CCS_HUB_HOME"
	: >"${CCS_HUB_HOME}/paused"
	run "$CCS_BIN" hub up
	[ "$status" -eq 14 ]
	[[ "$output" == *"ccs hub up --force"* ]]
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
	[[ "$output" == *"CCS_HUB_AUTOSTART"* ]]
	[[ "$output" == *"ccs hub up"* ]]
}

@test "hub agent: --autostart で一時的に上書きできる" {
	CCS_HUB_AUTOSTART=off run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"hub up --quiet"* ]]
}

@test "hub agent: 知らない --autostart は 2" {
	run "$CCS_BIN" hub agent --print --autostart sometimes
	[ "$status" -eq 2 ]
}

@test "hub agent --print: ラベルと間隔が設定どおりに入る" {
	CCS_HUB_AGENT_LABEL=com.example.myhub CCS_HUB_AGENT_INTERVAL=120 \
		run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"com.example.myhub"* ]] || [[ "$output" == *"com-example-myhub"* ]]
	[[ "$output" == *"120"* ]]
}

@test "hub agent --print: login モードでは間隔を入れない" {
	run "$CCS_BIN" hub agent --print --autostart login
	[ "$status" -eq 0 ]
	[[ "$output" != *"StartInterval"* ]]
	[[ "$output" != *"OnUnitActiveSec"* ]]
}

@test "hub agent --print: 出力に ccs の絶対パスが入る" {
	# 自動起動は PATH の通っていない環境から呼ばれることがある。
	run "$CCS_BIN" hub agent --print --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"${CCS_BIN}"* ]]
}

@test "hub agent: 知らない --unit は 2" {
	run "$CCS_BIN" hub agent --print --unit bogus
	[ "$status" -eq 2 ]
}

@test "hub agent: --print 無しなら入れ方の手順を出す" {
	run "$CCS_BIN" hub agent --autostart on
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs hub agent --print"* ]]
}
