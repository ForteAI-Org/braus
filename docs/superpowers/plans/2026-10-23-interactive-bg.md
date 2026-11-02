# Human intervention implementation status

The synthetic preview input plan was superseded: the preview is for watching only, and the person
uses the lent application with real input. Current contracts are maintained in
[Human control](../../../Documentation/Engine/InteractiveBackground.md).

Retained foundations:

- The bounded `HumanIntervention` queue and temporary history storage.
- Worker suspension, retained broker leases and explicit End Control.
- Driver human episodes as an agent-command pause, with stale episode abandonment on lease end,
  session close and new lease startup.
- Preview frame presentation, dynamic capture shape and 1080p HEIC history encoding.
- Agent observation, accessibility actuation, dropdown selection and per-Command preparation.

R1 removes synthetic preview input. R2 will attach window lending to
`HumanPreviewControl.begin()` and `finish()`. R3 will record real input and frames into the retained
storage. B3 reconstruction and B4 reviewed handoff are implemented in the current tree; see the human-control
guide for their ordering and verification limits. B5 invalidation remains pending. Controlled tests
do not establish live lending, capture coverage or CLI continuation behavior.
