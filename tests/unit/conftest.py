"""Shared helpers for testing the Kestra flow YAML files in this repo.

These are static structural/policy checks over flows/**/*.yml, not real flow
execution — that would need a live Kestra server (or Enterprise Edition's
YAML-based Unit Tests feature, which this OSS deployment doesn't have).
"""
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
FLOWS_DIR = REPO_ROOT / "flows"


def discover_flow_paths():
    """All flow YAML files under flows/, sorted for stable test ordering/ids."""
    return sorted(FLOWS_DIR.rglob("*.yml"))


def load_flow(path):
    with path.open() as f:
        return yaml.safe_load(f)


def walk(node):
    """Yield every dict found anywhere in a nested flow structure - tasks, nested
    ForEach/EachX tasks, error handlers, etc."""
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


def find_tasks_of_type(flow, task_type):
    """Yield every task dict of a given `type` found anywhere in the flow."""
    for node in walk(flow):
        if node.get("type") == task_type:
            yield node


def iter_strings(node):
    """Yield every string found anywhere in a nested structure - dict values,
    list items, and the node itself if it's already a leaf string."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            yield from iter_strings(value)
    elif isinstance(node, list):
        for item in node:
            yield from iter_strings(item)


@pytest.fixture(
    params=discover_flow_paths(),
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def flow_path(request):
    return request.param


@pytest.fixture
def flow(flow_path):
    return load_flow(flow_path)
