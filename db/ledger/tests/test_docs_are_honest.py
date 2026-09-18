"""The documentation is checked, not trusted.

README.md claims that every statement in it corresponds to a test that would
fail if the statement were false. That is a claim about a markdown file, and
markdown files rot. These tests make the rot fail the build instead.
"""

from __future__ import annotations

import pathlib
import re

import pytest

DOCS = pathlib.Path(__file__).resolve().parents[1]
TESTS = pathlib.Path(__file__).resolve().parent

TEST_NAME = re.compile(r"`(test_[a-z0-9_]+)`")
REASON_CODE = re.compile(r"`([A-Z][A-Z_]{4,})`")


def _defined_tests() -> set[str]:
    names: set[str] = set()
    for path in TESTS.glob("test_*.py"):
        names |= set(re.findall(r"^def (test_[a-z0-9_]+)", path.read_text(), re.MULTILINE))
    return names


@pytest.mark.parametrize("doc", ["README.md", "HANDOFF-for-kotlin.md", "FINDINGS.md"])
def test_every_test_named_in_the_docs_exists(doc: str):
    """A renamed or deleted test must not leave a dangling citation behind."""
    path = DOCS / doc
    if not path.exists():
        pytest.skip(f"{doc} not present")
    cited = set(TEST_NAME.findall(path.read_text()))
    missing = sorted(cited - _defined_tests())
    assert missing == [], f"{doc} cites tests that do not exist: {missing}"


def test_the_readme_cites_a_test_for_every_invariant():
    """Each of the six invariants must be backed by at least one named test."""
    readme = (DOCS / "README.md").read_text()
    for heading in ("Balanced at COMMIT", "One currency per transaction",
                    "Entries are immutable", "No negative balances",
                    "The cache equals the truth", "Idempotent posting"):
        start = readme.index(heading)
        end = readme.find("\n### ", start)
        section = readme[start:end if end != -1 else len(readme)]
        assert TEST_NAME.findall(section), f"invariant '{heading}' cites no test"


def test_every_error_code_the_schema_raises_is_documented():
    """A reason code the service cannot look up is a reason code it will
    mishandle, so the handoff table has to stay complete."""
    schema = (DOCS / "schema.sql").read_text()
    raised = set(re.findall(r"ledger_raise\(\s*'([A-Z_]+)'", schema))
    documented = set(REASON_CODE.findall((DOCS / "HANDOFF-for-kotlin.md").read_text()))
    missing = sorted(raised - documented)
    assert missing == [], f"raised by schema.sql but absent from HANDOFF: {missing}"


def test_the_handoff_does_not_document_codes_that_no_longer_exist():
    schema = (DOCS / "schema.sql").read_text()
    raised = set(re.findall(r"ledger_raise\(\s*'([A-Z_]+)'", schema))
    handoff = (DOCS / "HANDOFF-for-kotlin.md").read_text()
    # Only the rows of the error table, which are the ones making a promise.
    table_codes = set(re.findall(r"^\| `([A-Z_]+)`", handoff, re.MULTILINE))
    table_codes |= set(re.findall(r"^\| `([A-Z_]+)` / `([A-Z_]+)`", handoff, re.MULTILINE)
                       and [c for pair in re.findall(r"^\| `([A-Z_]+)` / `([A-Z_]+)`",
                                                     handoff, re.MULTILINE) for c in pair])
    stale = sorted(table_codes - raised)
    assert stale == [], f"documented in HANDOFF but never raised: {stale}"
