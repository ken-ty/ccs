# 開発用のタスク。CI もここを呼ぶ ── CI とローカルで手順がずれると、
# 「ローカルでは通る」が起きる。

SHELL := /bin/sh

BATS ?= bats
SHELLCHECK ?= shellcheck

# **LC_ALL=C で走らせる。** macOS 標準の bash 3.2 + bats 1.14 の組み合わせだと、
# 日本語を含むテスト名が化けて「unknown test name」で 1 件も実行されない。
# ロケールを固定すると通る（bash を新しくしなくてよい）。
BATS_ENV ?= LC_ALL=C

.PHONY: help
help:
	@echo 'make lint   shellcheck をかける'
	@echo 'make unit   unit テストだけ走らせる（外部プロセスを起動しない）'
	@echo 'make test   全テスト（unit + integration）'
	@echo 'make check  lint + test'
	@echo 'make reap   前回の実行が取り残したテストのサンドボックスを回収する'
	@echo 'make docs   ドキュメントをローカルで配信する'
	@echo
	@echo 'make setup-hooks  git のフックを張る（clone したら 1 度。worktree では不要）'

.PHONY: lint
lint:
	$(SHELLCHECK) -s sh bin/ccs
	@# テストとフィクスチャも検査する。スタブが壊れると、テストは
	@# 「落ちる」のではなく「間違ったものを検証する」ので気づきにくい。
	@# **`.py` は除く。** ここは「実行可能なフィクスチャ＝シェル」という前提で
	@# 書かれていたが、pty を作るフィクスチャだけは sh では書けない
	@# （scripts/termshot.py と同じ扱いにする）。
	@if [ -d test/fixtures ]; then \
		find test/fixtures -type f -perm -u+x ! -name '*.py' -exec $(SHELLCHECK) -s sh {} +; \
	fi
	@# フックも検査する。**CI は main でしか回らない**ので、hooks/pre-push が
	@# 唯一の関門になった。壊れたフックは「落ちない」＝素通しになるため、
	@# bin/ccs と同じ基準で見る。
	@if [ -d hooks ]; then \
		find hooks -type f -perm -u+x -exec $(SHELLCHECK) -s sh {} +; \
	fi
	@# テストの後片付けも検査する。**壊れても誰も気づかない**種類のもの
	@# （黙って何も片付けなくなるだけ）なので、静的に見る。
	$(SHELLCHECK) -s sh test/reap-tmux
	@# **素の `tmux` を禁じる。** ソケットを指定しない tmux は、利用者が実際に
	@# 開いているサーバを触る。テストが中断されるとそこにセッションが残り、
	@# `cc/` 接頭辞が無いので `ccs ls` にも出ない ── 誰も気づけない
	@# （2026-08-27 に fake-claude.bats で 1 件見つかった）。**破っても緑になる**
	@# 種類の規約なので、静的に見張る。テストからは ccs_tmux を使うこと。
	@if grep -rn --include='*.bats' -E '(^|[[:space:]]|[;&|(])tmux[[:space:]]+[-a-z]' test | \
		grep -vE '^[^:]*:[0-9]+:[[:space:]]*#'; then \
		echo '' >&2; \
		echo '上の素の tmux は、利用者が実際に開いているサーバを触ります。' >&2; \
		echo 'テスト専用のサーバを使ってください: ccs_tmux <args>' >&2; \
		echo '（本物の tmux を名指しで呼ぶ必要があるなら "$${CCS_REAL_TMUX:-tmux}" -S ...）' >&2; \
		exit 1; \
	fi
	@# **素の [[ ]] を禁じる。** macOS 標準の bash 3.2 では、テストの途中に
	@# 置いた [[ ]] は失敗しても errexit で落ちない（実測: false / [ ] / 関数の
	@# 戻り値はどれも落ちるのに、[[ ]] だけ素通りする。bash 4 で直っている）。
	@# 放っておくと 200 件のアサーションが手元で空振りし、Linux の CI でだけ
	@# 落ちる ── 実際にそうなっていた。`|| return 1` を付ければ両方で落ちる。
	@if grep -rn '^[[:space:]]*\[\[ .*\]\][[:space:]]*$$' test --include='*.bats'; then \
		echo '' >&2; \
		echo '上の [[ ]] は macOS の bash 3.2 では失敗しても素通りします。' >&2; \
		echo '行末に `|| return 1` を足してください。' >&2; \
		exit 1; \
	fi
	@# **焼き込み済みの bin/ccs をコミットさせない。** CCS_BUILD は
	@# scripts/install.sh が install 時に埋めるところで、リポジトリの中では
	@# 必ず空。埋まったままコミットすると、そのファイルはどのコミットに
	@# 置かれても同じ版を名乗り続ける ── 手書きの番号が 0.0.3 で止まって
	@# 「restore --last を持つ版と持たない版が同じ答えを返す」に陥ったのと
	@# **まったく同じ壊れ方**を、自動化した経路で再現することになる。
	@if ! grep -q "^CCS_BUILD=''$$" bin/ccs; then \
		echo 'bin/ccs の CCS_BUILD が空ではありません。' >&2; \
		grep -n '^CCS_BUILD=' bin/ccs >&2; \
		echo '' >&2; \
		echo '焼き込みは install が行うもので、コミットしてはいけません。' >&2; \
		echo "CCS_BUILD='' に戻してください。" >&2; \
		exit 1; \
	fi
	@# 錨（tag がまだ無いときの版）は X.Y.Z の形であること。
	@# `--short` が返す対外的な契約がここから出るため。
	@if ! grep -qE "^CCS_VERSION='[0-9]+\.[0-9]+\.[0-9]+'$$" bin/ccs; then \
		echo 'bin/ccs の CCS_VERSION が X.Y.Z の形ではありません。' >&2; \
		grep -n '^CCS_VERSION=' bin/ccs >&2; \
		exit 1; \
	fi

# core.hooksPath は .git/config に入る**リポジトリごとのローカル設定**で、
# **clone には付いてこない**（.git/config は複製されない）。だから clone したら
# 1 度張る必要がある。hooks/ をそのまま指すので、フックを直せばすぐ反映される
# （.git/hooks へコピーする方式だと配ったきり古くなる）。
#
# **同じリポジトリの worktree には引き継がれる。** core.hooksPath は共有の
# .git/config にあり、worktree もそれを読むため。worktree を足すたびに
# 実行し直す必要は無い。
#
# **CI は main への push でしか回らない。**このフックが唯一の関門なので、
# 新しい clone では必ずこれを実行すること。
.PHONY: setup-hooks
setup-hooks:
	git config core.hooksPath hooks
	@echo "core.hooksPath = $$(git config core.hooksPath)"
	@if [ -x hooks/pre-push ]; then \
		echo 'hooks/pre-push: 実行可'; \
	else \
		echo 'hooks/pre-push: **実行権がありません** chmod +x hooks/pre-push' >&2; \
		exit 1; \
	fi

.PHONY: unit
unit:
	$(BATS_ENV) $(BATS) test/unit

.PHONY: integration
integration:
	@if [ -d test/integration ] && [ -n "$$(find test/integration -name '*.bats' -print -quit)" ]; then \
		$(BATS_ENV) $(BATS) test/integration; \
	else \
		echo 'integration: まだテストがありません（ROADMAP S4 以降）'; \
	fi

.PHONY: test
test: unit integration

# 前回の実行が取り残したテストのサンドボックスを回収する。
#
# **プロセスグループごと殺してテストを止めたら、これを打つ。** そこまでいくと
# 見張り（test_helper.bash の ccs_watch_sandbox）も一緒に死ぬので、tmux サーバが
# そのまま残る ── 端末を閉じても死なない。`make integration` の頭でも自動で
# 走るが、次に走らせるまで残るのは気持ちが悪い。
.PHONY: reap
reap:
	test/reap-tmux

.PHONY: check
check: lint test

# uvx 経由で動かす。グローバルに mkdocs を入れさせない ── 入れさせると
# 手元と CI で版がずれる。requirements-docs.txt で固定してあるので、
# どちらも同じものを使う。
UVX ?= uvx --quiet --with-requirements requirements-docs.txt

.PHONY: docs
docs:
	$(UVX) mkdocs serve

.PHONY: docs-build
docs-build:
	$(UVX) mkdocs build --strict

.PHONY: shots
shots:
	@echo 'スクリーンショットは実際の実行結果から作る（作り物の画面は置かない）:'
	@echo '  ccs ls | python3 scripts/termshot.py -o docs/img/ls.svg --title "ccs ls"'
