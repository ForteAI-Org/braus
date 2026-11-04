SC0 is incomplete: the reviewed neutral delivery has not arrived.
This directory contains no accepted recorded scenes or invented substitutes.

The explicitly approved replacement corpus has eight primary app families and
two additional native accessibility examples. It replaces the unavailable
historical corpus; it is not a reconstruction of missing historical snapshots.

Before importing, validate the ten neutral snapshots, their recorded text,
call identities, SHA-256 hashes, source and renderer revisions, coverage, and
anonymization review against SC0 section 3. A renderer before SC1/EE6 requires
a new replay and attestation. Keep private prohibited values outside this tree.

The delivery must include manifest.json, corpus-declaration.json and
instance-checks.json. The declaration is registered before the new inputs are
entered. All 25 neutral inputs and five file roots require positive, hash-bound
observations in their declared cases. At least one task input must occur in the
same primary observation that has genuinely applied, nonempty window knowledge.
Do not count the absence of data as a successful instance check.

SceneTextDelivery validates metadata, hashes, source identity, native-origin
receipts, coverage and payload-bound privacy and expected-text reviews.
The privacy review also binds a SHA-256 digest of the raw captures array,
serialized as sorted-key JSON without escaped slashes. Changing a capture's
call identity, timestamp, quality or source metadata requires a new review.
This is an integrity check, not authentication of desktop origin or reviewers.
Its temporary synthetic validation tests do not approve a real delivery.

GoldenScene loads only files that pass that validation. Each scene needs
<name>.scene.json, <name>.v1.txt and <name>.v2.txt. Preserve recorded v1 bytes;
write v2 manually from the future design and leave it for Tommaso's review.
The v2 file is not generated from the current safe-cut renderer. Current safe
cuts and the future design have separate checks.

Missing delivery is a test failure, never a known issue or an empty corpus.
The future-format, budget and instance ratchets must be completed after inspecting the actual
scenes and metadata, with known issues only for individually confirmed failures.
Privacy review and three structured replay cases also remain pending. A
controlled partial-read fault is distinct from a naturally incomplete capture
and from the ten complete primary/supplemental observations.
The v1 and final read-only section checks need the reviewed delivery to run.
Do not change the existing replay exceptions.
