"""Per-cell triage Markdown: schema-required vs captured attribute keys.

Output goes to ``reports/diffs/<cell-id>.diff.md`` and is the workhorse page
during a red run — a reader should reach a verdict on a failure without
reproducing locally. A richer per-kind diff (expected schema slice vs captured
span attribute map) is deferred to follow-up; today's page covers the
high-signal "what's missing" axis.
"""
from __future__ import annotations


def build_diff_markdown(report: dict, *, schema_required: list[str]) -> str:
    lines = [
        f"# Triage — {report['cellId']}",
        "",
        f"**Category:** {report.get('category', '-') or '-'}",
        "",
    ]

    if report.get("violations"):
        lines += ["## Violations", ""]
        for v in report["violations"]:
            lines.append(
                f"- `{v['path']}` — {v['message']} (span `{v['spanName']}`)"
            )
        lines.append("")

    captured = report.get("capturedSpansAttributes") or []
    captured_keys = {k for attrs in captured for k in attrs.keys()}

    lines += [
        "## Required attributes vs captured",
        "",
        "| Required key | Status |",
        "|---|---|",
    ]
    for key in schema_required:
        if key in captured_keys:
            lines.append(f"| `{key}` | present |")
        else:
            lines.append(f"| `{key}` | **MISSING** |")
    return "\n".join(lines)
