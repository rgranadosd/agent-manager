# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

"""
Unit tests for TraceFetcher pagination and sample_traces.
"""

from typing import List
from unittest.mock import patch, MagicMock

import pytest

from amp_evaluation.trace.fetcher import TraceFetcher, sample_traces


def _raw_trace(trace_id: str, start_time: str) -> dict:
    return {
        "traceId": trace_id,
        "rootSpanId": f"{trace_id}-root",
        "rootSpanName": "root",
        "startTime": start_time,
        "endTime": start_time,
        "spans": [],
    }


def _make_fetcher() -> TraceFetcher:
    return TraceFetcher(
        base_url="http://localhost:8001",
        organization="org",
        project="proj",
        agent="agent",
        environment="dev",
        token_provider=lambda: "test-token",
    )


def _mock_response(traces: List[dict], total_count: int) -> MagicMock:
    resp = MagicMock()
    resp.raise_for_status.return_value = None
    resp.json.return_value = {"traces": traces, "totalCount": total_count, "truncated": False}
    return resp


class TestFetchTracesPagination:
    def test_paginates_across_multiple_pages(self):
        fetcher = _make_fetcher()

        page1 = [_raw_trace(f"t{i}", f"2026-01-01T00:00:{i:02d}Z") for i in range(0, 50)]
        page2 = [_raw_trace(f"t{i}", f"2026-01-01T00:01:{i - 50:02d}Z") for i in range(50, 100)]
        page3 = [_raw_trace(f"t{i}", f"2026-01-01T00:02:{i - 100:02d}Z") for i in range(100, 125)]

        responses = [
            _mock_response(page1, total_count=125),
            _mock_response(page2, total_count=125),
            _mock_response(page3, total_count=125),
        ]

        with patch("requests.get", side_effect=responses) as mock_get:
            result = list(
                fetcher.fetch_traces(start_time="2026-01-01T00:00:00Z", end_time="2026-01-01T01:00:00Z", page_size=50)
            )

        assert [t.traceId for t in result] == [f"t{i}" for i in range(125)]
        assert mock_get.call_count == 3
        # last call advanced the cursor to the last trace's startTime of the prior page
        assert mock_get.call_args_list[1].kwargs["params"]["startTime"] == page1[-1]["startTime"]
        assert mock_get.call_args_list[2].kwargs["params"]["startTime"] == page2[-1]["startTime"]

    def test_stops_when_page_smaller_than_page_size(self):
        fetcher = _make_fetcher()
        page = [_raw_trace("t0", "2026-01-01T00:00:00Z")]

        with patch("requests.get", return_value=_mock_response(page, total_count=1)) as mock_get:
            result = list(fetcher.fetch_traces(start_time="s", end_time="e", page_size=50))

        assert [t.traceId for t in result] == ["t0"]
        assert mock_get.call_count == 1

    def test_dedupes_traces_tied_at_page_boundary(self):
        """If multiple traces share the exact boundary startTime, the next page's
        re-query (from that same startTime) may re-return them. They must not be
        yielded twice, and a page that returns nothing new must stop iteration."""
        fetcher = _make_fetcher()

        tie_time = "2026-01-01T00:00:00Z"
        page1 = [_raw_trace("t0", tie_time), _raw_trace("t1", tie_time)]
        # Re-querying from tie_time returns the same two traces again (no new ones).
        page2 = [_raw_trace("t0", tie_time), _raw_trace("t1", tie_time)]

        with patch("requests.get", side_effect=[_mock_response(page1, 2), _mock_response(page2, 2)]) as mock_get:
            result = list(fetcher.fetch_traces(start_time="s", end_time="e", page_size=2))

        assert [t.traceId for t in result] == ["t0", "t1"]
        assert mock_get.call_count == 2

    def test_max_traces_stops_early(self):
        fetcher = _make_fetcher()
        page = [_raw_trace(f"t{i}", f"2026-01-01T00:00:{i:02d}Z") for i in range(10)]

        with patch("requests.get", return_value=_mock_response(page, total_count=10)):
            result = list(fetcher.fetch_traces(start_time="s", end_time="e", page_size=10, max_traces=3))

        assert [t.traceId for t in result] == ["t0", "t1", "t2"]

    def test_empty_page_stops_iteration(self):
        fetcher = _make_fetcher()

        with patch("requests.get", return_value=_mock_response([], total_count=0)) as mock_get:
            result = list(fetcher.fetch_traces(start_time="s", end_time="e"))

        assert result == []
        assert mock_get.call_count == 1

    def test_constructor_page_size_used_when_not_overridden(self):
        fetcher = TraceFetcher(
            base_url="http://localhost:8001",
            organization="org",
            project="proj",
            agent="agent",
            environment="dev",
            token_provider=lambda: "test-token",
            page_size=25,
        )
        page = [_raw_trace("t0", "2026-01-01T00:00:00Z")]

        with patch("requests.get", return_value=_mock_response(page, total_count=1)) as mock_get:
            list(fetcher.fetch_traces(start_time="s", end_time="e"))

        assert mock_get.call_args.kwargs["params"]["limit"] == "25"

    def test_per_call_page_size_overrides_constructor_default(self):
        fetcher = TraceFetcher(
            base_url="http://localhost:8001",
            organization="org",
            project="proj",
            agent="agent",
            environment="dev",
            token_provider=lambda: "test-token",
            page_size=25,
        )
        page = [_raw_trace("t0", "2026-01-01T00:00:00Z")]

        with patch("requests.get", return_value=_mock_response(page, total_count=1)) as mock_get:
            list(fetcher.fetch_traces(start_time="s", end_time="e", page_size=5))

        assert mock_get.call_args.kwargs["params"]["limit"] == "5"

    def test_default_page_size_is_small(self):
        """The constructor default must stay memory-bound, not the API's 1000 max."""
        fetcher = _make_fetcher()
        assert fetcher.page_size == 10


class TestSampleTraces:
    def test_deterministic_across_runs(self):
        traces = [MagicMock(traceId=f"trace-{i}") for i in range(500)]

        first = [t.traceId for t in sample_traces(traces, sample_rate=0.3)]
        second = [t.traceId for t in sample_traces(traces, sample_rate=0.3)]

        assert first == second
        assert len(first) > 0

    def test_approximate_rate_over_large_set(self):
        traces = [MagicMock(traceId=f"trace-{i}") for i in range(5000)]

        kept = list(sample_traces(traces, sample_rate=0.2))

        ratio = len(kept) / len(traces)
        assert 0.15 < ratio < 0.25

    def test_sample_rate_one_keeps_everything(self):
        traces = [MagicMock(traceId=f"trace-{i}") for i in range(20)]
        assert list(sample_traces(traces, sample_rate=1.0)) == traces

    def test_invalid_sample_rate_raises(self):
        with pytest.raises(ValueError):
            list(sample_traces([], sample_rate=0))
        with pytest.raises(ValueError):
            list(sample_traces([], sample_rate=1.5))
