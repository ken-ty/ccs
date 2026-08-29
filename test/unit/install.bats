#!/usr/bin/env bats
#
# インストーラ — 版ごとのディレクトリへ入れ、symlink を原子的に差し替える。
#
# **ここで守るのは「PATH の ccs が git の作業ツリーを指さない」こと。**
# 指していると、走るコードは main checkout の HEAD がその瞬間に何であるか
# そのものになる（2026-08-29 の事故）。とくに `--auto` が**作業ツリーに
# 触らない**ことは、他のセッションが同じチェックアウトを使っている前提の
# 上で成立を支えている一点なので、専用の test で固定する。
#
# tmux も claude も起動しない（git だけ）ので unit に置く。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	export CCS_INSTALL_ROOT="${CCS_TEST_TMP}/share"
	export CCS_BIN_DIR="${CCS_TEST_TMP}/bin"
	# 検知のたびに fetch させる（間引きは別の test で見る）。
	export CCS_UPDATE_INTERVAL=0
	CCS_INSTALLER="${CCS_REPO_ROOT}/scripts/install.sh"
	export CCS_INSTALLER
}

teardown() {
	ccs_teardown_sandbox
}

# 上流（bare）と、そこから引いたチェックアウトを作る。
ccs_make_upstream() {
	up="${CCS_TEST_TMP}/upstream.git"
	repo="${CCS_TEST_TMP}/repo"
	git init -q --bare "$up"
	git clone -q "$up" "$repo" 2>/dev/null
	mkdir -p "${repo}/bin"
	cp "$CCS_BIN" "${repo}/bin/ccs"
	git -C "$repo" config user.email 'test@example.com'
	git -C "$repo" config user.name 'test'
	git -C "$repo" add -A
	git -C "$repo" commit -q -m 'one'
	git -C "$repo" branch -M main
	git -C "$repo" push -q -u origin main
}

# 別のクローンから上流を進める（＝どこかでマージされた状況）。
ccs_advance_upstream() {
	other="${CCS_TEST_TMP}/other"
	rm -rf "$other"
	git clone -q "$up" "$other" 2>/dev/null
	git -C "$other" config user.email 'test@example.com'
	git -C "$other" config user.name 'test'
	printf '\n# %s\n' "${1:-新機能}" >>"${other}/bin/ccs"
	git -C "$other" commit -qam "feat: ${1:-新機能}"
	git -C "$other" push -q origin main
}

# --- 入れる ----------------------------------------------------------------

@test "install: 版ごとのディレクトリに置き、symlink で指す" {
	ccs_make_upstream
	run "$CCS_INSTALLER" "$repo"
	[ "$status" -eq 0 ]

	[ -L "${CCS_BIN_DIR}/ccs" ] || return 1
	target=$(readlink "${CCS_BIN_DIR}/ccs")
	[[ "$target" == "${CCS_INSTALL_ROOT}/versions/"* ]] || return 1
	[ -x "$target" ]
}

@test "install: PATH の ccs が git の作業ツリーを指さない（事故の形にしない）" {
	ccs_make_upstream
	run "$CCS_INSTALLER" "$repo"
	[ "$status" -eq 0 ]

	target=$(readlink "${CCS_BIN_DIR}/ccs")
	[[ "$target" != "${repo}"* ]] || return 1
}

@test "install: 版を焼き込むので (dev) と名乗らない" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null

	run "${CCS_BIN_DIR}/ccs" version
	[ "$status" -eq 0 ]
	[[ "$output" != *"(dev)"* ]] || return 1
	sha=$(git -C "$repo" rev-parse --short HEAD)
	[[ "$output" == *"+${sha}"* ]] || return 1
}

@test "install: 素性（commit / install 元）を控える" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null

	id=$(cat "${CCS_INSTALL_ROOT}/current")
	sha=$(git -C "$repo" rev-parse HEAD)
	run grep -c "^commit=${sha}$" "${CCS_INSTALL_ROOT}/meta/${id}"
	[ "$output" = '1' ]
	[ "$(cat "${CCS_INSTALL_ROOT}/source")" = "$repo" ]
}

@test "install: インストーラの複製を置く（チェックアウトが壊れても巻き戻せる）" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	[ -x "${CCS_INSTALL_ROOT}/bin/ccs-install" ]
}

@test "install: 2 度入れても壊れない（冪等）" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	run "$CCS_INSTALLER" "$repo"
	[ "$status" -eq 0 ]
	run "${CCS_BIN_DIR}/ccs" version --short
	[ "$status" -eq 0 ]
}

# --- 検知 ------------------------------------------------------------------

@test "check: 最新なら 0" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	run "$CCS_INSTALLER" --check --force
	[ "$status" -eq 0 ]
	[[ "$output" == *"state=current"* ]] || return 1
}

@test "check: 上流が進んでいれば 10（古い）" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	ccs_advance_upstream

	run "$CCS_INSTALLER" --check --force
	[ "$status" -eq 10 ]
	[[ "$output" == *"state=stale"* ]] || return 1
	newsha=$(git -C "$other" rev-parse --short main)
	[[ "$output" == *"${newsha}"* ]] || return 1
}

@test "check: fetch できなければ 11 で「確認できていない」と言う（黙って盲目にならない）" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	git -C "$repo" remote set-url origin "${CCS_TEST_TMP}/does-not-exist.git"

	run "$CCS_INSTALLER" --check --force
	[ "$status" -eq 11 ]
	[[ "$output" == *"state=unsure"* ]] || return 1
	[[ "$output" == *"確認できていません"* ]] || return 1
	# **「最新です」と言わない**ことがこの test の本体。
	[[ "$output" != *"state=current"* ]] || return 1
}

# --- 自動切替 --------------------------------------------------------------

@test "auto: 上流が進んでいれば切り替える" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	before=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream

	run "$CCS_INSTALLER" --auto
	[ "$status" -eq 0 ]
	after=$(cat "${CCS_INSTALL_ROOT}/current")
	[ "$before" != "$after" ] || return 1
	newsha=$(git -C "$other" rev-parse --short main)
	[[ "$after" == *"${newsha}"* ]] || return 1
}

@test "auto: **チェックアウトの作業ツリーに触らない**（別ブランチ・未コミットでも）" {
	# ここが「ghq は実装用、動作は別 path」の要。同じチェックアウトを
	# 他のセッションが使っている前提なので、pull も branch 切り替えもしない。
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null

	git -C "$repo" switch -qc feature-branch
	printf '\n# 作業中の未コミット\n' >>"${repo}/bin/ccs"
	before_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
	before_head=$(git -C "$repo" rev-parse HEAD)
	before_sum=$(cksum <"${repo}/bin/ccs")

	ccs_advance_upstream
	run "$CCS_INSTALLER" --auto
	[ "$status" -eq 0 ]

	[ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = "$before_branch" ]
	[ "$(git -C "$repo" rev-parse HEAD)" = "$before_head" ]
	[ "$(cksum <"${repo}/bin/ccs")" = "$before_sum" ]
}

@test "auto: 入るのは origin/main であって、手元の未コミットではない" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	printf '\n# 手元だけの細工\n# CCS_MARKER_LOCAL_ONLY\n' >>"${repo}/bin/ccs"
	ccs_advance_upstream

	"$CCS_INSTALLER" --auto >/dev/null
	id=$(cat "${CCS_INSTALL_ROOT}/current")
	run grep -c 'CCS_MARKER_LOCAL_ONLY' "${CCS_INSTALL_ROOT}/versions/${id}"
	[ "$output" = '0' ]
}

@test "auto: fetch できなければ切り替えず、11 を返す" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	before=$(cat "${CCS_INSTALL_ROOT}/current")
	git -C "$repo" remote set-url origin "${CCS_TEST_TMP}/does-not-exist.git"

	run "$CCS_INSTALLER" --auto
	[ "$status" -eq 11 ]
	[ "$(cat "${CCS_INSTALL_ROOT}/current")" = "$before" ]
}

@test "auto: 版が起動できなければ切り替えない（壊れたものを掴ませない）" {
	# 自動切替は人が見ていないので、起動もできないものに差し替えると
	# hub ごと止まる。**入れる前に version を訊く。**
	#
	# **壊し方が肝心。** CCS_BUILD の行ごと壊すと、smoke test ではなく
	# 焼き込み検査のほうで弾かれてしまい、この test は smoke test を
	# 検証しないまま緑になる（実際に一度そうなった）。焼き込みは通るが
	# 起動はできない、という形にする。
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	before=$(cat "${CCS_INSTALL_ROOT}/current")

	other="${CCS_TEST_TMP}/other"
	rm -rf "$other"
	git clone -q "$up" "$other" 2>/dev/null
	git -C "$other" config user.email 'test@example.com'
	git -C "$other" config user.name 'test'
	# CCS_BUILD='' の直後で死ぬようにする（焼き込みの行は残る）。
	sed "s/^CCS_BUILD=''\$/CCS_BUILD=''\nexit 7/" "$CCS_BIN" >"${other}/bin/ccs"
	grep -q "^CCS_BUILD=''$" "${other}/bin/ccs" || return 1
	git -C "$other" commit -qam 'broken'
	git -C "$other" push -q origin main

	run "$CCS_INSTALLER" --auto
	[ "$status" -ne 0 ]
	[ "$(cat "${CCS_INSTALL_ROOT}/current")" = "$before" ]
	[[ "$(readlink "${CCS_BIN_DIR}/ccs")" == *"${before}" ]] || return 1
}

@test "auto: 焼き込めない版は入れない（CCS_BUILD の行が無い）" {
	# 焼き込みに失敗したまま入れると、その実体は版を名乗れない。
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	before=$(cat "${CCS_INSTALL_ROOT}/current")

	other="${CCS_TEST_TMP}/other"
	rm -rf "$other"
	git clone -q "$up" "$other" 2>/dev/null
	git -C "$other" config user.email 'test@example.com'
	git -C "$other" config user.name 'test'
	# **version には答えられるが、焼き込む行が無い**という形にする。
	# 単に壊れたものを置くと smoke test のほうで弾かれ、この test は
	# 焼き込み検査を検証しないまま緑になる。
	printf '#!/bin/sh\n[ "$1" = version ] && { echo 1.2.3; exit 0; }\nexit 0\n' \
		>"${other}/bin/ccs"
	git -C "$other" commit -qam 'no stamp line'
	git -C "$other" push -q origin main

	run "$CCS_INSTALLER" --auto
	[ "$status" -ne 0 ]
	[ "$(cat "${CCS_INSTALL_ROOT}/current")" = "$before" ]
}

# --- install 元が消えたとき ----------------------------------------------

@test "check: install 元が消えたら「分からない」と言う（別のリポジトリにすり替えない）" {
	# **実測で踏んだバグ。** 控えが辿れないときに「自分が居るリポジトリ」へ
	# 落ちると、**基準点が黙って別のリポジトリにすり替わる** ── install 元を
	# 消したあと ccs の作業ツリーから --check を打つと、そちらの origin/main を
	# 「新しい版」として報告した。検知の根拠が入れ替わるのは、古さを見逃すより悪い。
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	gone="$repo"
	rm -rf "$repo"

	run "$CCS_INSTALLER" --check --force
	[ "$status" -eq 11 ]
	[[ "$output" == *"state=unsure"* ]] || return 1
	# 消えた場所を名指しする（何を直せばよいか分かるように）。
	[[ "$output" == *"${gone}"* ]] || return 1
	# **別のリポジトリを基準にしていない。**
	[[ "$output" != *"state=stale"* ]] || return 1
	[[ "$output" != *"$CCS_REPO_ROOT"* ]] || return 1
}

@test "auto: install 元が消えたら切り替えない" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	before=$(cat "${CCS_INSTALL_ROOT}/current")
	rm -rf "$repo"

	run "$CCS_INSTALLER" --auto
	[ "$status" -eq 11 ]
	[ "$(cat "${CCS_INSTALL_ROOT}/current")" = "$before" ]
}

@test "switch: install 元が消えても巻き戻せる（複製を置いている狙い）" {
	# インストーラの複製と過去の版は $CCS_INSTALL_ROOT に残る。
	# **巻き戻しがチェックアウトに依存したら「別 path で管理する」が徹底できない。**
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	first=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream
	"$CCS_INSTALLER" --auto >/dev/null
	rm -rf "$repo"

	run "${CCS_INSTALL_ROOT}/bin/ccs-install" --switch "$first"
	[ "$status" -eq 0 ]
	[ "$(cat "${CCS_INSTALL_ROOT}/current")" = "$first" ]
	run "${CCS_BIN_DIR}/ccs" version
	[ "$output" = "$first" ]
}

# --- 巻き戻し --------------------------------------------------------------

@test "switch: 1 手で前の版へ戻せる" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	first=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream
	"$CCS_INSTALLER" --auto >/dev/null

	run "$CCS_INSTALLER" --switch "$first"
	[ "$status" -eq 0 ]
	[ "$(cat "${CCS_INSTALL_ROOT}/current")" = "$first" ]
	run "${CCS_BIN_DIR}/ccs" version
	[[ "$output" == "$first" ]] || return 1
}

@test "switch: 前の版は残っている（戻り先が消えていては巻き戻せない）" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	first=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream
	"$CCS_INSTALLER" --auto >/dev/null

	[ -x "${CCS_INSTALL_ROOT}/versions/${first}" ]
}

@test "switch: 知らない版は断る" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	run "$CCS_INSTALLER" --switch 'そんな版は無い'
	[ "$status" -ne 0 ]
}

@test "switch: 切り替えても、巻き戻し方を出す" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	first=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream

	run "$CCS_INSTALLER" --auto
	[[ "$output" == *"--switch ${first}"* ]] || return 1
}

# --- 記録 ------------------------------------------------------------------

@test "log: いつ・どの版から どの版へ・きっかけ が残る" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	first=$(cat "${CCS_INSTALL_ROOT}/current")
	ccs_advance_upstream
	"$CCS_INSTALLER" --auto >/dev/null
	second=$(cat "${CCS_INSTALL_ROOT}/current")

	line=$(grep '"trigger":"auto"' "${CCS_INSTALL_ROOT}/install.log")
	[[ "$line" == *"\"from\":\"${first}\""* ]] || return 1
	[[ "$line" == *"\"to\":\"${second}\""* ]] || return 1
	[[ "$line" == *'"ts":"20'* ]] || return 1
}

@test "log: 手で入れたものは trigger=manual で残る" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	run grep -c '"trigger":"manual"' "${CCS_INSTALL_ROOT}/install.log"
	[ "$output" = '1' ]
}

# --- 掃除 ------------------------------------------------------------------

@test "prune: 版は無限に溜まらないが、いま指しているものは消えない" {
	ccs_make_upstream
	export CCS_KEEP_VERSIONS=2
	"$CCS_INSTALLER" "$repo" >/dev/null
	for i in 1 2 3; do
		ccs_advance_upstream "変更${i}"
		"$CCS_INSTALLER" --auto >/dev/null
	done

	cur=$(cat "${CCS_INSTALL_ROOT}/current")
	[ -x "${CCS_INSTALL_ROOT}/versions/${cur}" ]
	n=$(find "${CCS_INSTALL_ROOT}/versions" -type f | grep -c .)
	[ "$n" -le 3 ]
}

# --- 見せる ----------------------------------------------------------------

@test "list: 入っている版を並べ、いま指しているものに印を付ける" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	cur=$(cat "${CCS_INSTALL_ROOT}/current")

	run "$CCS_INSTALLER" --list
	[ "$status" -eq 0 ]
	[[ "$output" == *"* ${cur}"* ]] || return 1
}

@test "where: PATH の ccs が何を指しているかを出す" {
	ccs_make_upstream
	"$CCS_INSTALLER" "$repo" >/dev/null
	run "$CCS_INSTALLER" --where
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(cat "${CCS_INSTALL_ROOT}/current")"* ]] || return 1
}

@test "使い方の誤りは 2" {
	run "$CCS_INSTALLER" --nope
	[ "$status" -eq 2 ]
}
