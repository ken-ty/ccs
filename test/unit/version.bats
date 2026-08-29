#!/usr/bin/env bats
#
# 版の名乗り方 — 焼き込み / git からの導出 / どちらも無いとき。
#
# **これは回帰テストである以前に、事故の再発防止そのもの。** 手書きの番号は
# 0.1.0 → 0.2.0 → 0.0.1 → 0.0.3 と後退したまま 3 つの機能 PR をまたいで
# 止まり、`restore --last` を持つ版と持たない版に同じ答えを返していた。
# ここで固定するのは「版がコミットから導出されること」＝**前と後が必ず
# 区別できること**。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
}

teardown() {
	ccs_teardown_sandbox
}

# bin/ccs の複製を持つ使い捨ての git リポジトリを作る。
#
# **本物のリポジトリでは tag を試せない**（tag を打つ／消すのは副作用）。
# 版の導出は git の状態そのものを読むので、状態を自分で作れる場所が要る。
ccs_make_version_repo() {
	_vr_dir="${CCS_TEST_TMP}/vrepo"
	mkdir -p "${_vr_dir}/bin"
	cp "$CCS_BIN" "${_vr_dir}/bin/ccs"
	git -C "$_vr_dir" init -q
	git -C "$_vr_dir" config user.email 'test@example.com'
	git -C "$_vr_dir" config user.name 'test'
	git -C "$_vr_dir" add -A
	git -C "$_vr_dir" commit -q -m 'init'
	printf '%s' "$_vr_dir"
}

# --- 機械可読な形 ----------------------------------------------------------

@test "version --short: X.Y.Z だけを出す（以前の出力そのままの契約）" {
	run "$CCS_BIN" version --short
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
}

@test "version --short: -s も同じ" {
	run "$CCS_BIN" version -s
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
}

@test "version: 知らないオプションは使い方の誤り（2）" {
	run "$CCS_BIN" version --nope
	[ "$status" -eq 2 ]
}

# --- git から導出する ------------------------------------------------------

@test "version: tag が無ければ 錨+sha を名乗り、sha は HEAD と一致する" {
	repo=$(ccs_make_version_repo)
	sha=$(git -C "$repo" rev-parse --short HEAD)

	run "${repo}/bin/ccs" version
	[ "$status" -eq 0 ]
	[[ "$output" == *"+${sha}"* ]] || return 1
}

@test "version: コミットが動けば版も動く（前と後が区別できる）" {
	repo=$(ccs_make_version_repo)
	run "${repo}/bin/ccs" version --short
	before_full=$("${repo}/bin/ccs" version)

	printf '\n# もう 1 コミット\n' >>"${repo}/README"
	git -C "$repo" add -A
	git -C "$repo" commit -q -m 'second'

	after_full=$("${repo}/bin/ccs" version)
	[ "$before_full" != "$after_full" ] || return 1
}

@test "version: tag があれば tag 由来の版になる（先頭の v は落ちる）" {
	repo=$(ccs_make_version_repo)
	git -C "$repo" tag v1.2.3

	run "${repo}/bin/ccs" version
	[ "$status" -eq 0 ]
	[[ "$output" == "1.2.3 (dev)" ]] || return 1

	run "${repo}/bin/ccs" version --short
	[ "$output" = '1.2.3' ]
}

@test "version: 追跡されている変更があれば dirty が付く" {
	repo=$(ccs_make_version_repo)
	git -C "$repo" tag v1.2.3
	printf '\n# 手が入っている\n' >>"${repo}/bin/ccs"

	run "${repo}/bin/ccs" version
	[ "$status" -eq 0 ]
	[[ "$output" == *"dirty"* ]] || return 1
}

@test "version: 焼き込まれていなければ (dev) と名乗る" {
	repo=$(ccs_make_version_repo)
	run "${repo}/bin/ccs" version
	[[ "$output" == *"(dev)"* ]] || return 1
}

# --- 焼き込み --------------------------------------------------------------

@test "version: 焼き込みがあればそれを名乗り、(dev) は付かない" {
	# install が焼き込んだ実体を模す（repo の外にある単一ファイル）。
	installed="${CCS_TEST_TMP}/installed-ccs"
	sed "s/^CCS_BUILD=''\$/CCS_BUILD='9.9.9+deadbee'/" "$CCS_BIN" >"$installed"
	chmod +x "$installed"

	run "$installed" version
	[ "$status" -eq 0 ]
	[ "$output" = '9.9.9+deadbee' ]

	run "$installed" version --short
	[ "$output" = '9.9.9' ]
}

@test "version: 焼き込みは git より優先する（repo の中に居ても）" {
	repo=$(ccs_make_version_repo)
	git -C "$repo" tag v1.2.3
	sed -i.bak "s/^CCS_BUILD=''\$/CCS_BUILD='9.9.9+deadbee'/" "${repo}/bin/ccs"
	rm -f "${repo}/bin/ccs.bak"

	run "${repo}/bin/ccs" version
	[ "$output" = '9.9.9+deadbee' ]
}

# --- どちらも無いとき ------------------------------------------------------

@test "version: git の外に置かれ焼き込みも無ければ unknown（黙って嘘を言わない）" {
	orphan="${CCS_TEST_TMP}/orphan/ccs"
	mkdir -p "$(dirname "$orphan")"
	cp "$CCS_BIN" "$orphan"

	run "$orphan" version
	[ "$status" -eq 0 ]
	[[ "$output" == *"unknown"* ]] || return 1
}

@test "version: symlink 経由でも実体の git から導出する" {
	# 事故当時の形（PATH の ccs が repo の作業ツリーを指す symlink）。
	repo=$(ccs_make_version_repo)
	sha=$(git -C "$repo" rev-parse --short HEAD)
	link="${CCS_TEST_TMP}/link-ccs"
	ln -s "${repo}/bin/ccs" "$link"

	run "$link" version
	[ "$status" -eq 0 ]
	[[ "$output" == *"+${sha}"* ]] || return 1
}

# --- コミットされたファイルは焼き込み済みであってはならない ----------------

@test "bin/ccs: コミットされた本体の CCS_BUILD は空（焼き込みを混入させない）" {
	# 焼き込み済みのファイルをコミットすると、そこから先ずっと嘘の版を
	# 名乗り続ける。make lint も同じものを見張るが、ここでも固定しておく。
	run grep -c "^CCS_BUILD=''$" "$CCS_BIN"
	[ "$output" = '1' ]
}

@test "version: PATH 経由で別のリポジトリの中から打っても、自分の版を答える" {
	# **いま実際に使われている形**（PATH の ccs が repo の bin/ccs を指す
	# symlink）で、まったく別のリポジトリの中から打つ。導出が cwd を見て
	# しまうと、そのリポジトリの sha を自分の版として答えることになる。
	repo=$(ccs_make_version_repo)
	sha=$(git -C "$repo" rev-parse --short HEAD)

	binpath="${CCS_TEST_TMP}/pathbin"
	mkdir -p "$binpath"
	ln -s "${repo}/bin/ccs" "${binpath}/ccs"

	other="${CCS_TEST_TMP}/other-repo"
	mkdir -p "$other"
	git -C "$other" init -q
	git -C "$other" config user.email 'test@example.com'
	git -C "$other" config user.name 'test'
	printf 'x\n' >"${other}/f"
	git -C "$other" add -A
	git -C "$other" commit -q -m 'other'
	other_sha=$(git -C "$other" rev-parse --short HEAD)

	run env PATH="${binpath}:${PATH}" sh -c "cd '${other}' && ccs version"
	[ "$status" -eq 0 ]
	[[ "$output" == *"+${sha}"* ]] || return 1
	[[ "$output" != *"${other_sha}"* ]] || return 1
}
