# Complete titles for flat dropdown selection

Flat dropdown selection must keep the complete requested item through observed
menu resolution, native or remote choice, keyboard planning and final readback.
The generic scene core key removes short leading tokens and punctuation; it is
not an item identity. For example, `J 1/8 note` and `1/4 note` both reduced to
`note`, allowing a sole wrong duration to resolve.

`LabelText.exactMenuItemMatch` compares complete semantic menu titles using the
existing case, bidi, typographic-quote and trailing-ellipsis contract. It preserves
numbers, fractions, single dots, triplets, J/v letters and musical symbols.
Two titles that compare alike remain ambiguous. It does not strip decoration
without provenance: `J 1/8 note` cannot be chosen as `1/8 note` merely because J
might have been an OCR glyph.

`SeatDropdownSelector` uses this contract for its attested menu scene and opts
into exact titles for native AX choice, remote menu choice, keyboard plans and
readback. A title prefix cannot stand for a longer duration. A disabled observed
item refuses. Keyboard plans require unique current and target rows; a known disabled row in
native or pixel rows refuses an unqualified arrow count. Native
listings that are ambiguous or contain disabled rows cannot fall back to a
partial pixel listing to manufacture an arrow count. Pixel planning is used only
when no native rows were supplied. A direct enabled native item can still be
pressed without a keyboard plan.

General context-menu commands retain their documented unique-prefix contract,
such as Compress followed by a generated filename. Those callers do not gain
permission to use prefix matching for flat value selection. No popup gesture,
window ownership or irreversible-action guard is relaxed.

Verification still reads the requested value at the original control's position,
in the same captured recipient. Exact readback requires a unique matching native
control when present; contradictory native values cannot be overridden by OCR.
Pixel-only readback requires a unique nearby candidate. A different duration whose punctuation formerly
normalized away cannot verify success. A menu closing or an Undo label is still
not evidence of a document-content edit. Canvas/timeline edits need their own
before/after content observation; this patch adds no document-domain oracle.

Controlled regressions cover the wrong-duration counterexample, dots, triplets,
musical symbols, real J/v labels, exact/native/remote matching, duplicates,
disabled keyboard rows and value readback at the original position. Existing
remote-popup tests also cover single, double and triple clicks refusing without
sending an alternate physical gesture. G08's existing direct, sibling-window,
windowless and foreign-owner resolver fixtures remain the qualification boundary;
no speculative resolver patch is added.

## The Seat's native popups: accessibility titles decide

When the Seat opens a popup through its native show-menu action, the item is chosen
by `DropdownOpening.select` with exact titles: one enabled accessibility item must
match the requested title completely. The painted menu is still read and its frame
attested, but its labels no longer gate the choice: Pro Tools paints a checkmark and
note glyphs into the rows ("v J 1/4 note"), which change between readings and kept
every Nudge and Grid duration from being selected (22 October 2026). No prefix,
normalised key or OCR guess is admitted. A title that matches no single enabled item
closes the menu and answers the item titles the menu holds.

Before opening, a popup whose native value already reads the requested item exactly
answers `acted_noop` with the reading as its passed check; nothing is sent.
