# Engine release notes

## T2: schema 22 and derived Brain reads

Schema 22 uses integer storage identities while preserving public identifiers. It freezes the
historical Brain naming projection and stores observations, capabilities, verification and
Recall records in their dedicated relations. New observations do not mutate that frozen
projection. A schema 22 archive cannot be opened for writing by an older engine.

The app may migrate a recognized earlier archive automatically. CLI producers require an
explicit `memory --migrate`; read-only inspection never migrates. Migration requires enough
free space, exclusive archive access and no open person episode. It checks person admission
again before publication. The source stays read-only during conversion, including its WAL.
The converted file is checked before a durable exchange retains the earlier archive family.
A completed exchange record is retained under a unique name when its slot is reused.

`memory --rollback <retained-copy-name>` restores a recognized earlier archive and retains the
schema 22 family, including later writes. It does not merge later writes into the earlier
schema. An interrupted exchange must be recovered as an exchange; corruption recovery does
not inspect or replace its live archive. Copy families named by schema 22 migration and rollback records stay beside the archive;
ordinary backup rotation cannot retire them. Keep each family until its contents have been reviewed. Migration and rollback must first be verified on SQLite backup copies.

Exact supplied schema 20 and 21 shapes are recognized. Commands in both become registered
capabilities with their candidate and ordered route-step links. Facts from schema 21 remain
in the retained source; this engine does not import or use those facts. Unknown shapes and command
identifiers that cannot be converted are refused without publishing a partial destination.
Real-archive timings, space use and older-binary refusal are recorded separately from unit tests.

Frozen naming snapshots and their indexes share one process-wide cache. The provisional
retention budget is 8 MiB of estimated storage, not a measured process memory limit. Store
incarnations prevent reuse after close or replacement, even at the same path. Readers may
retain evicted snapshots; their estimated bytes are reported separately.

A stopped derived read cooperates during SQL decoding, index construction, byte accounting
and matching, and checks again before cache publication. Abandoned scenes are discarded at
the read boundary. This control does not cancel a gesture already sent or discard essential
recorded facts. Real takeover latency and residual CPU/SQL time still need dedicated measures;
the scheduler connection belongs to T3.

The real-copy schema 22 space gate is not met: the 1,020-action reference produced
18,055,168 bytes (17,701 bytes per action), above the approved 10,000-byte limit.
Tommaso approved a temporary exception for T2 on 2026-11-03. The space target remains
unmet; the threshold and DDL are unchanged. Integrity, retained data and rollback checks
remain required, and performance and live acceptance are recorded separately.
