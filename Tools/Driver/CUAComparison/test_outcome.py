import itertools

import compare
import summarize
from outcome import fields, is_failure, legacy_kind


def test_conversion_table():
    cases = [
        ("sent · confirmed · continue", "found_acted", False),
        ("sent · absent · retry", "acted_unverified", True),
        ("sent · absent · do_not_repeat", "acted_unverified", True),
        ("uncertain · unknown(not_readable) · observe", "acted_unverified", False),
        ("not_sent · confirmed · continue", "acted_noop", False),
        ("not_sent · not_applicable · continue", "acted_noop", False),
        ("not_sent · not_applicable · change_target(not_found)", "honest_miss", True),
        ("not_sent · not_applicable · change_target(ambiguous)", "ambiguous", True),
        ("not_sent · not_applicable · ask_person", "refused", True),
        ("not_sent · not_applicable · retry", "refused", False),
        ("not_sent · not_applicable · observe", "refused", False),
    ]
    for row, kind, failure in cases:
        assert legacy_kind(row) == kind
        assert is_failure(row) == failure
        reply = {"result": {"content": [{"type": "text", "text": row + "\nA bounded message."}]}}
        assert compare.self_verdict(reply) == row
        assert bool(compare.failed(reply)) == failure
        assert summarize.reported_ok({"ok": True, "self_verdict": row}) != failure


def test_unknown_effects_are_not_failures():
    for reason, recovery in itertools.product(
        ["still_changing", "not_watched", "not_classified", "not_readable"],
        ["observe", "do_not_repeat", "continue"],
    ):
        row = f"sent · unknown({reason}) · {recovery}"
        assert fields(row)
        assert not is_failure(row)


def test_invalid_rows_and_legacy_values():
    assert fields("sent · confirmed · invent") is None
    assert fields(None) is None
    assert legacy_kind("found_acted") == "found_acted"
    assert not summarize.reported_ok({"ok": True, "self_verdict": "refused"})
