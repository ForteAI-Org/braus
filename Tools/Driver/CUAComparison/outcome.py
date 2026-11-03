"""Readers for the closed action outcome row vocabulary."""


def fields(row):
    if not isinstance(row, str):
        return None
    parts = row.split(" · ")
    if len(parts) != 3 or parts[0] not in {"sent", "not_sent", "uncertain"}:
        return None
    effects = {"confirmed", "absent", "not_applicable"} | {
        f"unknown({reason})" for reason in ("still_changing", "not_watched", "not_classified", "not_readable")
    }
    recoveries = {"continue", "observe", "do_not_repeat", "ask_person", "retry"} | {
        f"change_target({reason})" for reason in ("not_found", "ambiguous", "unreachable", "disabled", "destructive")
    }
    return tuple(parts) if parts[1] in effects and parts[2] in recoveries else None


def legacy_kind(row):
    parsed = fields(row)
    if parsed is None:
        return row
    gesture, effect, recovery = parsed
    if gesture != "not_sent":
        return "found_acted" if effect == "confirmed" or recovery == "continue" else "acted_unverified"
    if recovery == "change_target(not_found)":
        return "honest_miss"
    if recovery == "change_target(ambiguous)":
        return "ambiguous"
    return "acted_noop" if recovery == "continue" else "refused"


def is_failure(row):
    parsed = fields(row)
    if parsed is None:
        return False
    gesture, effect, recovery = parsed
    return effect == "absent" or (gesture == "not_sent" and (
        recovery.startswith("change_target(") or recovery == "ask_person"))
