These are manually authored, neutral v1 cases, not a real-run corpus.
Answers and goldens were recorded through production code at
93495efd3609cf729f747ad48cbacd9a1761303e, with no production changes.
The real corpus is pending an aligned neutral export.

The fifteen action goldens use ResultFormatter.outcome, including each prefix
on one fresh formatter. JSON uses sorted keys, UTF-8 and no final newline.
batch-01 was recorded through AutomationTools.call with a local session and
is report-only here. Full dispatcher regeneration belongs to the TU3 tests.
The Seat refusal and uncertain delivery are synthetic outcomes, not live tests.

The exception list contains an observation request in delivery-01 and a chain
of depth three in sequence-4, in both recorded and regenerated reports.
Unchanged deliveries still extend a chain. Saved character totals count only
the scene or changes text, including every delivery in the prefix.

For SC1 or SG2 corrections, preserve the previous goldens and their SHA-256
hashes with the base revision under history/<increment>/ before replacing
only the prescribed active delta. Do not rewrite answer, savedText or historical
totals to accommodate a correction. Active loaders read cases/ and golden/
only; history is never an active reference. Remove resolved exceptions.

Current model delivery is regenerated through ResultFormatter.finish and pinned in
`golden/current-delivery/`. The original `golden/*.txt`, recorded answers and scene
totals above remain historical evidence. Set BRAUS_RECORD_REPLAY_GOLDENS=1 only
when intentionally recording and reviewing a changed current contract; rerun
without it to verify. Current tagged outcomes retain synchronized structured
content; producer diagnostic prose stays out of the model-facing message.
The bounded scene policy removes the regenerated sequence-4 depth exception;
the historical depth exception remains. The original scene-size threshold is
unchanged. Header text omits anchor/last labels while keeping revision/since;
the base and dependencies remain typed policy facts.
