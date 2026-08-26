#!/usr/bin/env bats
#
# ccs gc
#
# 消す操作なので、**既定が dry-run であること**を最優先で確かめる。
# あわせて「中身のある作業枠を絶対に消さない」ことも押さえる ──
# そこにあるのは利用者のファイルで、消えたら戻らない。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

_new() {
	mkdir -p "${CCS_TEST_TMP}/work/$1"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/$1"
	[ "$status" -eq 0 ]
	echo "$output"
}

# --- 何も無いとき ----------------------------------------------------------

@test "gc: 何も無ければその旨を出す" {
	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "gc: 生きているセッションだけなら何もしない" {
	_new alive >/dev/null

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/alive'
}

# --- 既定は dry-run --------------------------------------------------------

@test "gc: 既定では畳まない" {
	# ハブのエージェントが打つことを想定すると、確認なしで消える設計は
	# 割に合わない（ghq rm --dry-run と同じ作法）。
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs gc --yes"* ]] || return 1

	ccs_tmux has-session -t '=cc/dead'
}

@test "gc: 既定でも対象を具体的に見せる" {
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc
	[[ "$output" == *"dead"* ]] || return 1
}

@test "gc: 既定では空の枠も消さない" {
	mkdir -p "${CCS_SCRATCH_ROOT}/1"

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[ -d "${CCS_SCRATCH_ROOT}/1" ]
}

# --- --yes で実行 ----------------------------------------------------------

@test "gc --yes: 止まったセッションを畳む" {
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/dead'
	[ "$status" -ne 0 ]
}

@test "gc -y: 短い形も効く" {
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc -y
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/dead'
	[ "$status" -ne 0 ]
}

@test "gc --yes: 生きているセッションは残す" {
	_new alive >/dev/null
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]

	ccs_tmux has-session -t '=cc/alive'
	run ccs_tmux has-session -t '=cc/dead'
	[ "$status" -ne 0 ]
}

@test "gc --yes: 空の枠を消す" {
	mkdir -p "${CCS_SCRATCH_ROOT}/1" "${CCS_SCRATCH_ROOT}/2"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ ! -d "${CCS_SCRATCH_ROOT}/1" ]
	[ ! -d "${CCS_SCRATCH_ROOT}/2" ]
}

@test "gc --yes: 使用中の枠は触らない" {
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	_path=$(echo "$output" | jq -r '.path')

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "$_path" ]
	ccs_tmux has-session -t '=cc/tmp-1'
}

# --- 中身のある枠は消さない ------------------------------------------------

@test "gc --yes: 中身のある枠は絶対に消さない" {
	# ここにあるのは利用者のファイル。枠を塞いでいるのは事実だが、
	# 消えたら戻らない。
	mkdir -p "${CCS_SCRATCH_ROOT}/1"
	printf 'たいせつな作業\n' >"${CCS_SCRATCH_ROOT}/1/notes.md"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -f "${CCS_SCRATCH_ROOT}/1/notes.md" ]
	[ "$(cat "${CCS_SCRATCH_ROOT}/1/notes.md")" = 'たいせつな作業' ]
}

@test "gc: 中身のある枠は報告する" {
	# 消さないが、枠を塞いでいることは伝える。
	mkdir -p "${CCS_SCRATCH_ROOT}/1"
	touch "${CCS_SCRATCH_ROOT}/1/leftover"

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"中身が残っている"* ]] || return 1
	[[ "$output" == *"消しません"* ]] || return 1
}

@test "gc: 隠しファイルだけでも中身ありとみなす" {
	mkdir -p "${CCS_SCRATCH_ROOT}/1/.git"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_SCRATCH_ROOT}/1/.git" ]
}

# --- 復帰の手掛かり --------------------------------------------------------

@test "gc: 畳む前に uuid を見せる" {
	# **畳むと pane_start_command ごと消えるので、ここが最後の機会。**
	_out=$(_new dead)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc
	[[ "$output" == *"claude --resume ${_id}"* ]] || return 1
}

@test "gc --yes: 実行時にも uuid を見せる" {
	_out=$(_new dead)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	[[ "$output" == *"${_id}"* ]] || return 1
}

# --- 管轄の境界 ------------------------------------------------------------

@test "gc: cc/ が付かない tmux セッションは触らない" {
	ccs_tmux new-session -d -s 'my-own-work' -c "$CCS_TEST_TMP" 'sleep 60'

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=my-own-work'
}

@test "gc: 枠の外のディレクトリは触らない" {
	mkdir -p "${CCS_TEST_TMP}/not-a-slot"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_TEST_TMP}/not-a-slot" ]
}

@test "gc: 知らないオプションは 2" {
	run "$CCS_BIN" gc --nope
	[ "$status" -eq 2 ]
}

# --- 後始末のあと ----------------------------------------------------------

@test "gc --yes のあと ls が綺麗になる" {
	_new alive >/dev/null
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'alive' ]
}

@test "gc --yes のあと作業枠が使えるようになる" {
	export CCS_SCRATCH_SLOTS=1
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]

	# 枠が 1 本しかないので、次は取れない
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 1 ]

	ccs_kill_claude_of tmp-1
	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
}

# --- worktree（W3、ADR-0003 決定 7）----------------------------------------
#
# **git は本物を使う。** 安全性の本体は `git worktree remove` と `git branch -d`
# が素で拒むことなので、スタブに置き換えると「スタブが正しいこと」しか
# 確かめられない。ここで守りたいのは **未 push かつ未マージのコミットが
# 自動では消えない**ことで、それは git の挙動そのもの。

_wt_repo() {
	CCS_TEST_REPO="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$CCS_TEST_REPO"
	ccs_stub_ghq "$CCS_TEST_REPO"

	# 疑似リモート。**上流の有無が分類を分ける**ので、本物の remote が要る。
	git init -q --bare "${CCS_TEST_TMP}/remote.git"
	git -C "$CCS_TEST_REPO" remote add origin "${CCS_TEST_TMP}/remote.git"
	git -C "$CCS_TEST_REPO" push -q -u origin main
}

# <repo>/.worktrees/<branch> に worktree を切る。git を直接叩く
# （ccs new を通すと claude の起動まで巻き込む）。
_wt_add() {
	git -C "$CCS_TEST_REPO" worktree add -q ".worktrees/$1" -b "$1"
}

_wt_commit() {
	printf '%s\n' "$1" >"${CCS_TEST_REPO}/.worktrees/${1}/${1}.txt"
	git -C "${CCS_TEST_REPO}/.worktrees/$1" add -A
	git -C "${CCS_TEST_REPO}/.worktrees/$1" commit -q -m "$1"
}

# --- A. 消す候補 -------------------------------------------------------------

@test "gc: merge 済み・push 済みの worktree を消す候補に出す" {
	_wt_repo
	_wt_add done-1
	_wt_commit done-1
	git -C "${CCS_TEST_REPO}/.worktrees/done-1" push -q -u origin done-1
	git -C "$CCS_TEST_REPO" merge -q --no-ff -m merge done-1

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"不要になった worktree"* ]] || return 1
	[[ "$output" == *"done-1"* ]] || return 1
	# 既定は dry-run。まだ消えていない。
	[ -d "${CCS_TEST_REPO}/.worktrees/done-1" ]
}

@test "gc --yes: merge 済み・push 済みの worktree とブランチを消す" {
	_wt_repo
	_wt_add done-1
	_wt_commit done-1
	git -C "${CCS_TEST_REPO}/.worktrees/done-1" push -q -u origin done-1
	git -C "$CCS_TEST_REPO" merge -q --no-ff -m merge done-1

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ ! -d "${CCS_TEST_REPO}/.worktrees/done-1" ]

	run git -C "$CCS_TEST_REPO" branch --list done-1
	[ -z "$output" ]
}

@test "gc --yes: 全部消えたら .worktrees も畳む" {
	_wt_repo
	_wt_add done-1
	_wt_commit done-1
	git -C "${CCS_TEST_REPO}/.worktrees/done-1" push -q -u origin done-1
	git -C "$CCS_TEST_REPO" merge -q --no-ff -m merge done-1

	run "$CCS_BIN" gc --yes
	[ ! -d "${CCS_TEST_REPO}/.worktrees" ]
}

# --- B. 未 merge / 未 push ---------------------------------------------------

@test "gc --yes: 未 merge のコミットがある worktree は消さない" {
	# **これが W3 の本命。** 未 push かつ未マージのコミットは、
	# --yes を打っても自動では消えない（git branch -d が拒む層）。
	_wt_repo
	_wt_add wip
	_wt_commit wip

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_TEST_REPO}/.worktrees/wip" ]

	run git -C "$CCS_TEST_REPO" branch --list wip
	[[ "$output" == *"wip"* ]] || return 1
}

@test "gc: 未 merge の worktree は報告だけ" {
	_wt_repo
	_wt_add wip
	_wt_commit wip

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs は消しません"* ]] || return 1
	[[ "$output" == *"wip"* ]] || return 1
	[[ "$output" == *"未 merge"* ]] || return 1
	# 消す候補には出さない。
	[[ "$output" != *"不要になった worktree"* ]] || return 1
}

@test "gc: 上流の無いブランチは未 push として報告する" {
	# ADR-0003 決定 7。上流が無いと git は fatal で落ちるので、
	# 「0 コミット ahead」と区別できない。**報告側に倒す。**
	_wt_repo
	_wt_add no-upstream
	# コミットせず、main と同じ位置のまま = merge 済み扱いになる。
	# それでも上流が無い限り消さない。

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"上流なし"* ]] || return 1
	[[ "$output" != *"不要になった worktree"* ]] || return 1
}

@test "gc --yes: 上流の無い worktree は消さない" {
	_wt_repo
	_wt_add no-upstream

	run "$CCS_BIN" gc --yes
	[ -d "${CCS_TEST_REPO}/.worktrees/no-upstream" ]
}

@test "gc: merge 済みでも未 push なら報告だけ" {
	_wt_repo
	_wt_add pushed-not
	_wt_commit pushed-not
	git -C "${CCS_TEST_REPO}/.worktrees/pushed-not" branch \
		--set-upstream-to=origin/main >/dev/null 2>&1
	git -C "$CCS_TEST_REPO" merge -q --no-ff -m merge pushed-not

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"未 push"* ]] || return 1
	[[ "$output" != *"不要になった worktree"* ]] || return 1
}

# --- C. dirty ----------------------------------------------------------------

@test "gc: 追跡外ファイルだけでも dirty として報告する" {
	# ADR-0003 決定 7 の「dirty（追跡外ファイルを含む）」。
	# git worktree remove 自身が追跡外ファイルで拒む（実測）ので、
	# 判定を合わせておかないと「消す候補に出したのに消えない」になる。
	_wt_repo
	_wt_add scratch
	printf 'x\n' >"${CCS_TEST_REPO}/.worktrees/scratch/untracked.txt"

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"変更が残っている worktree"* ]] || return 1
	[[ "$output" == *"scratch"* ]] || return 1
}

@test "gc --yes: dirty な worktree は絶対に消さない" {
	_wt_repo
	_wt_add scratch
	printf 'x\n' >"${CCS_TEST_REPO}/.worktrees/scratch/untracked.txt"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -f "${CCS_TEST_REPO}/.worktrees/scratch/untracked.txt" ]
}

@test "gc: dirty は merge 済み・push 済みでも消す候補にしない" {
	_wt_repo
	_wt_add dirty-merged
	_wt_commit dirty-merged
	git -C "${CCS_TEST_REPO}/.worktrees/dirty-merged" push -q -u origin dirty-merged
	git -C "$CCS_TEST_REPO" merge -q --no-ff -m merge dirty-merged
	printf 'x\n' >"${CCS_TEST_REPO}/.worktrees/dirty-merged/untracked.txt"

	run "$CCS_BIN" gc
	[[ "$output" != *"不要になった worktree"* ]] || return 1
	[[ "$output" == *"変更が残っている worktree"* ]] || return 1
}

# --- D. prunable -------------------------------------------------------------

@test "gc: ディレクトリだけ消えた worktree を prune の対象に出す" {
	_wt_repo
	_wt_add gone
	rm -rf "${CCS_TEST_REPO}/.worktrees/gone"

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"ディレクトリだけ消えた worktree"* ]] || return 1
	[[ "$output" == *"gone"* ]] || return 1
}

@test "gc --yes: prunable な登録を整理する" {
	_wt_repo
	_wt_add gone
	rm -rf "${CCS_TEST_REPO}/.worktrees/gone"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]

	run git -C "$CCS_TEST_REPO" worktree list --porcelain
	[[ "$output" != *"gone"* ]] || return 1
}

@test "gc --yes: prune はブランチを消さない" {
	# ディレクトリが消えただけで、コミットが不要になったわけではない。
	_wt_repo
	_wt_add gone
	_wt_commit gone
	rm -rf "${CCS_TEST_REPO}/.worktrees/gone"

	run "$CCS_BIN" gc --yes
	run git -C "$CCS_TEST_REPO" branch --list gone
	[[ "$output" == *"gone"* ]] || return 1
}

# --- 範囲 --------------------------------------------------------------------

@test "gc: .worktrees の外にある worktree は触らない" {
	# 人が手で切った worktree は ccs の場所ではない。
	_wt_repo
	git -C "$CCS_TEST_REPO" worktree add -q "${CCS_TEST_TMP}/manual" -b manual

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_TEST_TMP}/manual" ]
	[[ "$output" != *"manual"* ]] || return 1
}

@test "gc: 本体のリポジトリは触らない" {
	_wt_repo

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -f "${CCS_TEST_REPO}/README.md" ]
	[[ "$output" != *"x01"* ]] || return 1
}

@test "gc: worktree が無ければ何も言わない" {
	_wt_repo

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "gc: 稼働中の worktree は出さない" {
	# **照合は名前ではなく cwd**（ADR-0002 決定 3）。ここが名前だと、
	# 改名されたセッションの worktree を消す候補に出してしまう。
	_wt_repo

	run --separate-stderr "$CCS_BIN" new 'x01@live'
	[ "$status" -eq 0 ]

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" != *"live"* ]] || return 1
	[ -d "${CCS_TEST_REPO}/.worktrees/live" ]
}

@test "gc --yes: 稼働中の worktree は消さない" {
	_wt_repo

	run --separate-stderr "$CCS_BIN" new 'x01@live'
	[ "$status" -eq 0 ]

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_TEST_REPO}/.worktrees/live" ]
}

@test "gc: 名前を変えられても稼働中と分かる" {
	# tmux セッションを改名しても cwd は変わらない。**ここが本命。**
	# 名前で当てていると、この時点で「消す候補」に落ちる。
	_wt_repo
	_wt_add live2
	_wt_commit live2
	git -C "${CCS_TEST_REPO}/.worktrees/live2" push -q -u origin live2
	git -C "$CCS_TEST_REPO" merge -q --no-ff -m merge live2

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_REPO}/.worktrees/live2"
	[ "$status" -eq 0 ]
	local _slug
	_slug=$(echo "$output" | jq -r '.slug')
	ccs_tmux rename-session -t "=cc/${_slug}" 'cc/renamed'

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" != *"不要になった worktree"* ]] || return 1
	[ -d "${CCS_TEST_REPO}/.worktrees/live2" ]
}
