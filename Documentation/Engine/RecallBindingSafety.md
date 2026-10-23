# Conservative Recall binding and action classification

This contract covers the B2 changes of 22 October 2026. It changes neither stored
TaskValue rows nor the operational profile. It adds no unit conversion.

## Binding

`RecallBinding` matches complete normalized identities: case, diacritics and
width are folded, and punctuation separates words. Every word is retained at its
full length. Search stemming and content-word overlap remain relevance signals;
they cannot assign a parameter.

A unique exact name binds only when its kind is compatible and its explicit role
agrees with the parameter's explicit role. An absent role does not assert a
conflict. When the name is absent, a unique exact role can bind. Multiple
normalized names or roles are ambiguous with candidate names sorted independently
of input order, including collisions across kinds. An explicit conflicting role
or incompatible kind leaves the parameter missing. Historical observed values
are not an input-value whitelist. Numbers and references do not become names by
being assigned to text parameters. File and folder references retain their
explicit compatibility with reference parameters.

Explicit roles are identity text, not a semantic similarity test. A legitimate
paraphrase can therefore remain unresolved: `output_name` with role `filename of
the exported document` does not bind a parameter whose role is `name of the
exported file`, despite the exact name and the human-readable similarity. This
is a current compatibility limit. A caller supplying a role must reuse the
declared parameter role reported by Recall; it must not rewrite that role into
prose and assume equivalence. The delivered parameter remains `missing`, its
argument keeps the parameter placeholder, and no historical example or producer
feed supplies a replacement value. Resolve the role before carrying out that
step. A separately named export format remains a separate choice.

File components retain derivation provenance in their name and role. An exact
component role can bind the base name, extension or containing folder of a named
file. Another source/destination role cannot bind it; multiple source identities
or matching component roles remain ambiguous.

## Quantities

A nonblank `RecallSource.Parameter.unit` requires evidence that `TaskValue` does
not currently carry. Such a parameter remains missing even if its name, role or
number agrees. A role saying "milliseconds" is free text, not unit evidence.
The selector also prevents historical producer feeds from supplying an untyped
task output around that guard. Delivered parameters include the required `unit`
and a `unit_unresolved` condition explaining the missing evidence.

A nil or blank required unit retains the unitless kind contract. Existing data
is not backfilled with units. Seconds/milliseconds, frames/sample rates,
percent/fraction and currency denominations need a separate typed quantity and
conversion contract before automatic binding can resume. A missing quantity is
not proof that two quantities differ, and no scaling is attempted.

## Action classification

`ActionPolicy` checks complete words, command phrases, English inflections and
Italian stems at token starts. Internal substrings such as "Information" and
"Payload" do not identify commands. Commands such as Format Disk, Send message,
Publish, Buy, Pay, Invia and Elimina retain their guard.

Opening a native `AXPopUpButton` through `select`, with a whole format
configuration label, is classified separately from invoking its label as a
command. `SeatDropdownSelector` uses this operation-specific contract for its
opener. Its selected item retains an independent policy check. A button, unknown
role, arbitrary popup label or ordinary click cannot acquire that exemption.
A whole payment/purchase/order history label identifies navigation only on a
native link or tab. A button or menu item with the same label remains guarded.
These are application-independent rules; no application whitelist was added.

`IrreversiblePolicy` still requires both consent and a verifier of the final
effect. Opening a selector never grants consent or supplies that verifier.

## Qualified limits

G06: popup gestures in `RemoteContentActuator` still refuse before a double-click
can be substituted. The current code intentionally separates ordinary/native
and remote surfaces; no measured alternate rename capability was supplied.
Existing row-double-click and popup-refusal fixtures qualify those contracts,
not arbitrary popup renaming on the desktop.

G07: the historical menu labels `J 1/8 note` and `v J 1/8 note` do not identify
which characters came from OCR, native text or a checked-state decoration.
Removing J/v or musical symbols globally would erase possible semantic labels.
No such normalization was added. A closed menu or an Undo label remains
insufficient evidence of a document-content edit; domain readback and live
before/after captures are still required.

G08: `DialogEndpointResolver` already starts at the hit test, walks parents and
falls back to an attested window subtree only after a qualified sibling-window
result. Existing direct/sibling/windowless and foreign-owner fixtures cover those
contracts. No current localized failure justifies broadening that search.

## Verification

New controlled regressions cover identity collisions in both orders, conflicting
roles, rejected lexical guesses, unseen names, file-component provenance,
number/reference-to-text refusal, required units, selector producer-feed bypass,
unit delivery, lexical false positives and final destructive commands. They do
not claim live application, provider or document-edit coverage. Validation
commands and results are recorded in the dedicated B2 handoff after independent
review; previous G01/G02 test results do not validate these changes.
