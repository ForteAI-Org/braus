# SQLiteAmalgamation

SQLite compiled into Braus, so every supported macOS runs the same library and not the system's. The
living memory needs 3.51.3 or later, or the backports 3.44.6 and 3.50.7, for the WAL-reset correction.
Its schema needs 3.44.0 for `group_concat(... ORDER BY ...)`. macOS 27 ships 3.54.0. Earlier releases ship
older libraries, and the store refused to open on them.

## Source

- Release: SQLite 3.54.0, `SQLITE_SOURCE_ID` `2026-10-09 15:46:58 be8d059e9a49089ab2dce5ed26dd87aaf598fdc5fbe0b107c0dd758464bcd5e3`.
- Archive: `https://sqlite.org/2026/sqlite-amalgamation-3540000.zip`, 2,990,479 bytes, SHA3-256
  `7b670a62fdfbd672b75fef004cb703c8a3e87d3a5cc7d675b4a08337004a2d93`, the hash the download page publishes.
- Files taken unchanged: `sqlite3.c` and `sqlite3.h`, the latter in `include/`. `shell.c` and `sqlite3ext.h`
  are left out.
- SQLite is in the public domain: <https://sqlite.org/copyright.html>.

## Options

The options are in `Package.swift`. They reproduce the defaults of the system library that the store was
built and measured against on macOS 27, wherever a default changes SQL or durability:

- recursive triggers on;
- `checkpoint_fullfsync` on;
- WAL truncated to 32 KiB after a checkpoint;
- a cache of 2000 pages;
- Apple's limits on the length of a value and on the number of bound variables.

A debug build compiles this target at `-O2` too (`unsafeFlags`, debug configuration only), because the app the live runs
use is a debug build and SQLite at `-O0` made learning a procedure about a third slower than with the optimized library
(the learning probe of the scale campaign, 13 October 2026: p50 63–83 ms against 43–61 ms over the first 1,500
procedures). The release build keeps the optimization SwiftPM and Xcode give it.

One more Apple default has no compile-time option: persistent WAL. Apple's library keeps `-wal` and `-shm`
after the last close, and its read-only connections never create them. `SQLiteConnection` sets
`SQLITE_FCNTL_PERSIST_WAL` on every connection. `SQLiteMemoryInspection` refuses a WAL archive without its
log files before opening it.

Apple's options this store does not use stay off: FTS, R-tree, sessions, snapshots and its encryption
codec. One known difference is left as it is. Apple's `secure_delete` defaults to `FAST`, which zeroes
deleted content when that costs no extra I/O; here it is off. Nothing in the store relies on it.

The symbols keep their names and default visibility. Hidden visibility does not link, because the build
system pre-links each target. The system `libsqlite3.dylib` that SwiftData and Core Data load in the
app is still separate: frameworks bind to it by its install name. Only `SQLiteMemory` opens the
archive, and it does so only through this library. Two copies of SQLite on one file in one process
would lose each other's POSIX locks.

The app target links with `-Wl,-unexported_symbol,_sqlite3_*` (`Braus.xcodeproj`). Without it,
`Braus.debug.dylib` exports this copy. The app tests that import the SDK's `SQLite3` to open the SwiftData
store would then bind to it instead of to the system library SwiftData uses. `nm -m` on the test bundle
shows those symbols `from libsqlite3`.

## Updating

1. Download the new amalgamation from <https://sqlite.org/download.html> and check its SHA3-256 against the
   page.
2. Replace `sqlite3.c` and `include/sqlite3.h`, and update this README.
3. `SQLiteLibrary.Requirement` still refuses a library below the store's needs. Run `make test` and the
   `SQLiteMemoryTests`, and print `braus memory --status` to see the linked version.
