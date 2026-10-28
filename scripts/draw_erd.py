"""
draw the crow's foot erd of the kodes_retail database as a compact svg
(and a png through chromium when playwright is available).

usage:  python3 scripts/draw_erd.py
output: docs/erd.svg, docs/erd.png
"""
import re
from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path("docs")

# (type, column, key, note) per table, in the same order as schema.sql
TABLES = {
    "countries": [
        ("smallint", "country_id", "PK", "auto_increment"),
        ("varchar(60)", "country_name", "UK", "not null"),
        ("boolean", "is_country", "", "default true"),
    ],
    "customers": [
        ("int", "customer_id", "PK", "auto_increment"),
        ("smallint", "country_id", "FK", "not null"),
        ("boolean", "is_guest", "", "default false"),
        ("varchar(255)", "email", "UK", "null, format check"),
        ("varchar(20)", "phone", "", "null, format check"),
    ],
    "invoices": [
        ("varchar(10)", "invoice_no", "PK", ""),
        ("int", "customer_id", "FK", "not null"),
        ("datetime", "invoice_date", "", "default now"),
        ("varchar(10)", "invoice_type", "", "Sale | Return"),
        ("varchar(10)", "status", "", "Completed | Cancelled"),
        ("datetime", "cancelled_at", "", "null"),
    ],
    "inventory": [
        ("varchar(20)", "stock_code", "PK, FK", ""),
        ("int", "quantity_on_hand", "", "check >= 0"),
        ("int", "reorder_level", "", "check >= 0"),
        ("datetime", "last_updated", "", "auto"),
    ],
    "products": [
        ("varchar(20)", "stock_code", "PK", ""),
        ("varchar(255)", "description", "", "not null"),
        ("decimal(10,2)", "unit_price", "", "list price, >= 0"),
        ("boolean", "is_stock_item", "", "default true"),
    ],
    "invoice_lines": [
        ("varchar(10)", "invoice_no", "PK, FK", ""),
        ("smallint", "line_no", "PK", "check >= 1"),
        ("varchar(20)", "stock_code", "FK", "not null"),
        ("int", "quantity", "", "check <> 0"),
        ("decimal(10,3)", "unit_price", "", "price paid, >= 0"),
    ],
}
GRID = [["countries", "customers", "invoices"], ["inventory", "products", "invoice_lines"]]

CW = 6.9          # average character width at 12.5px
ROW, HEAD, PAD = 24, 30, 9
GAP_X, GAP_Y, MARGIN = 132, 92, 24


def col_widths(rows):
    return [max(len(r[i]) for r in rows) * CW + 2 * PAD for i in range(4)]


widths = {t: col_widths(r) for t, r in TABLES.items()}
box_w = {t: max(sum(w), len(t) * 8 + 40) for t, w in widths.items()}
box_h = {t: HEAD + ROW * len(r) for t, r in TABLES.items()}
col_w = [max(box_w[GRID[r][c]] for r in range(2)) for c in range(3)]
x_of = [MARGIN + sum(col_w[:c]) + GAP_X * c for c in range(3)]
row_h = [max(box_h[t] for t in GRID[r]) for r in range(2)]
y_of = [MARGIN + 18, MARGIN + 18 + row_h[0] + GAP_Y]
pos = {}
for r, names in enumerate(GRID):
    for c, t in enumerate(names):
        pos[t] = (x_of[c] + (col_w[c] - box_w[t]) / 2 if r == 0 else x_of[c] + (col_w[c] - box_w[t]) / 2, y_of[r])
W = x_of[2] + col_w[2] + MARGIN
H = y_of[1] + row_h[1] + MARGIN

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.0f} {H:.0f}" '
       f'font-family="Helvetica, Arial, sans-serif" font-size="12.5">',
       '<style>.h{font-size:14px;fill:#222}.t{fill:#555}.n{fill:#111}.k{fill:#1d4ed8}.o{fill:#666}'
       '.l{fill:#444;font-size:12px}.b{fill:#fff;stroke:#8a8a8a}.hd{fill:#ececec;stroke:#8a8a8a}'
       '.s{fill:#f6f6f6}.g{stroke:#d4d4d4}.r{stroke:#555;stroke-width:1.2;fill:none}</style>',
       f'<rect width="{W:.0f}" height="{H:.0f}" fill="#fff"/>']

for t, rows in TABLES.items():
    x, y = pos[t]
    w, h = box_w[t], box_h[t]
    cw = widths[t]
    cw[-1] += w - sum(cw)  # stretch the note column to the box width
    svg.append(f'<rect class="b" x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}"/>')
    svg.append(f'<rect class="hd" x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{HEAD}"/>')
    svg.append(f'<text class="h" x="{x + w / 2:.1f}" y="{y + 20:.1f}" text-anchor="middle">{t}</text>')
    for i, row in enumerate(rows):
        ry = y + HEAD + i * ROW
        if i % 2:
            svg.append(f'<rect class="s" x="{x + 0.5:.1f}" y="{ry:.1f}" width="{w - 1:.1f}" height="{ROW}"/>')
        if i:
            svg.append(f'<line class="g" x1="{x:.1f}" y1="{ry:.1f}" x2="{x + w:.1f}" y2="{ry:.1f}"/>')
        cx = x
        for j, (val, cls) in enumerate(zip(row, ["t", "n", "k", "o"])):
            if val:
                svg.append(f'<text class="{cls}" x="{cx + PAD:.1f}" y="{ry + 16:.1f}">{escape(val)}</text>')
            cx += cw[j]

# relationships: (parent, child, parent end, child end, label)
#   one = exactly one (||), many0 = zero or many (o<), many1 = one or many (|<), one0 = zero or one (o|)
RELS = [
    ("countries", "customers", "one", "many0", "is home of"),
    ("customers", "invoices", "one", "many0", "places"),
    ("invoices", "invoice_lines", "one", "many1", "contains"),
    ("products", "invoice_lines", "one", "many0", "is sold on"),
    ("products", "inventory", "one", "one0", "is stocked as"),
]


def marker(px, py, dx, dy, kind):
    """draw the crow's foot end at (px, py) on the box edge; (dx, dy) points away from the box."""
    nx, ny = -dy, dx  # perpendicular
    out = []
    tick = lambda d: out.append(
        f'<line class="r" x1="{px + dx * d + nx * 7:.1f}" y1="{py + dy * d + ny * 7:.1f}" '
        f'x2="{px + dx * d - nx * 7:.1f}" y2="{py + dy * d - ny * 7:.1f}"/>')
    circle = lambda d: out.append(
        f'<circle cx="{px + dx * d:.1f}" cy="{py + dy * d:.1f}" r="5" fill="#fff" stroke="#555" stroke-width="1.2"/>')

    def foot():
        tip_x, tip_y = px + dx * 14, py + dy * 14
        for s in (-8, 0, 8):
            out.append(f'<line class="r" x1="{tip_x:.1f}" y1="{tip_y:.1f}" x2="{px + nx * s:.1f}" y2="{py + ny * s:.1f}"/>')

    if kind == "one":
        tick(10); tick(16)
    elif kind == "one0":
        tick(10); circle(21)
    elif kind == "many1":
        foot(); tick(20)
    elif kind == "many0":
        foot(); circle(25)
    return out


for parent, child, pend, cend, text in RELS:
    (px, py), (cx_, cy_) = pos[parent], pos[child]
    pw, ph, cw_, ch = box_w[parent], box_h[parent], box_w[child], box_h[child]
    if abs(py - cy_) < 1:  # same row: horizontal line between facing edges
        y = py + HEAD + ROW * 0.5 + 2
        if px < cx_:
            a, b, da, db = (px + pw, y), (cx_, y), (1, 0), (-1, 0)
        else:
            a, b, da, db = (px, y), (cx_ + cw_, y), (-1, 0), (1, 0)
        lx, ly = (a[0] + b[0]) / 2, y - 7
        anchor = "middle"
    else:  # same column: vertical line
        x = px + pw / 2
        a, b, da, db = (x, py + ph), (x, cy_), (0, 1), (0, -1)
        lx, ly, anchor = x + 10, (a[1] + b[1]) / 2 + 4, "start"
    svg.append(f'<line class="r" x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}"/>')
    svg += marker(a[0], a[1], da[0], da[1], pend)
    svg += marker(b[0], b[1], db[0], db[1], cend)
    svg.append(f'<text class="l" x="{lx:.1f}" y="{ly:.1f}" text-anchor="{anchor}">{text}</text>')

svg.append(f'<text class="o" x="{MARGIN}" y="{MARGIN + 2}" font-size="12">kodes_retail · crow\'s foot erd · '
           f'PK primary key, FK foreign key, UK unique</text>')
svg.append("</svg>")
svg = [re.sub(r'(\d)\.0(?=\D)', r'\1', part) for part in svg]  # 42.0 -> 42
(OUT / "erd.svg").write_text("".join(svg))
print(f"docs/erd.svg written ({len(''.join(svg)):,} bytes, {W:.0f} x {H:.0f})")

try:
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": int(W), "height": int(H)}, device_scale_factor=2)
        pg.set_content(f'<html><body style="margin:0">{"".join(svg)}</body></html>')
        pg.locator("svg").screenshot(path=str(OUT / "erd.png"), animations="disabled", timeout=20000)
        b.close()
    print("docs/erd.png written")
except Exception as e:  # playwright is optional
    print("png skipped:", e)
