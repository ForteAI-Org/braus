#!/usr/bin/env python3
"""Measures a first execution of a task against its reuse and a control without recall, on a live run's root.

It never starts Braus, never acts on an application and never writes to an archive: the archive is read with
mode=ro in one read transaction (the observatory's reader does the same and is checked to create no file).

  sample   --root R --out O [--interval 1] [--match REGEX]
           every interval until Ctrl-C: the resident memory (RSS, KiB) and CPU of the processes whose command matches
           (Braus, braus, braus-bridge, claude, codex by default), and the bytes of the run's Knowledge folder (each
           file's logical size and allocated blocks: the archive, its -wal and -shm, backups, migration copies) and of
           its Models folder apart. Appends to O/samples.jsonl.
  mark     --out O LABEL [--task ID]
           appends a wall-clock marker to O/markers.jsonl: the tester's own instants (request sent, result verified
           independently), which the archive cannot know.
  report   --root R --out O [--usage U.json]
           per task of the archive: when it opened and closed, its calls (started, completed, failed, verified), its
           searches and choices with their Engine durations and sizes, when its interpretation and version were
           recorded and when its parts entered the index, the peak RSS per process and the disk growth over its window,
           and the provider's token counts when U.json gives them ({task_id: {input, output, cache_read, cache_write,
           reasoning, source}}). Writes O/report.json and O/report.md. A figure not measured is "unknown", never 0.
  compare  --out O --pairs P.json
           P.json: [{"name", "model", "first": task_id, "reuse": task_id, "control": task_id or null,
           "first_correct": bool, "reuse_correct": bool, "control_correct": bool or null, "repetition": n}], with the
           correctness the tester verified independently. Writes O/compare.md: every sample, then the median and range
           per pair kind with their counts; the observed reduction (first − reuse) / first only for pairs both correct;
           no percentile from fewer than 20 samples. A descriptive comparison, not a causal claim: the control and the
           ablations (BRAUS_MEASURE_ABLATION) are what attribute a difference to the knowledge.
"""
import argparse
import json
import os
import re
import signal
import sqlite3
import statistics
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_MATCH = r'(^|/)(Braus|braus|braus-bridge|claude|codex)( |$)'


def now_ms():
    return int(time.time() * 1000)


def folder_bytes(folder):
    """Each file under folder: (logical bytes, allocated bytes)."""
    found = {}
    if not folder.is_dir():
        return found
    for path in sorted(folder.rglob('*')):
        if path.is_file() and not path.is_symlink():
            stat = path.stat()
            found[str(path.relative_to(folder))] = [stat.st_size, stat.st_blocks * 512]
    return found


def processes(pattern):
    out = subprocess.run(['ps', '-A', '-o', 'pid=,rss=,%cpu=,command='], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and re.search(pattern, parts[3]) and 'measure-reuse.py' not in parts[3]:
            rows.append({'pid': int(parts[0]), 'rss_kib': int(parts[1]), 'cpu': float(parts[2]),
                         'command': parts[3][:160]})
    return rows


def sample(args):
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    root = Path(args.root)
    stop = {'now': False}
    signal.signal(signal.SIGINT, lambda *_: stop.update(now=True))
    signal.signal(signal.SIGTERM, lambda *_: stop.update(now=True))
    with (out / 'samples.jsonl').open('a') as file:
        file.write(json.dumps({'kind': 'start', 'wall_ms': now_ms(), 'interval_s': args.interval, 'match': args.match,
                               'root': str(root)}) + '\n')
        while not stop['now']:
            record = {'kind': 'sample', 'wall_ms': now_ms(), 'processes': processes(args.match),
                      'knowledge': folder_bytes(root / 'AppSupport' / 'Knowledge'),
                      'models': folder_bytes(root / 'AppSupport' / 'Models')}
            file.write(json.dumps(record) + '\n')
            file.flush()
            time.sleep(args.interval)
        file.write(json.dumps({'kind': 'stop', 'wall_ms': now_ms()}) + '\n')


def mark(args):
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with (out / 'markers.jsonl').open('a') as file:
        file.write(json.dumps({'label': args.label, 'task': args.task, 'wall_ms': now_ms()}) + '\n')
    print(f'{args.label} at {now_ms()}')


def read_archive(database):
    connection = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True, timeout=0.5)
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA query_only=ON')
    try:
        connection.execute('BEGIN')
        def rows(sql, *values):
            return [dict(row) for row in connection.execute(sql, values)]
        def columns(table):
            return {row['name'] for row in rows(f'PRAGMA table_info("{table}")')}
        version = connection.execute('PRAGMA user_version').fetchone()[0]
        tasks = rows('SELECT task_id, opened_at_ms, closed_at_ms FROM memory_tasks ORDER BY opened_at_ms')
        report = []
        for task in tasks:
            tid = task['task_id']
            goal = rows("SELECT goal FROM memory_task_revisions WHERE task_id = ? ORDER BY revision LIMIT 1", tid)
            calls = rows("""SELECT a.event_id, a.tool_kind, a.execution_status, a.started_at_ms, a.completed_at_ms, a.duration_ms
                            FROM memory_agent_actions a JOIN memory_task_call_revisions r ON r.event_id = a.event_id
                            WHERE r.task_id = ? ORDER BY a.started_at_ms""", tid)
            ends = rows("SELECT checkpoint_kind, recorded_at_ms, declared_status FROM memory_task_checkpoints WHERE task_id = ? ORDER BY sequence", tid)
            proposals = rows("""SELECT proposal_id, reason, channel, search_status, search_note, candidates_considered, proposal_bytes,
                                       recorded_at_ms, duration_us FROM memory_recall_proposals WHERE task_id = ? ORDER BY recorded_at_ms""", tid)
            queries = rows("""SELECT query_id, selector_version, coverage, delivery, delivery_bytes, recorded_at_ms, duration_us
                              FROM memory_recall_queries WHERE task_id = ? ORDER BY recorded_at_ms""", tid)
            versions = rows("SELECT route_id, built_at_ms FROM memory_procedure_versions WHERE task_id = ? ORDER BY built_at_ms", tid)
            interpretations = rows("""SELECT i.recorded_at_ms FROM memory_procedure_interpretations i
                                      JOIN memory_procedure_candidates c ON c.candidate_id = i.candidate_id
                                      WHERE c.task_id = ? ORDER BY i.recorded_at_ms""", tid) if 'task_id' in columns('memory_procedure_candidates') else []
            indexed = []
            for built in versions:
                entered = rows("""SELECT min(e.entered_at_ms) AS first, max(e.entered_at_ms) AS last, count(*) AS parts
                                  FROM memory_recall_entries e JOIN memory_recall_generations g ON g.generation_id = e.generation_id
                                  WHERE e.route_id = ? AND g.status = 'ready'""", built['route_id'])
                indexed.append({'route_id': built['route_id'], **(entered[0] if entered else {})})
            report.append({'task_id': tid, 'goal': goal[0]['goal'] if goal else None, 'opened_at_ms': task['opened_at_ms'],
                           'closed_at_ms': task['closed_at_ms'], 'checkpoints': ends,
                           'calls': {'count': len(calls), 'failed': sum(1 for c in calls if c['execution_status'] == 'failed'),
                                     'first_started_ms': calls[0]['started_at_ms'] if calls else None,
                                     'last_completed_ms': max((c['completed_at_ms'] or 0 for c in calls), default=None) or None,
                                     'tools': sorted({c['tool_kind'] for c in calls})},
                           'proposals': proposals, 'queries': queries, 'interpretations': interpretations,
                           'versions': versions, 'indexed': indexed})
        vectors = rows('SELECT count(*) AS n FROM memory_recall_vectors')[0]['n']
        generations = rows('SELECT generation_id, document_format, space_id, status, started_at_ms, ready_at_ms FROM memory_recall_generations')
        return {'schema_version': version, 'tasks': report, 'vectors': vectors, 'generations': generations}
    finally:
        connection.rollback()
        connection.close()


def load_jsonl(path):
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def window_figures(samples, start_ms, end_ms):
    """Peak RSS per process name and the Knowledge folder's bytes at the window's edges, from the samples."""
    inside = [s for s in samples if s.get('kind') == 'sample' and start_ms - 5000 <= s['wall_ms'] <= end_ms + 5000]
    if not inside:
        return {'samples': 0, 'peak_rss_kib': 'unknown', 'knowledge_bytes': 'unknown'}
    peaks = {}
    for s in inside:
        for p in s['processes']:
            name = Path(p['command'].split(' ')[0]).name
            peaks[name] = max(peaks.get(name, 0), p['rss_kib'])
    def total(s):
        logical = sum(v[0] for v in s['knowledge'].values())
        allocated = sum(v[1] for v in s['knowledge'].values())
        return {'logical': logical, 'allocated': allocated, 'files': len(s['knowledge'])}
    return {'samples': len(inside), 'peak_rss_kib': peaks, 'knowledge_bytes': {'start': total(inside[0]), 'end': total(inside[-1])},
            'note': 'RSS of each process at its own peak; peaks of different processes are not simultaneous and share pages'}


def report(args):
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    root = Path(args.root)
    database = root / 'AppSupport' / 'Knowledge' / 'memory.sqlite'
    archive = read_archive(database)
    samples = load_jsonl(out / 'samples.jsonl')
    markers = load_jsonl(out / 'markers.jsonl')
    usage = json.loads(Path(args.usage).read_text()) if args.usage else {}
    for task in archive['tasks']:
        end = task['closed_at_ms'] or (task['checkpoints'][-1]['recorded_at_ms'] if task['checkpoints'] else task['opened_at_ms'])
        task['window'] = window_figures(samples, task['opened_at_ms'], end)
        task['markers'] = [m for m in markers if m.get('task') == task['task_id']]
        task['tokens'] = usage.get(task['task_id'], 'unknown')
        calls = task['calls']
        last_effect = calls['last_completed_ms']
        interpreted = task['interpretations'][-1]['recorded_at_ms'] if task['interpretations'] else None
        indexed = max((i.get('last') or 0 for i in task['indexed']), default=0) or None
        task['durations_ms'] = {
            'open_to_close': (task['closed_at_ms'] - task['opened_at_ms']) if task['closed_at_ms'] else 'unknown',
            'open_to_first_call': (calls['first_started_ms'] - task['opened_at_ms']) if calls['first_started_ms'] else 'unknown',
            'last_call_to_interpretation': (interpreted - last_effect) if interpreted and last_effect else 'unknown',
            'interpretation_to_indexed': (indexed - interpreted) if indexed and interpreted else 'unknown',
            'engine_search_ms': [round(p['duration_us'] / 1000, 2) for p in task['proposals']] or 'none',
            'engine_choice_ms': [round(q['duration_us'] / 1000, 2) for q in task['queries']] or 'none',
        }
    (out / 'report.json').write_text(json.dumps(archive, indent=2, sort_keys=True, ensure_ascii=False))
    lines = [f"# Run measures: {root}", '', f"Schema {archive['schema_version']}; vectors {archive['vectors']}; generations "
             + ', '.join(f"{g['generation_id']}:{g['status']}:{g['space_id'] or 'lexical'}" for g in archive['generations']), '',
             '| Task | Goal | Calls (failed) | Open→close ms | Last call→interpreted ms | Interpreted→indexed ms | Searches (channel, status, ms) | Choices | Peak RSS KiB | Knowledge bytes start→end | Tokens |',
             '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |']
    for t in archive['tasks']:
        d = t['durations_ms']
        searches = '; '.join(f"{p['channel']}/{p['search_status']}/{round(p['duration_us']/1000,1)}" for p in t['proposals']) or 'none'
        window = t['window']
        disk = window['knowledge_bytes']
        disk_text = f"{disk['start']['logical']}→{disk['end']['logical']}" if isinstance(disk, dict) else disk
        rss = window['peak_rss_kib']
        rss_text = ', '.join(f'{k} {v}' for k, v in rss.items()) if isinstance(rss, dict) else rss
        lines.append(f"| {t['task_id'][:8]} | {(t['goal'] or '')[:40]} | {t['calls']['count']} ({t['calls']['failed']}) | {d['open_to_close']} | "
                     f"{d['last_call_to_interpretation']} | {d['interpretation_to_indexed']} | {searches} | {len(t['queries'])} | {rss_text} | "
                     f"{disk_text} | {t['tokens'] if isinstance(t['tokens'], str) else json.dumps(t['tokens'])} |")
    (out / 'report.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


def compare(args):
    out = Path(args.out)
    archive = json.loads((out / 'report.json').read_text())
    tasks = {t['task_id']: t for t in archive['tasks']}
    pairs = json.loads(Path(args.pairs).read_text())
    rows, by_kind = [], {}
    for pair in pairs:
        for kind in ('first', 'reuse', 'control'):
            tid = pair.get(kind)
            if not tid or tid not in tasks:
                continue
            task = tasks[tid]
            duration = task['durations_ms']['open_to_close']
            tokens = task['tokens']
            rows.append((pair['name'], pair.get('model'), pair.get('repetition'), kind, tid[:8], duration,
                         pair.get(f'{kind}_correct'), tokens if isinstance(tokens, str) else tokens.get('input', 'unknown')))
            if isinstance(duration, int) and pair.get(f'{kind}_correct'):
                by_kind.setdefault((pair['name'], pair.get('model'), kind), []).append(duration)
    lines = ['# First execution, reuse and control', '', 'Every sample:', '',
             '| Pair | Model | Rep. | Kind | Task | Open→close ms | Correct | Input tokens |', '| --- | --- | --- | --- | --- | --- | --- | --- |']
    lines += [f'| {a} | {b} | {c} | {d} | {e} | {f} | {g} | {h} |' for a, b, c, d, e, f, g, h in rows]
    lines += ['', 'Per kind, correct tasks only (median, min–max, n; no percentile under 20 samples):', '',
              '| Pair | Model | Kind | Median ms | Range ms | n |', '| --- | --- | --- | --- | --- | --- |']
    for (name, model, kind), values in sorted(by_kind.items(), key=lambda item: tuple(str(x) for x in item[0])):
        lines.append(f'| {name} | {model} | {kind} | {statistics.median(values):.0f} | {min(values)}–{max(values)} | {len(values)} |')
    reductions = []
    for pair in pairs:
        first, reuse = tasks.get(pair.get('first') or ''), tasks.get(pair.get('reuse') or '')
        if first and reuse and pair.get('first_correct') and pair.get('reuse_correct'):
            a, b = first['durations_ms']['open_to_close'], reuse['durations_ms']['open_to_close']
            if isinstance(a, int) and isinstance(b, int) and a > 0:
                reductions.append((pair['name'], pair.get('repetition'), round((a - b) / a, 3)))
    lines += ['', 'Observed reduction (first − reuse) / first, both correct; negative is slower; descriptive only:', '']
    lines += [f'- {name} rep. {rep}: {value}' for name, rep, value in reductions] or ['- none: no pair with both tasks correct']
    (out / 'compare.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('sample'); p.add_argument('--root', required=True); p.add_argument('--out', required=True)
    p.add_argument('--interval', type=float, default=1.0); p.add_argument('--match', default=DEFAULT_MATCH)
    p = sub.add_parser('mark'); p.add_argument('--out', required=True); p.add_argument('label'); p.add_argument('--task')
    p = sub.add_parser('report'); p.add_argument('--root', required=True); p.add_argument('--out', required=True); p.add_argument('--usage')
    p = sub.add_parser('compare'); p.add_argument('--out', required=True); p.add_argument('--pairs', required=True)
    args = parser.parse_args()
    {'sample': sample, 'mark': mark, 'report': report, 'compare': compare}[args.command](args)


if __name__ == '__main__':
    main()
