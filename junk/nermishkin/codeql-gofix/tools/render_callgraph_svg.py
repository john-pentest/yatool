#!/usr/bin/env python3
import csv
import html
import sys
from collections import defaultdict, deque
from pathlib import Path


def wrap_text(text: str, width: int) -> list[str]:
    if not text:
        return [""]
    chunks = []
    current = ""
    for ch in text:
        current += ch
        if ch in "/.(":
            chunks.append(current)
            current = ""
    if current:
        chunks.append(current)

    lines = []
    line = ""
    for chunk in chunks:
        if len(line) + len(chunk) <= width:
            line += chunk
            continue
        if line:
            lines.append(line)
            line = ""
        while len(chunk) > width:
            lines.append(chunk[:width])
            chunk = chunk[width:]
        line = chunk
    if line:
        lines.append(line)
    return lines or [text]


def normalize_callee(expr: str) -> str:
    if expr.startswith("selection of "):
        return expr[len("selection of ") :]
    return expr


def short_label(kind: str, name: str, file_name: str) -> str:
    if kind == "func":
        return f"{Path(file_name).stem}.{name}"
    if kind == "func_ref":
        return name
    return name


def pick_display_name(row: dict) -> str:
    qname = row.get("callee_qname", "")
    base_qname = row.get("base_qname", "")
    expr = row.get("callee_expr", "")
    if qname:
        return qname
    norm = normalize_callee(expr)
    if base_qname and norm:
        return f"{base_qname}.{norm}"
    return norm or expr


def qname_tail(qname: str) -> str:
    if not qname:
        return ""
    tail = qname.rsplit("/", 1)[-1]
    if "." in tail:
        return tail
    return qname.rsplit(".", 1)[-1]


def should_promote_callee_to_function(row: dict) -> bool:
    qname = row.get("callee_qname", "")
    if not qname:
        return False
    if qname in {"len", "cap", "append", "copy", "delete", "make", "new", "panic", "print", "println", "recover", "close", "clear", "complex", "imag", "real", "max", "min"}:
        return False
    return "/" in qname or "." in qname


def short_path(path: str) -> str:
    if not path:
        return ""
    parts = Path(path).parts
    if len(parts) <= 4:
        return path
    return "/".join(parts[-4:])


def fmt_loc(prefix: str, path: str, line: str | int, col: str | int, include_path: bool = True) -> str:
    try:
        line_i = int(line)
    except (TypeError, ValueError):
        line_i = 0
    try:
        col_i = int(col)
    except (TypeError, ValueError):
        col_i = 0
    if not line_i:
        return ""
    if include_path and path:
        return f"{prefix}@{short_path(path)}:{line_i}:{col_i or 1}"
    return f"{prefix}@{line_i}:{col_i or 1}"


def filter_to_main_component(nodes, edges):
    outgoing = defaultdict(list)
    for src, dst in edges:
        outgoing[src].append(dst)

    roots = [
        node_id
        for node_id, data in nodes.items()
        if data["kind"] == "func" and short_label(data["kind"], data["name"], data["file"]) == "main.main"
    ]
    if not roots:
        return nodes, edges

    project_roots = [
        node_id for node_id in roots if nodes[node_id].get("detail", "").startswith("a.yandex-team.ru/")
    ]
    if project_roots:
        roots = project_roots

    reachable = set()
    queue = deque(roots)
    while queue:
        current = queue.popleft()
        if current in reachable:
            continue
        reachable.add(current)
        queue.extend(outgoing.get(current, ()))

    filtered_nodes = {node_id: data for node_id, data in nodes.items() if node_id in reachable}
    filtered_edges = [(src, dst) for src, dst in edges if src in reachable and dst in reachable]
    return filtered_nodes, filtered_edges


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: render_callgraph_svg.py <input.csv> <output.svg>", file=sys.stderr)
        return 2

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])

    edges = []
    edge_set = set()
    nodes = {}
    func_nodes_by_name = defaultdict(set)

    with input_path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        enriched_mode = {"caller_qname", "callee_qname", "base_qname"}.issubset(
            set(reader.fieldnames or [])
        )

    for row in rows:
        caller_file = row["caller_file"]
        caller_name = row["caller_name"]
        caller_qname = row.get("caller_qname", "")

        src = f"func::{caller_qname or caller_file + '::' + caller_name}"
        node = nodes.setdefault(
            src,
            {
                "kind": "func",
                "name": caller_name,
                "file": caller_file,
                "detail": caller_qname,
                "meta": fmt_loc("decl", caller_file, row.get("caller_line", 0), row.get("caller_col", 0)),
            },
        )
        if caller_qname and not node.get("detail"):
            node["detail"] = caller_qname
        if not node.get("meta"):
            node["meta"] = fmt_loc("decl", caller_file, row.get("caller_line", 0), row.get("caller_col", 0))
        func_nodes_by_name[caller_name].add(src)
        if caller_qname:
            func_nodes_by_name[caller_qname].add(src)

        if should_promote_callee_to_function(row):
            callee_qname = row.get("callee_qname", "")
            dst = f"func::{callee_qname}"
            nodes.setdefault(
                dst,
                {
                    "kind": "func_ref",
                    "name": qname_tail(callee_qname),
                    "file": "",
                    "detail": callee_qname,
                    "meta": fmt_loc("call", caller_file, row.get("call_line", 0), row.get("call_col", 0), include_path=True),
                },
            )
            func_nodes_by_name[callee_qname].add(dst)
            func_nodes_by_name[qname_tail(callee_qname)].add(dst)

    for row in rows:
        caller_file = row["caller_file"]
        caller_name = row["caller_name"]
        caller_qname = row.get("caller_qname", "")
        src = f"func::{caller_qname or caller_file + '::' + caller_name}"

        if enriched_mode:
            callee_name = pick_display_name(row)
        else:
            callee_name = normalize_callee(row["callee_expr"])

        matches = sorted(func_nodes_by_name.get(callee_name, set()))
        if len(matches) == 1:
            dst = matches[0]
        else:
            dst = f"expr::{callee_name}"
            nodes.setdefault(
                dst,
                {
                    "kind": "expr",
                    "name": callee_name,
                    "file": caller_file,
                    "detail": row.get("base_qname", "") or row.get("callee_sig", ""),
                    "meta": fmt_loc("call", caller_file, row.get("call_line", 0), row.get("call_col", 0)),
                },
            )
        if not nodes[src].get("meta"):
            nodes[src]["meta"] = fmt_loc("decl", caller_file, row.get("caller_line", 0), row.get("caller_col", 0))
        if nodes[dst]["kind"] == "expr" and not nodes[dst].get("meta"):
            nodes[dst]["meta"] = fmt_loc("call", caller_file, row.get("call_line", 0), row.get("call_col", 0))
        edge = (src, dst)
        if edge not in edge_set:
            edge_set.add(edge)
            edges.append(edge)

    if not nodes:
        output_path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="120">'
            '<rect width="100%" height="100%" fill="#fbf7ef"/>'
            '<text x="24" y="64" font-family="monospace" font-size="18" fill="#5b4636">'
            "No callgraph edges found"
            "</text></svg>"
        )
        return 0

    nodes, edges = filter_to_main_component(nodes, edges)

    indegree = {node_id: 0 for node_id in nodes}
    outgoing = defaultdict(list)
    for src, dst in edges:
        outgoing[src].append(dst)
        indegree[dst] += 1

    queue = deque(sorted(node_id for node_id, degree in indegree.items() if degree == 0))
    level = {node_id: 0 for node_id in nodes}
    visited = set()
    while queue:
        current = queue.popleft()
        visited.add(current)
        for nxt in outgoing[current]:
            level[nxt] = max(level[nxt], level[current] + 1)
            indegree[nxt] -= 1
            if indegree[nxt] == 0:
                queue.append(nxt)

    for node_id in nodes:
        if node_id not in visited:
            level.setdefault(node_id, 0)

    columns = defaultdict(list)
    for node_id, lvl in level.items():
        columns[lvl].append(node_id)
    for lvl in columns:
        columns[lvl].sort(key=lambda node_id: (nodes[node_id]["file"], nodes[node_id]["name"]))

    box_w = 520
    left = 50
    top = 40
    col_gap = 620
    row_gap = 28
    pad_x = 16
    line_gap = 18
    title_font = 16
    detail_font = 12

    node_layout = {}
    for node_id, data in nodes.items():
        file_tail = Path(data["file"]).name if data["file"] else "unknown"
        title_lines = wrap_text(short_label(data["kind"], data["name"], data["file"]), 46)
        detail_lines = wrap_text(data.get("detail") or file_tail, 62)
        meta_lines = wrap_text(data.get("meta") or "", 62) if data.get("meta") else []
        text_lines = len(title_lines) + len(detail_lines)
        text_lines += len(meta_lines)
        box_h = 18 + title_font + max(0, len(title_lines) - 1) * line_gap + 10
        box_h += detail_font + max(0, len(detail_lines) - 1) * 15 + 14
        if meta_lines:
            box_h += len(meta_lines) * 15 + 4
        node_layout[node_id] = {
            "title_lines": title_lines,
            "detail_lines": detail_lines,
            "meta_lines": meta_lines,
            "box_h": box_h,
        }

    width = left * 2 + (max(columns.keys()) + 1) * box_w + max(columns.keys()) * (col_gap - box_w)
    column_heights = {}
    for lvl, items in columns.items():
        total_height = sum(node_layout[node_id]["box_h"] for node_id in items)
        total_height += max(0, len(items) - 1) * row_gap
        column_heights[lvl] = total_height
    height = max(180, top * 2 + max(column_heights.values()))

    positions = {}
    for lvl, items in sorted(columns.items()):
        y = top
        for node_id in items:
            positions[node_id] = (left + lvl * col_gap, y)
            y += node_layout[node_id]["box_h"] + row_gap

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto" markerUnits="strokeWidth">'
        '<path d="M0,0 L10,3 L0,6 z" fill="#8a3b12"/></marker></defs>',
        '<rect width="100%" height="100%" fill="#fbf7ef"/>',
    ]

    for src, dst in edges:
        sx, sy = positions[src]
        dx, dy = positions[dst]
        y1 = sy + node_layout[src]["box_h"] / 2
        y2 = dy + node_layout[dst]["box_h"] / 2
        x1 = sx + box_w
        x2 = dx
        mid_x = (x1 + x2) / 2
        parts.append(
            '<path d="M {x1} {y1} C {mx} {y1}, {mx} {y2}, {x2} {y2}" '
            'fill="none" stroke="#8a3b12" stroke-width="2.4" marker-end="url(#arrow)"/>'.format(
                x1=x1, y1=y1, mx=mid_x, x2=x2, y2=y2
            )
        )

    for node_id, data in nodes.items():
        x, y = positions[node_id]
        layout = node_layout[node_id]
        file_tail = Path(data["file"]).name if data["file"] else "unknown"
        fill = "#fff8dc" if data["kind"] == "func" else "#f8efe3"
        parts.append(
            f'<rect x="{x}" y="{y}" rx="14" ry="14" width="{box_w}" height="{layout["box_h"]}" '
            f'fill="{fill}" stroke="#5b4636" stroke-width="1.6"/>'
        )
        text_y = y + 24
        for line in layout["title_lines"]:
            parts.append(
                f'<text x="{x + pad_x}" y="{text_y}" font-family="monospace" font-size="{title_font}" fill="#2f241d">'
                f"{html.escape(line)}</text>"
            )
            text_y += line_gap
        text_y += 6
        for line in layout["detail_lines"]:
            parts.append(
                f'<text x="{x + pad_x}" y="{text_y}" font-family="monospace" font-size="{detail_font}" fill="#7a6858">'
                f"{html.escape(line)}</text>"
            )
            text_y += 15
        if layout["meta_lines"]:
            text_y += 4
            for line in layout["meta_lines"]:
                parts.append(
                    f'<text x="{x + pad_x}" y="{text_y}" font-family="monospace" font-size="{detail_font}" fill="#8a3b12">'
                    f"{html.escape(line)}</text>"
                )
                text_y += 15

    parts.append("</svg>")
    output_path.write_text("\n".join(parts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
