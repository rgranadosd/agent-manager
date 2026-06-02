from harness.categorize import FailureCategory


def test_boundary_categories_exist():
    assert FailureCategory.INGEST_REJECTED.value == "ingest-rejected"
    assert FailureCategory.EXPORT_FAILED.value == "export-failed"
    assert FailureCategory.COLLECTOR_NOT_RECEIVED.value == "collector-not-received"
