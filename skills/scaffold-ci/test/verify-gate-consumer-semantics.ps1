$ErrorActionPreference = 'Stop'
$asset = Join-Path $PSScriptRoot '../assets/assert_gate_coverage.py'
$python = Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { throw 'Python is required for gate consumer regressions' }
@'
import importlib.util
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location('gate', sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
assert gate.static_truth("!'false'") is False
assert gate.static_truth("${{ 'left' == 'right' }}") is False
assert gate.static_truth("${{ 'false' }}") is True
assert gate.static_truth("${{ '' }}") is False
assert gate.static_truth("'false'") is False  # YAML boolean spelling
assert gate.runs_unconditionally('always()&&true')
assert not gate.runs_unconditionally("'always()'")
assert not gate.runs_unconditionally('always()&&github.ref')
assert gate.mask_quoted('echo "continued\\\ntext"; cd sub').count('\n') == 1
assert gate.changes_directory(['echo "Running gate', 'checks"; cd sub', 'echo done'])
assert not gate.changes_directory(['echo "Running gate', 'cd sub"', 'echo done'])

plain = ["jobs:\n", "  build:\n", "    runs-on: ubuntu-latest\n", "    steps:\n", "      - run:\n", "          python scripts/gate.py\n", "  ci-gate:\n", "    runs-on: ubuntu-latest\n"]
jobs = {'build': 1, 'ci-gate': 6}
bodies = list(gate.gated_run_bodies(plain, jobs, ['build'], 'ci-gate', pathlib.Path('.')))
assert any('python scripts/gate.py' in entry[1] for entry in bodies)
metadata = ["defaults:\n", "  run:\n", "    working-directory: sub/${{ github.workspace }}\n"]
assert gate.run_payload_indexes(metadata) == set()

base = '''jobs:
  build:
    if: ${{ always() && true }}
    runs-on: ubuntu-latest
    steps:
      - run: echo checked
  ci-gate:
    if: always()
    needs: [build]
    runs-on: ubuntu-latest
    steps:
      - if: always() && (contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled'))
        run: exit 1
'''
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / 'ci.yml'
    for field, expected in [('', None), ('continue-on-error: true', 'tolerated run step'),
                            ('if: false', 'always-skipped run step'),
                            ('continue-on-error: false', None)]:
        contents = base.replace('- run: echo checked', '- run: echo checked\n        ' + field) if field else base
        path.write_text(contents, encoding='utf-8')
        try:
            gate.check_file(str(path), 'ci-gate', set(), set())
        except SystemExit as exc:
            assert expected and expected in str(exc), str(exc)
        else:
            assert expected is None, field
print('gate consumer regressions OK')
'@ | & $python.Source -S - $asset
if ($LASTEXITCODE -ne 0) { throw 'Gate consumer regressions failed' }
