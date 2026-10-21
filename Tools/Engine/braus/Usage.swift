//
//  Usage.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// Usage is the help text.
enum Usage {

    static let text = """
    braus: drive a Mac application from the terminal through the Perception and Engine layers.

      braus --chat ["prompt"] [--provider claude|codex] [--model <name>]
                                              chat using your signed-in provider; --chat --help for options
      braus --chat --resume <UUID|last>         continue a saved conversation
      braus chat --script <file> --provider claude|codex [--model <name>] [--evidence <dir>] [--preflight <json>]
                                              one chat per request of the file, on one archive; evidence per request
      braus doctor [--knowledge <dir>] [--json] every component a run needs on this Mac: archive, index, model,
                                              permissions, provider CLIs, app and MCP bridge, disk

      braus windows <app>                      the window census: what would be driven, what is a pop-up
      braus scene   <app> [--json]             perceive the interaction window and print the text map
      braus peek    [--sections-only] [--labels]    live boxes over the frontmost app; peek --help for options
      braus watch   [<app>] [--raw] [--json]    inspect manual input and resolved controls; watch --help
      braus act     <app> <target> [options]   resolve the target by name, act, verify, report the outcome
      braus select  <app> <dropdown> <item> --seat   open and select in one background menu operation
      braus batch   <app> --window <title> --seat [options] -- <step> --then <step> ...
                                              run several steps in one Seat lifetime
      braus memory  <app>                      what the brain remembers about the application
      braus adapters [<app> [<query>]]         the app adapters: availability and verbs, or one app's as JSON
      braus adapters call <adapter.verb> [<json>]
                                              run one adapter verb and print its outcome
      braus mac open|windows|read|record <app> [<file.json>] [--window <n>] [--limit <n>]
                                              the MacDriver's reading side: background launch, windows,
                                              one window's scene and coverage, its tree as a fixture
      braus mac pane <name|id> | reveal <path> | open-with <path> [<app>]
                                              open a Settings pane, reveal a file, open a file, app behind
      braus memory  --status                   what the memory's archive file is, and the Recall this build
                                              would run (channel, model and its files, ablation), read only
      braus memory  --tasks [--last <n>] [--producer app|mcp|cli] [--json]
                                              the archive's tasks, newest first, with what the procedures
                                              and the Recall hold of each, counted; default the last 20
      braus memory  --task <id> [--graph]      one task's attempts, calls, procedures, qualifications, Brain
                                              relations, and its Recall (proposals, choices, queries, linked
                                              calls, uses), read only; --graph prints them as Mermaid
      braus memory  --part <id> --state <usable|to_reevaluate|retired> --reason <text>
                                              keep a procedure part out of the catalogue, or offer it again;
                                              nothing is deleted and retired is final
      braus memory  --requalify <route id>     evaluate a procedure version again from its facts
      braus memory  --apply-relations          run to its end the relation recovery the memory runs on its
                                              own: operations never evaluated (an archive migrated from an
                                              earlier schema, a write lost on exit), ones whose evidence
                                              arrived, ones evaluated under an earlier policy
      braus memory  --consolidation [--json]   what a consolidation would share, read only: subprocedures and
                                              steps grouped by method across procedures, with their labels
      braus memory  --quarantine-policy <version> --reason <text>
                                              stop offering what a qualification policy admitted
      braus memory  --recall-status            the Recall's index: generations, entries, vectors and work pending
      braus memory  --recall-rebuild [--within <seconds>]
                                              rebuild the Recall's index from the catalogue and wait for it
      braus memory  --recall-explain <text> [--limit <n>]
                                              score the indexed parts against a text, most relevant first;
                                              no query is recorded and nothing is selected
      braus memory  --import-json <dir>        copy the Brains of an earlier JSON Knowledge directory into
                                              the memory, for applications it holds nothing about yet; a new
                                              archive already took those beside it when it was created

    <app> is a bundle id (com.adobe.PremierePro) or an application name (Premiere); the match is
    case-insensitive and a name may be a prefix.

    act options:
      --verb click|double_click|triple_click|right_click|set_toggle   default click
      --value on|off                                                  the state a set_toggle must reach
      --section <name>                                                a panel name that disambiguates a shared label
      --dry-run                                                       resolve and report, perform nothing
      --allow-destructive                                             permit a target whose label names a destructive act

    common options:
      --knowledge <dir>          where memory lives; default ~/Library/Application Support/Braus/Knowledge
      --evidence <dir>           select: save captures; batch: dropdown captures in step-N subfolders
      --window <title>           with --seat: require one exact window title (for example "I/O Setup")
      --seat                     scene, act, select and batch: drive in the background on the Seat's virtual
                                 display instead of the real screen; the window is adopted, driven, returned
                                 through the app's own brokered session, so a running browser is given a new
                                 window of its own unless --window names one
      --allow-unvalidated-build  with --seat: the Driver's research opt-in for a macOS build its ledger has
                                 not validated

    batch example (with New Paths already open):
      braus batch "Pro Tools" --window "New Paths" --seat --allow-unvalidated-build -- \\
        select "Mono" "Stereo" --then \\
        act "Auto-create sub paths" --verb set_toggle --value on --then act "Create"

    Batch steps are select <dropdown> <item> or act <target> [--verb ...] [--value ...] [--section ...].
    Put shared options before --. The app is specified once. All arguments are checked before adoption.
    Each step reads the window again. Failure, ambiguity, unverified effects or a lost target stop the batch;
    a verified set_toggle that is already on/off continues. Earlier effects remain, with no rollback or replay.
    The final step may close the window. Changing windows between steps and batch --dry-run are not supported.

    Screen Recording and Accessibility must be granted to the terminal that runs this.
    select uses native menu actions when exposed; custom dropdowns use a routed opener and visible-row keyboard selection.
    Both the current value and desired item must be readable in a custom menu. The closed dropdown verifies success.
    """
}
