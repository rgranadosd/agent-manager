from harness.triage import build_diff_markdown


def test_diff_shows_missing_required_attribute():
    report = {
        "cellId": "x",
        "category": "schema-violation",
        "violations": [
            {
                "spanName": "openai.chat",
                "kind": "llm",
                "rule": "schema",
                "path": "/attributes/gen_ai.system",
                "message": "'gen_ai.system' is a required property",
            }
        ],
        "capturedSpansAttributes": [{"gen_ai.request.model": "gpt-4o-mini"}],
    }
    md = build_diff_markdown(
        report, schema_required=["gen_ai.system", "gen_ai.request.model"]
    )
    assert "gen_ai.system" in md
    assert "MISSING" in md


def test_diff_marks_all_required_present_when_attrs_cover_them():
    report = {
        "cellId": "y",
        "category": "schema-violation",
        "violations": [],
        "capturedSpansAttributes": [
            {"gen_ai.system": "openai", "gen_ai.request.model": "gpt-4o-mini"}
        ],
    }
    md = build_diff_markdown(
        report, schema_required=["gen_ai.system", "gen_ai.request.model"]
    )
    assert "MISSING" not in md
