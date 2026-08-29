#!/bin/sh
#
# ccs を ghq のチェックアウトの外へ入れる。
#
# **PATH の ccs が git の作業ツリーを指していてはいけない。** そうなっていると、
# 走るコードは「main checkout の HEAD がその瞬間に何であるか」そのものになる。
# 2026-08-29 に事故になった: マージは worktree のセッションから GitHub 上で
# 起きるので main checkout には何も起きず、PATH の ccs は 5 コミット古いまま
# `ccs restore --last` を知らなかった。**「古い」だけでなく「可変」**なのが本体で、
# main で branch を切っただけでインストール操作なしに別物になり、`git pull` は
# 実体をその場で書き換えるので原子性も巻き戻しも無い。
#
# 形は同じマシンの claude / cursor-agent に倣う（版ごとのディレクトリ + symlink）。
#
#   $CCS_INSTALL_ROOT/versions/<版>   実行可能な単一ファイル
#   $CCS_INSTALL_ROOT/meta/<版>       commit / installed / source
#   $CCS_INSTALL_ROOT/current         いま指している版
#   $CCS_INSTALL_ROOT/source          install 元のチェックアウト
#   $CCS_INSTALL_ROOT/bin/ccs-install このスクリプトの複製
#   $CCS_INSTALL_ROOT/install.log     切り替えの記録（JSONL）
#   $CCS_BIN_DIR/ccs -> versions/<版>
#
# **複製を置くのは、ghq のチェックアウトが壊れていても巻き戻せるようにするため。**
# 巻き戻しがチェックアウトに依存していたら、「別 path で管理する」が徹底できない。

set -eu

# --- 設定 -------------------------------------------------------------------
#
# ccs 本体と同じキーを見る（ccs config に出る）。ここでは設定ファイルは読まない
# ── **設定ファイルを source しない**という方針（design.md §8.2）に加えて、
# インストーラが ccs の設定解析を写し取ると 2 箇所に同じものができるため。
# 設定ファイルで変えている人向けには、ccs 側が値を env で渡す。
: "${CCS_INSTALL_ROOT:=${HOME}/.local/share/ccs}"
: "${CCS_BIN_DIR:=${HOME}/.local/bin}"
: "${CCS_UPDATE_INTERVAL:=3600}"
: "${CCS_KEEP_VERSIONS:=5}"
: "${CCS_GIT_BIN:=git}"

VERSIONS_DIR="${CCS_INSTALL_ROOT}/versions"
META_DIR="${CCS_INSTALL_ROOT}/meta"
CURRENT_FILE="${CCS_INSTALL_ROOT}/current"
SOURCE_FILE="${CCS_INSTALL_ROOT}/source"
LASTCHECK_FILE="${CCS_INSTALL_ROOT}/last-check"
LOG_FILE="${CCS_INSTALL_ROOT}/install.log"
SELF_COPY="${CCS_INSTALL_ROOT}/bin/ccs-install"
LINK="${CCS_BIN_DIR}/ccs"

# 終了コード。**呼び出し側（ccs doctor / ccs hub up）が分岐に使う契約。**
EX_OK=0
EX_FAIL=1
EX_USAGE=2
EX_STALE=10   # 新しい版がある
EX_UNSURE=11  # 確認できなかった（fetch できない・素性が分からない）

warn() { printf '%s\n' "$*" >&2; }
die() {
	_code=$1
	shift
	warn "ccs-install: $*"
	exit "$_code"
}

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# JSONL で 1 行残す。**jq に依存しない**（インストーラは ccs より依存が少ない
# ほうがよい ── 入れる前に走るので）。値に入り得る文字だけを潰す。
log_event() {
	_ev=$1
	_from=${2:-}
	_to=${3:-}
	_why=${4:-}
	mkdir -p "$CCS_INSTALL_ROOT" 2>/dev/null || return 0
	printf '{"ts":"%s","event":"%s","from":"%s","to":"%s","trigger":"%s"}\n' \
		"$(now_iso)" "$_ev" "$_from" "$_to" "$_why" >>"$LOG_FILE" 2>/dev/null || true
}

# --- 版の導出（bin/ccs の ccs_build_id と同じ規則）-------------------------
#
# **綴りから種別を当てない。** 短い sha は数字で始まることがある（実測
# 3f5673a）ので「数字で始まれば tag 由来」は誤判定する。--always を付けずに
# describe させ、成否そのものを種別にする。
#
# 引数: <チェックアウト> <committish>
# committish が空なら作業ツリーの状態（dirty も含む）を見る。
build_id_for() {
	_bi_repo=$1
	_bi_ref=${2:-}

	if [ -n "$_bi_ref" ]; then
		if _bi_desc=$("$CCS_GIT_BIN" -C "$_bi_repo" describe --tags "$_bi_ref" 2>/dev/null) &&
			[ -n "$_bi_desc" ]; then
			printf '%s\n' "${_bi_desc#v}"
			return 0
		fi
		_bi_sha=$("$CCS_GIT_BIN" -C "$_bi_repo" rev-parse --short "$_bi_ref" 2>/dev/null) || return 1
		printf '%s+%s\n' "$(anchor_of "$_bi_repo" "$_bi_ref")" "$_bi_sha"
		return 0
	fi

	if _bi_desc=$("$CCS_GIT_BIN" -C "$_bi_repo" describe --tags --dirty 2>/dev/null) &&
		[ -n "$_bi_desc" ]; then
		printf '%s\n' "${_bi_desc#v}"
		return 0
	fi
	_bi_sha=$("$CCS_GIT_BIN" -C "$_bi_repo" rev-parse --short HEAD 2>/dev/null) || return 1
	"$CCS_GIT_BIN" -C "$_bi_repo" diff --quiet HEAD 2>/dev/null || _bi_sha="${_bi_sha}-dirty"
	printf '%s+%s\n' "$(anchor_of "$_bi_repo" '')" "$_bi_sha"
}

# tag がまだ無いときの錨（bin/ccs の CCS_VERSION）。
#
# **その committish の bin/ccs から読む。** 作業ツリーから読むと、origin/main
# の版を計算しているのに手元で書き換えた錨を混ぜてしまう。
anchor_of() {
	_an_repo=$1
	_an_ref=${2:-}
	if [ -n "$_an_ref" ]; then
		_an_src=$("$CCS_GIT_BIN" -C "$_an_repo" show "${_an_ref}:bin/ccs" 2>/dev/null) || {
			printf '0.0.0\n'
			return 0
		}
		printf '%s' "$_an_src" | sed -n "s/^CCS_VERSION='\\([0-9.]*\\)'\$/\\1/p" | head -1
	else
		sed -n "s/^CCS_VERSION='\\([0-9.]*\\)'\$/\\1/p" "${_an_repo}/bin/ccs" 2>/dev/null | head -1
	fi
}

# --- 素性 -------------------------------------------------------------------

read_current() { [ -f "$CURRENT_FILE" ] && cat "$CURRENT_FILE" || printf ''; }

read_meta() {
	_rm_id=$1
	_rm_key=$2
	[ -f "${META_DIR}/${_rm_id}" ] || return 1
	sed -n "s/^${_rm_key}=//p" "${META_DIR}/${_rm_id}" | head -1
}

# 控えてある install 元のチェックアウト。**代わりを勝手に探さない。**
#
# 消えていたら「分からない」と言う。ここで「自分が居るリポジトリ」に落ちると、
# **基準点が黙って別のリポジトリにすり替わる** ── 実測で踏んだ: install 元を
# 消したあと ccs の作業ツリーから --check を打つと、そちらの origin/main を
# 「新しい版」として報告した。検知の根拠が入れ替わるのは、古さを見逃すより悪い。
recorded_source() {
	[ -f "$SOURCE_FILE" ] || return 1
	_rs=$(cat "$SOURCE_FILE")
	[ -n "$_rs" ] || return 1
	# worktree の .git は**ファイル**なので、-d だけでは弾いてしまう。
	if [ -d "${_rs}/.git" ] || [ -f "${_rs}/.git" ]; then
		printf '%s\n' "$_rs"
		return 0
	fi
	return 1
}

# 控えが無いときに、このスクリプトの在処から辿る。
#
# **初回の install 専用。** clone しただけの状態で `make install` を打てる
# ようにするためのもので、検知（--check / --auto）では使わない。
enclosing_checkout() {
	_ec_self=$(cd "$(dirname "$0")" && pwd -P) || return 1
	"$CCS_GIT_BIN" -C "$_ec_self" rev-parse --show-toplevel 2>/dev/null
}

resolve_source() {
	recorded_source && return 0
	enclosing_checkout
}

# --- 切り替え ---------------------------------------------------------------

# **symlink を rename で差し替える。** 同じディレクトリへの rename は原子的なので、
# 「消えている瞬間」が無い。走っているプロセスは自分が開いたファイルを持ち続ける
# ので、hub が 300 秒ごとに叩いている最中でも壊れない。
swap_link() {
	_sl_target=$1
	mkdir -p "$CCS_BIN_DIR"
	_sl_tmp="${LINK}.new.$$"
	ln -sfn "$_sl_target" "$_sl_tmp"
	mv -f "$_sl_tmp" "$LINK"
}

# **切り替える前に、その版が動くことを確かめる。** 自動切替では人が見ていないので、
# 起動もできないものに差し替えると hub ごと止まる。版を名乗れれば最低限は動く。
smoke_test() {
	_st_bin=$1
	_st_out=$("$_st_bin" version --short 2>/dev/null) || return 1
	[ -n "$_st_out" ] || return 1
	return 0
}

switch_to() {
	_sw_id=$1
	_sw_why=$2
	_sw_bin="${VERSIONS_DIR}/${_sw_id}"

	[ -x "$_sw_bin" ] || die "$EX_FAIL" "そんな版は入っていません: ${_sw_id}
  入っている版: ccs-install --list"

	smoke_test "$_sw_bin" ||
		die "$EX_FAIL" "版 ${_sw_id} が version を答えません。切り替えずに止めます。"

	_sw_from=$(read_current)
	[ "$_sw_from" = "$_sw_id" ] && [ -L "$LINK" ] && {
		printf 'ccs %s（変更なし）\n' "$_sw_id"
		return 0
	}

	swap_link "$_sw_bin"
	printf '%s\n' "$_sw_id" >"$CURRENT_FILE"
	# **切り替え「後」の版を書く。** 自動切替でこれを実行しているのは古い版の
	# プロセス（launchd から起動された ccs）なので、自分の版を書くと記録が
	# 「何から何へ」を取り違える。
	log_event 'switch' "$_sw_from" "$_sw_id" "$_sw_why"

	if [ -n "$_sw_from" ] && [ "$_sw_from" != "$_sw_id" ]; then
		printf 'ccs %s へ切り替えました（前: %s）\n' "$_sw_id" "$_sw_from"
		printf '  戻す: %s --switch %s\n' "$(tilde "$SELF_COPY")" "$_sw_from"
	else
		printf 'ccs %s を入れました\n' "$_sw_id"
	fi
}

tilde() { case $1 in "${HOME}"/*) printf '~%s' "${1#"${HOME}"}" ;; *) printf '%s' "$1" ;; esac; }

# 古い版を落とす。**いま指しているものと直前のものは残す。**
prune_versions() {
	[ -d "$VERSIONS_DIR" ] || return 0
	_pv_keep=$CCS_KEEP_VERSIONS
	[ "$_pv_keep" -ge 2 ] 2>/dev/null || _pv_keep=2
	_pv_cur=$(read_current)
	# 新しい順（mtime）に並べ、keep を超えたものを消す。
	_pv_n=0
	# **新しい順に並べたいので ls を読む。** 版のファイル名は自分で作っており
	# （git describe の出力＝英数・ドット・ハイフン・プラスだけ）、空白も改行も
	# 入らない。glob では mtime 順に並べられないため、ここは ls を使う。
	# shellcheck disable=SC2045
	for _pv_f in $(ls -t "$VERSIONS_DIR" 2>/dev/null); do
		[ "$_pv_f" = "$_pv_cur" ] && continue
		_pv_n=$((_pv_n + 1))
		[ "$_pv_n" -lt "$_pv_keep" ] && continue
		rm -f "${VERSIONS_DIR}/${_pv_f}" "${META_DIR}/${_pv_f}"
	done
}

# --- install ----------------------------------------------------------------

# <チェックアウト> [committish] を入れる。
#
# committish を渡すと、**作業ツリーを一切触らずに** その版の bin/ccs を
# オブジェクトから取り出す（`git show <ref>:bin/ccs`）。これが「ghq のチェック
# アウトは実装用、動作は別 path」を成立させている核心 ── pull も branch 切り替えも
# 要らないので、他のセッションが使っている作業ツリーに手を出さずに済む。
do_install() {
	_di_repo=$1
	_di_ref=${2:-}
	_di_why=${3:-manual}

	[ -d "$_di_repo" ] || die "$EX_FAIL" "チェックアウトが見つかりません: ${_di_repo}"

	_di_id=$(build_id_for "$_di_repo" "$_di_ref") ||
		die "$EX_FAIL" "版を決められません（git リポジトリではない？）: ${_di_repo}"
	[ -n "$_di_id" ] || die "$EX_FAIL" "版を決められません: ${_di_repo}"

	if [ -n "$_di_ref" ]; then
		_di_sha=$("$CCS_GIT_BIN" -C "$_di_repo" rev-parse "$_di_ref") ||
			die "$EX_FAIL" "解決できません: ${_di_ref}"
	else
		_di_sha=$("$CCS_GIT_BIN" -C "$_di_repo" rev-parse HEAD) ||
			die "$EX_FAIL" "HEAD を読めません: ${_di_repo}"
	fi

	mkdir -p "$VERSIONS_DIR" "$META_DIR" "${CCS_INSTALL_ROOT}/bin"

	_di_dest="${VERSIONS_DIR}/${_di_id}"
	_di_tmp="${_di_dest}.tmp.$$"

	if [ -n "$_di_ref" ]; then
		"$CCS_GIT_BIN" -C "$_di_repo" show "${_di_ref}:bin/ccs" >"$_di_tmp" ||
			die "$EX_FAIL" "取り出せません: ${_di_ref}:bin/ccs"
	else
		cp "${_di_repo}/bin/ccs" "$_di_tmp" ||
			die "$EX_FAIL" "読めません: ${_di_repo}/bin/ccs"
	fi

	# **ここで焼き込む。** repo の外に出た実体は git を引けないので、
	# 版を名乗る根拠はこの 1 行だけになる（bin/ccs の CCS_BUILD）。
	sed "s/^CCS_BUILD=''\$/CCS_BUILD='${_di_id}'/" "$_di_tmp" >"${_di_tmp}.stamped"
	mv -f "${_di_tmp}.stamped" "$_di_tmp"
	chmod +x "$_di_tmp"

	grep -q "^CCS_BUILD='${_di_id}'\$" "$_di_tmp" || {
		rm -f "$_di_tmp"
		die "$EX_FAIL" "焼き込みに失敗しました（CCS_BUILD の行が見つからない）"
	}
	smoke_test "$_di_tmp" || {
		rm -f "$_di_tmp"
		die "$EX_FAIL" "取り出した ${_di_id} が version を答えません。入れずに止めます。"
	}

	mv -f "$_di_tmp" "$_di_dest"

	cat >"${META_DIR}/${_di_id}" <<META
commit=${_di_sha}
installed=$(now_iso)
source=${_di_repo}
META

	cp "$0" "$SELF_COPY" 2>/dev/null || true
	chmod +x "$SELF_COPY" 2>/dev/null || true
	printf '%s\n' "$_di_repo" >"$SOURCE_FILE"

	switch_to "$_di_id" "$_di_why"
	prune_versions
	stamp_checked
}

# --- 検知 -------------------------------------------------------------------

stamp_checked() {
	mkdir -p "$CCS_INSTALL_ROOT" 2>/dev/null || return 0
	date '+%s' >"$LASTCHECK_FILE" 2>/dev/null || true
}

check_is_due() {
	[ -f "$LASTCHECK_FILE" ] || return 0
	_cd_last=$(cat "$LASTCHECK_FILE" 2>/dev/null) || return 0
	_cd_now=$(date '+%s')
	[ $((_cd_now - _cd_last)) -ge "$CCS_UPDATE_INTERVAL" ]
}

# origin/main と、いま入っている版を突き合わせる。
#
# 出力は KEY=VALUE。**呼び出し側（ccs doctor / ccs hub up）との契約。**
# 終了コード: 0 最新 / 10 古い / 11 確認できなかった
do_check() {
	_dc_force=${1:-}

	_dc_installed=$(read_current)
	[ -n "$_dc_installed" ] || _dc_installed='(未インストール)'

	# **控えてある install 元だけを見る**（resolve_source の fallback は使わない）。
	# 代わりを探すと基準点が黙って別のリポジトリにすり替わる。
	_dc_repo=$(recorded_source) || {
		_dc_was=''
		[ -f "$SOURCE_FILE" ] && _dc_was=$(cat "$SOURCE_FILE")
		if [ -n "$_dc_was" ]; then
			printf 'state=unsure\ninstalled=%s\nfetched=no\nreason=%s\n' \
				"$_dc_installed" \
				"install 元のチェックアウトがありません: ${_dc_was}（消えた／移動した？）"
		else
			printf 'state=unsure\ninstalled=%s\nfetched=no\nreason=%s\n' \
				"$_dc_installed" 'install 元のチェックアウトを控えていません'
		fi
		return "$EX_UNSURE"
	}

	# **fetch しないと基準点が古い。** ここを黙って飛ばすと「最新です」と
	# 言いながら実際は何も見ていない状態になる ── 検知が盲目になる。
	_dc_fetched=''
	if [ -n "$_dc_force" ] || check_is_due; then
		if "$CCS_GIT_BIN" -C "$_dc_repo" fetch --quiet origin main 2>/dev/null; then
			_dc_fetched='yes'
			stamp_checked
		else
			_dc_fetched='no'
		fi
	else
		_dc_fetched='cached'
	fi

	_dc_latest_sha=$("$CCS_GIT_BIN" -C "$_dc_repo" rev-parse origin/main 2>/dev/null) || {
		printf 'state=unsure\ninstalled=%s\nsource=%s\nfetched=%s\nreason=%s\n' \
			"$_dc_installed" "$_dc_repo" "$_dc_fetched" 'origin/main を読めません'
		return "$EX_UNSURE"
	}

	if [ "$_dc_fetched" = 'no' ]; then
		# ref は読めるが、それが今のリモートと同じとは限らない。
		# **「最新です」と言い切らない。** 黙って盲目になるくらいなら、
		# 確認できていないと言うほうがよい。
		printf 'state=unsure\ninstalled=%s\nsource=%s\nfetched=no\nreason=%s\n' \
			"$_dc_installed" "$_dc_repo" 'fetch できませんでした（オフライン？）。確認できていません'
		return "$EX_UNSURE"
	fi

	_dc_cur_sha=''
	[ -n "$(read_current)" ] && _dc_cur_sha=$(read_meta "$(read_current)" commit 2>/dev/null || printf '')

	_dc_latest_id=$(build_id_for "$_dc_repo" 'origin/main' 2>/dev/null || printf '')

	if [ -n "$_dc_cur_sha" ] && [ "$_dc_cur_sha" = "$_dc_latest_sha" ]; then
		printf 'state=current\ninstalled=%s\nlatest=%s\nsource=%s\nfetched=%s\n' \
			"$_dc_installed" "$_dc_latest_id" "$_dc_repo" "$_dc_fetched"
		return "$EX_OK"
	fi

	printf 'state=stale\ninstalled=%s\nlatest=%s\nsource=%s\nfetched=%s\n' \
		"$_dc_installed" "$_dc_latest_id" "$_dc_repo" "$_dc_fetched"
	return "$EX_STALE"
}

# --- 使い方 -----------------------------------------------------------------

usage() {
	cat <<'EOF'
ccs-install — ccs を ghq のチェックアウトの外へ入れる

使い方:
  ccs-install [<チェックアウト>]     いまの作業ツリーを入れて切り替える
  ccs-install --auto                 origin/main が新しければ入れて切り替える
  ccs-install --check [--force]      新しい版があるか見る（切り替えない）
  ccs-install --list                 入っている版を並べる
  ccs-install --switch <版>          その版へ切り替える（巻き戻し）
  ccs-install --where                いま何がどこに入っているか

終了コード:
  0 成功 / 最新    2 使い方の誤り   10 新しい版がある   11 確認できなかった

置き場所（env か ccs の設定で変えられる）:
  CCS_INSTALL_ROOT   [既定: ~/.local/share/ccs]
  CCS_BIN_DIR        [既定: ~/.local/bin]
  CCS_UPDATE_INTERVAL[既定: 3600]  検知でネットワークを使う間隔（秒）
  CCS_KEEP_VERSIONS  [既定: 5]     残す版の数
EOF
}

cmd_list() {
	[ -d "$VERSIONS_DIR" ] || die "$EX_FAIL" 'まだ何も入っていません'
	_cl_cur=$(read_current)
	# 新しい順。ファイル名の制約は prune_versions のコメントと同じ。
	# shellcheck disable=SC2045
	for _cl_f in $(ls -t "$VERSIONS_DIR" 2>/dev/null); do
		if [ "$_cl_f" = "$_cl_cur" ]; then
			printf '* %s\n' "$_cl_f"
		else
			printf '  %s\n' "$_cl_f"
		fi
	done
}

cmd_where() {
	printf '入っている版: %s\n' "$(read_current || printf '(無し)')"
	printf 'PATH の ccs:  %s\n' "$(tilde "$LINK")"
	if [ -L "$LINK" ]; then
		printf '  → %s\n' "$(tilde "$(readlink "$LINK")")"
	else
		printf '  → **symlink ではありません**\n'
	fi
	printf 'install 元:   %s\n' "$(resolve_source 2>/dev/null || printf '(分かりません)')"
	printf '記録:         %s\n' "$(tilde "$LOG_FILE")"
}

main() {
	[ $# -eq 0 ] && {
		_src=$(resolve_source) || die "$EX_FAIL" 'チェックアウトが分かりません。パスを渡してください。'
		do_install "$_src" '' 'manual'
		return 0
	}

	case $1 in
	-h | --help | help) usage ;;
	--list) cmd_list ;;
	--where) cmd_where ;;
	--check)
		shift
		_force=''
		[ "${1:-}" = '--force' ] && _force=1
		do_check "$_force"
		;;
	--switch)
		[ $# -ge 2 ] || die "$EX_USAGE" '--switch には版が要ります（ccs-install --list）'
		switch_to "$2" 'manual'
		;;
	--auto)
		_out=$(do_check '') && _st=0 || _st=$?
		case $_st in
		"$EX_OK") printf '%s\n' "$_out" | sed -n 's/^installed=/ccs は最新です: /p' ;;
		"$EX_STALE")
			_repo=$(printf '%s' "$_out" | sed -n 's/^source=//p' | head -1)
			[ -n "$_repo" ] || die "$EX_FAIL" 'install 元が分かりません'
			do_install "$_repo" 'origin/main' 'auto'
			;;
		*)
			printf '%s\n' "$_out" | sed -n 's/^reason=/ccs-install: /p' >&2
			return "$_st"
			;;
		esac
		;;
	-*) die "$EX_USAGE" "知らないオプション: $1" ;;
	*) do_install "$1" '' 'manual' ;;
	esac
}

main "$@"
