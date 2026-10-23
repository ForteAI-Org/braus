# Raw native control facts

`NativeControlFacts` preserves diagnostics from one accessibility harvest without
interpreting a toggle state. Its typed attribute results distinguish an empty
CFString, CFBoolean false, CFNumber zero, no value, unsupported attribute,
exhausted messaging timeout, successful reply with no payload, other error and
an attribute never read. Other CF payloads retain their type ID without exposing
their contents.

The harvested control keeps the raw role, subrole, AXValue and AXSelected.
The node's reported owner process is separate from the capture owner.
Only non-editable button/check/radio/menu/popup controls receive these extra
facts. Text fields, text areas, combo editors and secure fields gain no second
raw-value channel.

A live augmenter supplies a new observation UUID and the requested process,
window number and frame. A window number is present only when the existing
capture-to-native-window resolver attested it. Geometry-only reads explicitly
carry no attested recipient. The pure harvester accepts provenance from its
caller and never invents it. Pixel merging preserves the facts of the matched
native widget. It does not create raw facts for a pixel-only widget.

Scene JSON and readable text carry these facts as `nativeFacts` and
`native-raw`. String representations escape whitespace, so a raw value cannot
create a second scene row. Semantic raw diagnostics and their capture target affect scene equality and the token.
Only the per-read observation UUID is excluded, so identical evidence in a new read
does not invalidate an otherwise unchanged scene. Display strings are capped at 64
Unicode scalars with an explicit truncation count; JSON retains the complete raw values. Retained and decoded facts remain historical diagnostics;
their serialization does not make them fresh.

`belongs(to:)` checks the complete observation scope, requires an
attested window number and requires the native node owner to match the capture owner. It is not a state interpreter, action capability or
verification. An observation is not atomic: attributes are read sequentially,
and another application action may occur between reads. Existing walk and
per-message budgets remain in force. The reader checks the walk deadline before
every raw attribute and before a retry, marking attributes not read after expiry.
One in-flight attribute can exceed the deadline by its messaging timeout; it cannot
start the remaining raw reads after that deadline. No latency claim is made.

## State qualification boundary

No new state adapter or automatic state rule is installed by this change.
`NativeButtonState`, the standard numeric check/radio path, action scope,
readback guards and the unknown-state `set_toggle` refusal retain their contracts.
AXToggle, AXPress, Selected text, an empty string and AXSelected=false do not
constitute a generic on/off capability. In particular, raw facts alone do not
make Layered Editing executable through `set_toggle`.

A future state interpreter must be an explicit adapter supplied at composition.
Its result must identify the current observation and target, the provider and
version scope, an independently qualified encoding, its evidence and the
interpreted on/off/mixed/unknown/conflict result. A match of the raw observation
alone supplies none of that evidence. A rule outside its provider, version,
window, owner or element scope must answer unknown. A cached prior interpretation
cannot supply current state. Post-action success additionally needs fresh
readback of the same target; an uncertain gesture is not retried.

Recorded empty/Selected/empty values with a false AXSelected flag motivate these
distinctions. They do not establish that every AXToggle shares that encoding.
Add Marker, Task Manager and ordinary buttons remain negative examples for any
unqualified general interpretation. This patch does not introduce application
or label whitelists.

## Verification

Controlled tests exercise native scalar decoding, unsuccessful read statuses,
negative selected flags, empty versus missing strings, raw facts without state,
widget identity during merge, provenance changes, legacy scene decoding and
escaped rendering. They do not replace live inspection of the new reader path
or demonstrate application-level toggle behavior. Root coordinates any host/live
qualification after independent review.
