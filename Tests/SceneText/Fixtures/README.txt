SC0 is incomplete: the required neutral delivery has not arrived.
This directory intentionally contains no recorded scenes or invented substitutes.

Before importing, validate the eight neutral snapshots, their recorded text,
call identities, SHA-256 hashes, source and renderer revisions, coverage, and
anonymization review against SC0 section 3. A renderer before SC1/EE6 requires
a new replay and attestation. Keep private prohibited values outside this tree.

The delivery must include manifest.json and instance-checks.json with the
25 neutral inputs, five neutral roots, case associations and neutral checks.
The supplied metadata schema and hash validation remain to be connected when
the delivery arrives; no metadata schema is presumed here.

GoldenScene loads only files imported after that validation. Each scene needs
<name>.scene.json, <name>.v1.txt and <name>.v2.txt. Preserve recorded v1 bytes;
write v2 from the design and leave it for Tommaso's review.

Missing delivery is a test failure, never a known issue or an empty corpus.
The v2, budget and instance ratchets must be added after inspecting the actual
scenes and metadata, with known issues only for individually confirmed failures.
Anonymity checks and three structured replay cases also remain pending.
The v1 and final read-only section checks need the real delivery to run.
Do not change the existing replay exceptions.
