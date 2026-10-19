#!/usr/bin/env python3
"""Real process-exit tests on synthetic folders. No app or owner document access."""
import json, os, pathlib, subprocess, sys, uuid
root = pathlib.Path(__file__).resolve().parent.parent
binary = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/arm64-apple-macosx/debug/TryFolderProbe'
base = root / 'Artifacts/TestRuns' / ('process-crash-' + str(uuid.uuid4()))
base.mkdir(parents=True)
os.environ['TRYFOLDER_COORDINATION_ROOT'] = str(root / 'Artifacts/Coordination')
results = []
for mode in ('apply', 'undo'):
    boundaries = ['afterJournalPersisted', 'afterReservation', 'afterJournal', 'beforeCommit', 'afterCommit', 'afterRelease']
    boundaries += [f'{point}@{occurrence}' for point in ('beforeMutation', 'afterMutation', 'beforeVerified', 'afterVerified') for occurrence in (1, 2, 3)]
    for boundary in boundaries:
        hook = mode + '.' + boundary
        fixture = base / hook
        result = subprocess.run([str(binary), 'crash-' + mode, str(fixture), hook], capture_output=True, text=True)
        assert result.returncode == 86, (hook, result.returncode, result.stderr)
        result = subprocess.run([str(binary), 'recover', str(fixture)], capture_output=True, text=True)
        assert result.returncode == 0, (hook, result.returncode, result.stderr)
        source = fixture / 'Source'
        terminal = boundary in ('afterCommit', 'afterRelease')
        applied = (mode == 'undo') != terminal
        expected_edit = 'reviewed\n' if applied else 'starting\n'
        assert (source / 'edit.txt').read_text() == expected_edit, hook
        assert (source / 'added.txt').exists() == applied, hook
        assert (source / 'remove.txt').exists() != applied, hook
        results.append({'hook': hook, 'exit': 86, 'recovered': True, 'idempotent': True})
print(json.dumps({'checks': results, 'fixtureRoot': str(base)}, indent=2))
