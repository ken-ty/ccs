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
	# `tmp` は「新しい枠を発行する」指示。戻す先は id まで要る。
	run "$CCS_BIN" restore tmp
	[ "$status" -eq 2 ]
	[[ "$stderr$output" == *"tmp-<id>"* ]] || return 1
}

@test "restore: id の無い tmp- は断る" {
	# **id の形そのものは見ない**（I2b）。番号だった頃は数字かどうかで
	# 弾けたが、発行が一意な id になったので「空でないこと」しか言えない。
	# 実在するかは、このあとの検査が見る。
	run "$CCS_BIN" restore tmp-
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
	[[ "$stderr$output" == *"会話"* ]] || return 1
}

@test "restore: hub は予約語として断る" {
	# 立て直しは ccs hub up / ccs hub restart --resume の担当。
	run "$CCS_BIN" restore hub
	[ "$status" -eq 1 ]
	[[ "$stderr$output" == *"ccs hub"* ]] || return 1
}

@test "help: restore を案内している" {
	run "$CCS_BIN" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs restore"* ]] || return 1
}

# --- 設定 ------------------------------------------------------------------

@test "config: CCS_RESTORE_MAX_AGE が一覧に出る" {
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$output" == *"CCS_RESTORE_MAX_AGE"* ]] || return 1
	[[ "$output" == *"7"* ]] || return 1
}

@test "config: CCS_RESTORE_MAX_AGE が整数でなければ落とす" {
	# 黙って既定値に戻すと、設定したのに効いていないことに気づけない。
	CCS_RESTORE_MAX_AGE=しばらく run "$CCS_BIN" restore
	[ "$status" -eq 2 ]
}

# --- --last / --since の受け付け方 -----------------------------------------
#
# **どちらも「候補を絞る」指定。** 何を戻すかを決めるのは候補の列挙のほうで、
# ここが受け付けるのは絞り方だけ。切り出しそのものは
# test/integration/restore.bats。

@test "restore: --last と slug の名指しは一緒に使えない" {
	# 名指しは「これを戻す」という答えそのもので、絞り込みが要らない。
	run "$CCS_BIN" restore --last tmp-1
	[ "$status" -eq 2 ]
	[[ "$stderr$output" == *"--last"* ]] || return 1
}

@test "restore: --since と slug の名指しは一緒に使えない" {
	run "$CCS_BIN" restore --since 6h tmp-1
	[ "$status" -eq 2 ]
}

@test "restore: --last と --since は一緒に使えない" {
	# 基準が起動時刻なのか現在時刻なのかが決まらない。
	run "$CCS_BIN" restore --last --since 6h
	[ "$status" -eq 2 ]
}

@test "restore: --since に値が無ければ断る" {
	run "$CCS_BIN" restore --since
	[ "$status" -eq 2 ]
}

@test "restore: --since の綴りは <数><s|m|h|d>" {
	# **綴りを間違えたまま素通りさせない。** 黙って全部を候補にすると、
	# 絞ったつもりの人が残骸まで立ち上げることになる。
	local bad
	for bad in 6x abc '' 0h -1h 6hh h; do
		run "$CCS_BIN" restore --since "$bad"
		[ "$status" -eq 2 ] || return 1
	done

	local good
	for good in 30s 45m 6h 2d; do
		run "$CCS_BIN" restore --since "$good"
		[ "$status" -eq 0 ] || return 1
	done
}

@test "config: CCS_RESTORE_LAST_WINDOW が一覧に出る" {
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$output" == *"CCS_RESTORE_LAST_WINDOW"* ]] || return 1
	[[ "$output" == *"300"* ]] || return 1
}

@test "config: CCS_RESTORE_LAST_WINDOW が整数でなければ落とす" {
	CCS_RESTORE_LAST_WINDOW=しばらく run "$CCS_BIN" restore
	[ "$status" -eq 2 ]
}

@test "config: CCS_RESTORE_BOOT_EPOCH は空でよいが、整数でなければ落とす" {
	# 既定は空（OS に訊く）。**空を許すぶん、綴り間違いは自分で見る。**
	CCS_RESTORE_BOOT_EPOCH= run "$CCS_BIN" restore
	[ "$status" -eq 0 ]

	CCS_RESTORE_BOOT_EPOCH=きのう run "$CCS_BIN" restore
	[ "$status" -eq 2 ]
}
