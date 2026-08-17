#!/usr/bin/env python3
"""キャプチャ済みの端末出力を SVG にする。

**作り物の画面を描くための道具ではない。** 実際に走らせた結果を貼るためのもの。
入力は `ccs ... | tee` や `tmux capture-pane -p` で取った実物のテキストを渡す。

標準ライブラリだけで動く。ドキュメントを作るためだけに ffmpeg や ttyd を
入れたくないのと、生成物が決定的（同じ入力なら同じ SVG）であってほしいため。
決定的なので、差分がそのままレビューできる。

使い方:

    ccs ls | python3 scripts/termshot.py -o docs/img/ls.svg --title 'ccs ls'
    python3 scripts/termshot.py captured.txt -o out.svg

MkDocs の light / dark 両方で読めるよう、SVG の中に両方の配色を入れて
`prefers-color-scheme` で切り替える（画像を 2 枚持たなくて済む）。
"""

from __future__ import annotations

import argparse
import re
import sys
from xml.sax.saxutils import escape

# 端末の色指定は落とす。tmux capture-pane は既定で付けないが、
# 手で `script` などを通したテキストが来ることもある。
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")

# 文字送り。等幅前提なので実測ではなく定数で置く。
CHAR_W = 8.4
LINE_H = 20.0
PAD_X = 16.0
PAD_TOP = 44.0  # タイトルバーのぶん
PAD_BOTTOM = 16.0

# 行頭がこれなら「人が打ったコマンド」として色を変える。
PROMPT_PREFIXES = ("$ ", "% ", "> ")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def expand_tabs(text: str) -> str:
    # SVG には tab の概念が無いので、先に空白へ潰す。
    return text.expandtabs(8)


def wcwidth_approx(line: str) -> int:
    """全角を 2 桁として数える。

    日本語を含む出力を等幅で置くと、素朴な len() では幅が足りずに
    枠から溢れる。厳密な East Asian Width の実装は入れず、よく出る
    範囲だけ 2 桁として数える。
    """
    width = 0
    for ch in line:
        code = ord(ch)
        if (
            0x1100 <= code <= 0x115F
            or 0x2E80 <= code <= 0xA4CF
            or 0xAC00 <= code <= 0xD7A3
            or 0xF900 <= code <= 0xFAFF
            or 0xFE30 <= code <= 0xFE6F
            or 0xFF00 <= code <= 0xFF60
            or 0xFFE0 <= code <= 0xFFE6
            or 0x20000 <= code <= 0x3FFFD
        ):
            width += 2
        else:
            width += 1
    return width


def render(lines: list[str], title: str) -> str:
    cols = max((wcwidth_approx(ln) for ln in lines), default=0)
    cols = max(cols, wcwidth_approx(title) + 4, 24)

    width = cols * CHAR_W + PAD_X * 2
    height = len(lines) * LINE_H + PAD_TOP + PAD_BOTTOM

    body: list[str] = []
    for i, line in enumerate(lines):
        y = PAD_TOP + i * LINE_H
        cls = "cmd" if line.startswith(PROMPT_PREFIXES) else "out"
        body.append(
            f'<text x="{PAD_X:.1f}" y="{y:.1f}" class="{cls}">{escape(line)}</text>'
        )

    dots = "".join(
        f'<circle cx="{x}" cy="20" r="6" class="dot dot{n}"/>'
        for n, x in enumerate((22, 44, 66), start=1)
    )

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" \
height="{height:.0f}" viewBox="0 0 {width:.0f} {height:.0f}" role="img" \
aria-label="{escape(title)}">
  <style>
    /* light と dark の両方を持たせて prefers-color-scheme で切り替える。
       画像を 2 枚用意して読み手の設定で出し分ける手間を省くため。 */
    .bg   {{ fill: #ffffff; stroke: #d8dde3; }}
    .bar  {{ fill: #f2f4f7; }}
    .ttl  {{ fill: #5b6672; }}
    .out  {{ fill: #24292f; }}
    .cmd  {{ fill: #0a5ca8; font-weight: 600; }}
    .dot1 {{ fill: #ff5f57; }} .dot2 {{ fill: #febc2e; }} .dot3 {{ fill: #28c840; }}
    text  {{ font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo,
             Consolas, "Liberation Mono", monospace;
             font-size: 13.5px; white-space: pre; dominant-baseline: middle; }}
    @media (prefers-color-scheme: dark) {{
      .bg  {{ fill: #14171c; stroke: #2c313a; }}
      .bar {{ fill: #1d2128; }}
      .ttl {{ fill: #98a2b0; }}
      .out {{ fill: #d7dde5; }}
      .cmd {{ fill: #6cb6ff; }}
    }}
  </style>
  <rect class="bg" x="0.5" y="0.5" width="{width - 1:.0f}" height="{height - 1:.0f}" rx="8"/>
  <path class="bar" d="M0.5 8.5 a8 8 0 0 1 8 -8 h{width - 17:.0f} a8 8 0 0 1 8 8 v31.5 h-{width - 1:.0f} z"/>
  {dots}
  <text x="{width / 2:.0f}" y="20" class="ttl" text-anchor="middle" \
font-size="12">{escape(title)}</text>
{chr(10).join("  " + b for b in body)}
</svg>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", nargs="?", help="キャプチャ済みのテキスト（既定は標準入力）")
    ap.add_argument("-o", "--output", help="出力先の SVG（既定は標準出力）")
    ap.add_argument("--title", default="terminal", help="タイトルバーに出す文字列")
    args = ap.parse_args()

    raw = (
        open(args.input, encoding="utf-8").read()
        if args.input
        else sys.stdin.read()
    )

    lines = [expand_tabs(strip_ansi(ln)) for ln in raw.rstrip("\n").split("\n")]
    # 末尾の空行は落とす。capture-pane はペインの高さぶん空行を返すため、
    # そのままだと下半分が余白の画像になる。
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        print("termshot: 入力が空です", file=sys.stderr)
        return 1

    svg = render(lines, args.title)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(svg)
    else:
        sys.stdout.write(svg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
