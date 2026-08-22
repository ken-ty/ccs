#!/usr/bin/env bats
#
# ccs restore の引数と入口。
#
# 外部プロセスを起動しない範囲（受け付ける綴り・断り方・設定の検査）だけを見る。
# 実際に立て直すところは test/integration/restore.bats。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_stub_deps
	ccs_stub_ghq ''
}

teardown() {
	ccs_teardown_sandbox
}

@test "restore: 知らないオプションは使い方の誤り (2)" {
	run "$CCS_BIN" restore --bogus
	[ "$status" -eq 2 ]
}

@test "restore: tmp は枠を取る綴りなので受け付けない" {
	# `tmp` は「空いている枠を取る」指示。戻す先は番号まで要る。
	run "$CCS_BIN" restore tmp
	[ "$status" -eq 2 ]
	[[ "$stderr$output" == *"tmp-1"* ]]
}

@test "restore: tmp-<番号> でない枠の綴りは断る" {
	run "$CCS_BIN" restore tmp-abc
	[ "$status" -eq 2 ]
}

@test "restore: --session-id に値が無ければ断る" {
	run "$CCS_BIN" restore tmp-1 --session-id
	[ "$status" -eq 2 ]
}

@test "restore: --session-id は戻す先が 1 つのときだけ" {
	# どの会話をどこに戻すのかが決まらない。
	run "$CCS_BIN" restore --session-id 00000000-0000-4000-8000-000000000000
	[ "$status" -eq 2 ]

	run "$CCS_BIN" restore tmp-1 tmp-2 --session-id 00000000-0000-4000-8000-000000000000
	[ "$status" -eq 2 ]
}

@test "restore: 戻す先の会話が無ければ 1 で終わる" {
	run "$CCS_BIN" restore tmp-1
	[ "$status" -eq 1 ]
	[[ "$stderr$output" == *"会話"* ]]
}

@test "restore: hub は予約語として断る" {
	# 立て直しは ccs hub up / ccs hub restart --resume の担当。
	run "$CCS_BIN" restore hub
	[ "$status" -eq 1 ]
	[[ "$stderr$output" == *"ccs hub"* ]]
}

@test "help: restore を案内している" {
	run "$CCS_BIN" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs restore"* ]]
}

# --- 設定 ------------------------------------------------------------------

@test "config: CCS_RESTORE_MAX_AGE が一覧に出る" {
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$output" == *"CCS_RESTORE_MAX_AGE"* ]]
	[[ "$output" == *"7"* ]]
}

@test "config: CCS_RESTORE_MAX_AGE が整数でなければ落とす" {
	# 黙って既定値に戻すと、設定したのに効いていないことに気づけない。
	CCS_RESTORE_MAX_AGE=しばらく run "$CCS_BIN" restore
	[ "$status" -eq 2 ]
}
