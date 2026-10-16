#!/usr/bin/env python3
"""M3 identity diagnostic carrier (Issue #80, admission 6209387364): --self-test runs the four
synthetic guards (CONTROL_ONLY); no argument runs the stop proof of the provision, baseline B of
the original metric_identity, and at most one trace T. Text evidence only; no Case runs.
"""
import hashlib
import os
import re
import resource
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve()
REPO = HERE.parents[2]
SOURCE = ('.github/workflows/openfoam-evidence.yml', 509823,
          '65446acba49eac2b371c6dc8afabceac052a1b9a90fae870f6af6b4b191ecb92')
VERSION = ('.openfoam-version', 6, 'f45ab757cb0d9b2d18eac5e0208643a6d43a32a634a35ff1d0456857b95129f5')
BLOCKS = (('definitions', 88598, '2c8682abfe8dd8a1cf89b9a268f7fc361b6b6180dde4374a2a318bcfe6899661'),
          ('identity_script', 956, '9a43acb03f1fc7d7008be6236a5d8b8e48125646395c10879b7c0945e9387b7b'),
          ('clock_stop_op', 7863, '8ba5373049732316ad06dacb08ec8ee4081330efa6542b51b4901f0fc06714ba'),
          ('require_values', 1083, '89214fbad0e5d2d65243562fb87cb551cbeae7bc29111d1af863c55111654612'),
          ('identity_function', 2521, '2578396818831bd18856bf7735682cf127f1cbfc9709fd5afba6ba37f2ee1b83'),
          ('bounded_runner', 2722, 'f7a1f172248b7c744d25cfbd3f00102c00b9e5ca793b403e654112478a480bf5'))
NAME = 'm3-identity-diagnostic'
PATH0 = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
BASHRC = '/usr/lib/openfoam/openfoam2512/etc/bashrc'
LIMIT_MS = 89921             # 90000 ms less the 79 ms prefix
ENTRY_MS = LIMIT_MS + 22000  # with the cleanup time and a margin
STREAM, PREFIX, RECORD, PACKET, FILES = 1048576, 65536, 65536, 8388608, 256
# Each guard: name, mode, expected IDENTITY_RETURN, M_OUTCOME, M_STATUS, M_CODE.
GUARDS = (('success', 'B', ('0', 'COMPLETED', '0', '')), ('stalled', 'T', ('1', 'TIMEOUT', '124', 'TIMEOUT')),
          ('nonzero', 'T', ('1', 'FAILED', '7', 'ENVIRONMENT_MISMATCH')),
          ('overflow', 'B', ('1', 'FILE_LIMIT', '153', 'RESOURCE_LIMIT')))
INSTALLER = ('sudo', 'apt', 'apt-get', 'dpkg', 'http', 'https', 'gpgv', 'curl', 'bash', 'sh')
END, KEYS = [0], []  # the work end in ms (T0 + 720 s); the identity keys

DRIVER = r'''# The fixed driver of metric_identity only: definitions, directory, mode, bashrc, seed, end, prelude.
set -euo pipefail
source "$1"
M_DIR="$2" M_LOG_DIR="$2" M_OUT_FILE="" M_ERR_FILE="" M_OUT="" M_ERR="" M_RECORD="" M_FOAM_RECORD=""
M_FSIZE="" M_OP_END="" M_SELECT_USED=0 M_CALC_USED=0 M_WORK_USED="$5" M_CLEANUP_USED=0
M_GROUPS=() M_FILES=() M_STOP=EMPTY M_OUTCOME=NOT_STARTED M_STATUS=124 M_GROUP=- M_LIMIT=0 M_ELAPSED=0
M_CODE="" M_REASON="" M_POINT=environment M_FAIL_POINT=NONE M_SEQ=2
BASELINE_RESULT=SUCCEEDED OPENFOAM_BASELINE=v2512 OPENFOAM_PACKAGE=openfoam2512-default OPENFOAM_BASHRC="$4"
M_START_MS="$(metric_now_ms)"
M_END_MS="$6"
printf 'seq\tlabel\tclass\tlimit_ms\tfile_limit_bytes\tstart_ms\tend_ms\tstatus\toutcome\tgroup\tlog\tvector\n' \
    > "${M_DIR}/commands.tsv"
exec 3> "${M_DIR}/trace.txt"
if [[ "$3" == T ]]; then
    export BASH_ENV="$7"
fi
status=0
metric_identity || status=$?
unset BASH_ENV
exec 3>&-
{
    printf 'IDENTITY_RETURN=%s\n' "$status"
    for name in M_OUTCOME M_STATUS M_CODE M_REASON M_FAIL_POINT M_LIMIT M_FILE_LIMIT M_GROUP M_STOP \
                M_ELAPSED M_START_MS M_END_MS BASH_VERSION; do
        printf '%s=%s\n' "$name" "${!name:-}"
    done
    printf 'DRIVER_END=COMPLETE\n'
} > "${M_DIR}/driver.env"
'''

PRELUDE = r'''# The fixed T prelude, Bash built-ins only: the identity Bash alone traces, to descriptor 3.
mapfile -d '' -t M3D_ARGV 2> /dev/null < "/proc/$$/cmdline" || M3D_ARGV=()
if [[ "${M3D_ARGV[1]:-}" != -c || "${M3D_ARGV[3]:-}" != identity ]]; then
    unset M3D_ARGV
    return 0
fi
unset M3D_ARGV
BASH_XTRACEFD=3
PS4='+IDTRACE ${EPOCHREALTIME} ${BASHPID} ${LINENO} '
set -x
'''


class Stop(Exception):
    """A fail-closed end: the arguments are a reason code and a text."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def now_ms():
    return time.time_ns() // 1000000


def entry(argv):
    return {(): 'native', ('--self-test',): 'self-test'}.get(tuple(argv))


def read(path):
    return path.read_bytes() if path.is_file() and not path.is_symlink() else b''


def blocks_of(data):
    # Ten leading spaces removed where present; all other bytes kept.
    lines = [x[10:] if x.startswith(b' ' * 10) else x for x in data.split(b'\n')]

    def at(start, text=None, prefix=None):
        for i in range(start, len(lines)):
            if lines[i] == text or (prefix and lines[i].startswith(prefix)):
                return i
        raise Stop('SOURCE_MISMATCH', 'a fixed marker is missing')

    def part(a, b):
        return b''.join(x + b'\n' for x in lines[a:b])

    beg = at(0, b'# ---- M3 mean speed: begin ----')
    ida, clk = at(beg, b"METRIC_IDENTITY_SCRIPT='"), at(beg, b'metric_now_ms() {')
    req = at(clk, b'metric_require() {')
    fun, lib = at(req, b'metric_identity() {'), at(0, b'cat > "$LIB" <<\'EVIDENCE_LIB\'')
    return {'definitions': part(beg, at(beg, b'# ---- M3 mean speed: end ----')),
            'identity_script': b'\n' + part(ida + 1, at(ida + 1, b"'")),
            'clock_stop_op': part(clk, at(clk, prefix=b'# metric_foam_op ')),
            'require_values': part(req, at(req, prefix=b'# metric_compare ')),
            'identity_function': part(fun, at(fun, prefix=b'# metric_source ')),
            'bounded_runner': part(lib + 1, at(lib + 1, b'EVIDENCE_LIB'))}


def check_source(src, ver, got=None):
    # Hashes before interpretation.
    for (rel, size, digest), data in ((SOURCE, src), (VERSION, ver)):
        if len(data) != size or sha(data) != digest:
            raise Stop('SOURCE_MISMATCH', f'{rel} is not {size} bytes with SHA-256 {digest}')
    got = got or blocks_of(src)
    for name, size, digest in BLOCKS:
        if len(got[name]) != size or sha(got[name]) != digest:
            raise Stop('SOURCE_MISMATCH', f'the {name} block is not {size} bytes with SHA-256 {digest}')
    return got


def runner_temp():
    text = os.environ.get('RUNNER_TEMP', '')
    path = Path(text)
    if not text or not path.is_absolute() or os.path.realpath(text) != text or not path.is_dir() or \
            path.stat().st_uid != os.getuid():
        raise Stop('ENVIRONMENT_UNAVAILABLE', f'RUNNER_TEMP {text!r} is unsafe')
    return path


def safe_work(path, temp):
    return (path.parent == temp and re.fullmatch(r'm3-identity-work\.[a-z0-9_]{8}', path.name) is not None
            and not path.is_symlink() and path.is_dir() and path.stat().st_uid == os.getuid()
            and os.path.realpath(path) == str(path))


def procs():
    # (pid, state, ppid, group, start, uid, name), or None if a stat file is unreadable.
    rows = []
    for name in filter(str.isdigit, os.listdir('/proc')):
        try:
            text = Path('/proc', name, 'stat').read_bytes().decode('latin-1')
            uid = os.stat('/proc/' + name).st_uid
        except (FileNotFoundError, ProcessLookupError):
            continue
        except OSError:
            return None
        f = text[text.rindex(')') + 2:].split()
        rows.append((int(name), f[0], int(f[1]), int(f[2]), int(f[19]), uid, text[text.index('(') + 1:text.rindex(')')]))
    return rows


def stop(group, seconds=6.0):
    # EMPTY, STOPPED, or NOT_STOPPED of one known group; groups below 2 and the own group are refused.
    def empty():
        rows = procs()
        return rows is not None and not [r for r in rows if r[3] == group and r[1] != 'Z']

    if group < 2 or group == os.getpgrp():
        return 'NOT_STOPPED'
    if empty():
        return 'EMPTY'
    end = time.monotonic() + seconds
    for sig, until in ((signal.SIGTERM, end - seconds / 2), (signal.SIGKILL, end)):
        try:
            os.killpg(group, sig)
        except OSError:
            pass
        while time.monotonic() < until:
            if empty():
                return 'STOPPED'
            time.sleep(0.1)
    return 'STOPPED' if empty() else 'NOT_STOPPED'


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (4294967296, 4294967296))
    resource.setrlimit(resource.RLIMIT_CPU, (90, 90))


def put(path, rows):
    text = ''.join(f'{k}=' + ''.join(c if c.isprintable() else ' ' for c in str(v))[:2000] + '\n' for k, v in rows)
    data = (text + 'RECORD_END=COMPLETE\n').encode('utf-8', 'replace')
    if len(data) > RECORD:
        raise Stop('RECORD_LIMIT', f'{path.name} would hold more than {RECORD} bytes')
    path.write_bytes(data)


def record_ok(data):
    parts = [line.partition(b'=') for line in data[:-1].split(b'\n')]
    keys = [k for k, sep, _ in parts if sep and re.fullmatch(rb'[A-Za-z_]\w*', k)]
    return (len(data) <= RECORD and data.endswith(b'\nRECORD_END=COMPLETE\n') and len(keys) == len(parts)
            and len(set(keys)) == len(keys))


def kv(path):
    out = {}
    for line in read(path)[:RECORD].decode('utf-8', 'replace').split('\n'):
        k, sep, v = line.partition('=')
        if sep and re.fullmatch(r'[A-Za-z_]\w*', k):
            out.setdefault(k, v)
    return out


def files_of(root, skip=()):
    out = []
    for top, dirs, names in os.walk(root):
        dirs.sort()
        out += [p for p in (Path(top, n) for n in sorted(names)) if p.relative_to(root).as_posix() not in skip]
    return out


def listing(root, skip=()):
    paths = files_of(root, skip)[:FILES + 1]
    rows = ''.join(f'{p.relative_to(root).as_posix()}\t{len(read(p))}\t{sha(read(p))}\n' for p in paths)
    return 'path\tbytes\tsha256\n' + rows, len(paths), sum(len(read(p)) for p in paths)


def keep(path, limit, dst=None):
    if path.is_symlink() or not path.is_file():
        return (0, 0, sha(b''), 'MISSING')
    size = path.stat().st_size
    if dst is None and size > limit:
        os.truncate(path, limit)
    with open(path, 'rb') as f:
        data = f.read(limit)
    if dst is not None:
        dst.write_bytes(data)
    return (size, len(data), sha(data), 'COMPLETE' if size <= limit else 'PARTIAL_PREFIX')


def scrub(paths):
    # A file with a secret value of the environment becomes one redaction line.
    names = re.compile(rb'TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE')
    values = [v for k, v in os.environb.items() if names.search(k.upper()) and len(v) >= 8]
    hits = [p for p in paths if any(v in read(p) for v in values)]
    for path in hits:
        path.write_bytes(b'[REDACTED]\n')
    return len(hits)


def cleanup(work, temp, stopped):
    if work is None:
        return 'NOT_NEEDED', ''
    if not stopped or not safe_work(work, temp):
        return 'CLEANUP_UNVERIFIED', ''
    text = listing(work)[0]
    shutil.rmtree(work, ignore_errors=True)
    return ('CLEANUP_UNVERIFIED' if work.exists() else 'REMOVED'), text


def finish(root, work, temp, stopped):
    clean, removed = cleanup(work, temp, stopped)
    (root / 'work-removed.tsv').write_bytes(removed.encode('utf-8', 'replace')[:RECORD])
    return clean, scrub(files_of(root))


def prepare(temp, got):
    KEYS[:] = re.findall(r'printf "(\w+)=%s', got['identity_script'].decode())
    work = Path(tempfile.mkdtemp(prefix='m3-identity-work.', dir=temp))
    files = {'definitions': got['definitions'], 'driver': DRIVER.encode(), 'prelude': PRELUDE.encode()}
    for name, data in files.items():
        (work / f'{name}.sh').write_bytes(data)
        if read(work / f'{name}.sh') != data:
            raise Stop('SOURCE_MISMATCH', f'the work file {name}.sh does not hold its exact bytes')
    return work, [(f'WORK_{n.upper()}_SHA256', sha(d)) for n, d in files.items()]


def probe(work, pdir, mode, bashrc, seed, env, wait, dst=None):
    # One driver run in its own session with the ceilings; then both groups proved empty.
    pdir.mkdir(mode=0o700)
    for key in ('HOME', 'TMPDIR'):
        Path(env[key]).mkdir(mode=0o700, parents=True, exist_ok=True)
    r = {'START_MS': now_ms(), 'PROBE_ENV': ' '.join(f'{k}={v}' for k, v in env.items())}
    args = ['/usr/bin/bash', '--noprofile', '--norc', str(work / 'driver.sh'), str(work / 'definitions.sh'), str(pdir),
            mode, bashrc, str(seed), str(min(r['START_MS'] + 180000, END[0])), str(work / 'prelude.sh')]
    with open(pdir / 'driver.out', 'wb') as f:
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT, env=env,
                             cwd=env['HOME'], start_new_session=True, preexec_fn=limits)
    stat = read(Path(f'/proc/{p.pid}/stat')).decode('latin-1')
    r['DRIVER_PID'], r['DRIVER_START_ID'] = p.pid, (stat[stat.rfind(')') + 2:].split()[19:20] or ['UNAVAILABLE'])[0]
    try:
        r['DRIVER_EXIT'] = p.wait(timeout=wait)
    except subprocess.TimeoutExpired:
        r['DRIVER_EXIT'] = 'LATE'
    r['DRIVER_GROUP_STOP'] = stop(p.pid)
    p.poll()
    d = r['d'] = kv(pdir / 'driver.env')
    group = d.get('M_GROUP', '')
    r['OPERATION_GROUP_STOP'] = 'EMPTY' if group == '-' else stop(int(group)) if group.isdigit() else 'NOT_STOPPED'
    r['END_MS'], r['out'], r['trace'] = now_ms(), read(pdir / '03-identity.out'), read(pdir / 'trace.txt')
    r['rows'] = [x for x in read(pdir / 'commands.tsv').decode('utf-8', 'replace').split('\n')[1:] if x]
    frames = [x for x in r['trace'].split(b'\n') if x]
    r['last'] = frames[-1].decode('utf-8', 'replace') if frames else ''
    r['rec'] = [(k, r[k]) for k in ('START_MS', 'END_MS', 'DRIVER_PID', 'DRIVER_START_ID', 'DRIVER_EXIT',
                                    'DRIVER_GROUP_STOP', 'OPERATION_GROUP_STOP', 'PROBE_ENV')]
    for key, name in (('STDOUT', '03-identity.out'), ('STDERR', '03-identity.err'), ('TRACE', 'trace.txt'),
                      ('DRIVER_OUT', 'driver.out'), ('DRIVER_ENV', 'driver.env'), ('COMMANDS', 'commands.tsv'),
                      ('IDENTITY', 'identity.txt')):
        r[key] = keep(pdir / name, PREFIX if dst or key[0] in 'DCI' else STREAM, dst / name if dst else None)
        r['rec'].append((f'FILE_{key}', ' '.join(map(str, (name,) + r[key]))))
    return r


def outcome(r, traced):
    d = r['d']
    if d.get('DRIVER_END') != 'COMPLETE' or r['DRIVER_EXIT'] != 0:
        return 'DRIVER_INCOMPLETE'
    if 'NOT_STOPPED' in (r['DRIVER_GROUP_STOP'], r['OPERATION_GROUP_STOP'], d.get('M_STOP')):
        return 'STOP_UNVERIFIED'
    if any(r[k][3] == 'PARTIAL_PREFIX' for k in ('STDOUT', 'STDERR', 'TRACE')):
        return 'STREAM_LIMIT'
    if (r['TRACE'][0] > 0) != traced:
        return 'TRACE_INCOMPLETE' if traced else 'TRACE_IN_BASELINE'
    if len(r['rows']) != 1 or not r['rows'][0].startswith('3\tidentity\tWORK\t'):
        return 'DIFFERENT_FAILURE'
    if d.get('IDENTITY_RETURN') == '0' and d.get('M_OUTCOME') == 'COMPLETED':
        return 'COMPLETED'
    end = tuple(d.get(k) for k in ('M_OUTCOME', 'M_STATUS', 'M_CODE', 'M_LIMIT'))
    return 'ORIGINAL_TIMEOUT' if end == ('TIMEOUT', '124', 'TIMEOUT', str(LIMIT_MS)) else 'DIFFERENT_FAILURE'


def trace_allowed(b, guards, stopped, left_ms):
    return b == 'ORIGINAL_TIMEOUT' and guards and stopped and left_ms >= ENTRY_MS


def verdict(b, t):
    if b != 'ORIGINAL_TIMEOUT':
        return 'EVIDENCE_LIMIT', 'NOT_REPRODUCED' if b == 'COMPLETED' else 'DIFFERENT_FAILURE', f'B ended with {b}'
    if t == 'ORIGINAL_TIMEOUT':
        return 'REVIEW_REQUIRED', 'STOP_LOCATION_OBSERVED', 'a location is no cause'
    if t == 'NOT_RUN':
        return 'EVIDENCE_LIMIT', 'ORIGINAL_TIMEOUT', 'no T: no time or stop proof'
    return 'EVIDENCE_LIMIT', 'TRACE_PERTURBED' if t == 'COMPLETED' else 'TRACE_' + t, f'T ended with {t}'


def fixture(base, name):
    tree, marker = base / 'usr/lib/openfoam/openfoam2512', base / 'forbidden-ran'
    for d in (base / 'fakebin', base / 'home', base / 'tmp', tree / 'etc', tree / 'bin'):
        d.mkdir(parents=True)
    core = 'exec /usr/bin/sleep 60' if name == 'stalled' else "printf '%s' 2512.0-2"
    tools = {base / 'fakebin/dpkg-query': f'case "${{3:-}}" in\n    openfoam2512-default) printf \'%s\' 2512.0-2 ;;\n'
             f'    openfoam2512) {core} ;;\n    *) exit 1 ;;\nesac', base / 'fakebin/uname': "printf '%s\\n' x86_64",
             base / 'fakebin/gcc': "/usr/bin/head -c 1100000 /dev/zero | /usr/bin/tr '\\0' 9" if name == 'overflow'
             else "printf '%s\\n' 13.3.0"}
    tools.update({tree / 'bin' / n: f': > {shlex.quote(str(marker))}; exit 1' for n in ('foamListTimes', 'simpleFoam')})
    for path, body in tools.items():
        path.write_text('#!/usr/bin/bash\n: M3D_FAKE_TOOL_SENTINEL\n' + body + '\n')
        path.chmod(0o755)
    rc = ['export WM_PROJECT_VERSION=v2512 WM_OPTIONS=linux64GccDPInt32Opt WM_COMPILER=Gcc',
          f'export PATH={shlex.quote(str(tree / "bin"))}:"$PATH"', ': "M3D_SECRET_PROBE=${M3D_FIXTURE_SECRET:-absent}"']
    (tree / 'etc/bashrc').write_text('\n'.join(rc + ["trap 'exit 7' EXIT"] * (name == 'nonzero')) + '\n')
    return tree / 'etc/bashrc', marker


def valid(out, tree):
    # The script keys in order, with values that metric_identity accepts.
    parts = [x.decode('utf-8', 'replace').partition('=') for x in out[:-1].split(b'\n')]
    v = {k: x for k, _, x in parts}
    return (out.endswith(b'\n') and [k for k, _, _ in parts] == KEYS and len(KEYS) == 12
            and (v['PACKAGE_VERSION'], v['ARCHITECTURE'], v['SOURCE_STATUS'], v['WM_PROJECT_VERSION'])
            == ('2512.0-2', 'x86_64', '0', 'v2512') and v['WM_COMPILER'].startswith('Gcc')
            and all(v[k].startswith(tree + '/') for k in ('PATH_foamListTimes', 'PATH_simpleFoam')))


def guard(work, gdir, name, mode, expect):
    base, cdir = work / ('guard-' + name), gdir / name
    bashrc, marker = fixture(base, name)
    tree = str(bashrc.parents[1])
    env = {'HOME': str(base / 'home'), 'TMPDIR': str(base / 'tmp'), 'PATH': f'{base}/fakebin:{PATH0}',
           'LC_ALL': 'C', 'LANG': 'C'}
    cdir.mkdir(mode=0o700)
    r = probe(work, base / 'probe', mode, str(bashrc), 83000, env, 20, cdir)
    out, trace, d, has_id = r['out'], r['trace'], r['d'], r['IDENTITY'][3] != 'MISSING'
    if name == 'success':
        output = valid(out, tree) and has_id and not trace
    elif name == 'stalled':
        output = (out == b'PACKAGE=openfoam2512-default\nPACKAGE_VERSION=2512.0-2\n' and not has_id
                  and re.match(r'\++IDTRACE \d+\.\d+ \d+ \d+ dpkg-query .* openfoam2512$', r['last']) is not None)
    elif name == 'nonzero':
        output = valid(out, tree) and not has_id and b': M3D_SECRET_PROBE=absent' in trace
    else:
        output = len(out) > STREAM and not has_id and not trace
    checks = {'END': tuple(d.get(k) for k in ('IDENTITY_RETURN', 'M_OUTCOME', 'M_STATUS', 'M_CODE')) == expect,
              'DRIVER': d.get('DRIVER_END') == 'COMPLETE' and r['DRIVER_EXIT'] == 0 and d.get('M_LIMIT') == '7000',
              'STOP': (r['DRIVER_GROUP_STOP'], r['OPERATION_GROUP_STOP']) == ('EMPTY', 'EMPTY')
              and d.get('M_STOP') in ('EMPTY', 'STOPPED'),
              'ROWS': len(r['rows']) == 1 and r['rows'][0].startswith('3\tidentity\tWORK\t7000\t'),
              'NO_FORBIDDEN_CALL': not marker.exists(), 'NO_TOOL_TRACE': b'M3D_FAKE_TOOL_SENTINEL' not in trace,
              'NO_SECRET': os.environb[b'M3D_FIXTURE_SECRET'] not in out + trace + read(base / 'probe/driver.out'),
              'OUTPUT': output}
    ok = all(checks.values())
    put(cdir / 'case.env', [('CASE', name), ('MODE', mode), ('LABEL', 'CONTROL_ONLY'), ('TRACE_LAST_FRAME', r['last'][:300])]
        + r['rec'] + [(f'CHECK_{k}', 'PASS' if v else 'FAIL') for k, v in checks.items()] + [('RESULT', 'PASS' if ok else 'FAIL')])
    line = ' '.join(d.get(k) or '-' for k in ('IDENTITY_RETURN', 'M_OUTCOME', 'M_STATUS', 'M_CODE')) + ' ' + mode
    return ok, line, 'NOT_STOPPED' not in (r['DRIVER_GROUP_STOP'], r['OPERATION_GROUP_STOP'])


def negatives(src, ver, got, temp, work):
    # Pure checks; no identity operation runs.
    def fails(*args):
        try:
            check_source(*args)
        except Stop:
            return True
        return False

    def end(traced=False, **change):
        full = (0, 0, '', 'COMPLETE')
        r = {'DRIVER_EXIT': 0, 'DRIVER_GROUP_STOP': 'EMPTY', 'OPERATION_GROUP_STOP': 'EMPTY', 'STDOUT': full,
             'STDERR': full, 'TRACE': full, 'rows': [f'3\tidentity\tWORK\t{LIMIT_MS}\t'], 'd': {
                 'DRIVER_END': 'COMPLETE', 'M_OUTCOME': 'TIMEOUT', 'M_STATUS': '124', 'M_CODE': 'TIMEOUT',
                 'M_LIMIT': str(LIMIT_MS), 'M_STOP': 'STOPPED'}}
        r.update(change)
        r['d'].update({k: v for k, v in change.items() if k.startswith('M_')})
        return outcome(r, traced)

    bad, link, planted = bytearray(src), work / 'negative-link', work / 'negative-secret'
    bad[len(bad) // 2] ^= 1
    link.symlink_to(work)
    planted.write_bytes(b'a ' + os.environb[b'M3D_FIXTURE_SECRET'] + b' b')
    n = {'ARGUMENTS': (entry([]), entry(['--self-test'])) == ('native', 'self-test') and not any(
        map(entry, (['--self-test'] * 2, ['--self-test=1'], ['-'], [''], ['--help'])))}
    n['SOURCE'] = (fails(bytes(bad), ver) and fails(src, b'v2512') and not fails(src, ver)
                   and fails(src, ver, dict(got, identity_script=got['identity_script'] + b' ')))
    n['PATH'] = safe_work(work, temp) and not any(safe_work(p, temp) for p in (link, temp, Path('/tmp')))
    n['RECORD'] = record_ok(b'A=1\nRECORD_END=COMPLETE\n') and not any(map(record_ok, (
        b'A=1\n', b'A=1\nRECORD_END=COMPLETE', b'A=1\nA=2\nRECORD_END=COMPLETE\n')))
    n['CLASSIFY'] = ((end(), end(M_STOP='NOT_STOPPED'), end(STDOUT=(STREAM + 1, STREAM, '', 'PARTIAL_PREFIX')),
                      end(M_STATUS='137'), end(TRACE=(5, 5, '', 'COMPLETE')), end(True))
                     == ('ORIGINAL_TIMEOUT', 'STOP_UNVERIFIED', 'STREAM_LIMIT', 'DIFFERENT_FAILURE',
                         'TRACE_IN_BASELINE', 'TRACE_INCOMPLETE')
                     and trace_allowed('ORIGINAL_TIMEOUT', True, True, ENTRY_MS)
                     and not trace_allowed('ORIGINAL_TIMEOUT', False, True, ENTRY_MS)
                     and not trace_allowed('ORIGINAL_TIMEOUT', True, False, ENTRY_MS))
    n['SECRET'] = scrub([planted]) == 1 and read(planted) == b'[REDACTED]\n'
    n['STOP'] = stop(0) == stop(1) == stop(os.getpgrp()) == 'NOT_STOPPED'
    n['CLEANUP'] = cleanup(work, temp, False)[0] == cleanup(link, temp, True)[0] == 'CLEANUP_UNVERIFIED' and work.is_dir()
    link.unlink()
    return n


def self_test():
    temp = runner_temp()
    root, gdir = temp / NAME, temp / NAME / 'guard'
    if root.exists() or root.is_symlink():
        raise Stop('CONTRACT_VIOLATION', f'{root} exists')
    root.mkdir(mode=0o700)
    gdir.mkdir(mode=0o700)
    os.environ['M3D_FIXTURE_SECRET'] = 'm3d-fixture-secret-' + os.urandom(16).hex()
    END[0] = now_ms() + 600000
    rows = [('GUARD_LABEL', 'CONTROL_ONLY'), ('DIAGNOSTIC_CONTEXT', 'NO_CASE'), ('M3_ACCEPTANCE_EVIDENCE', 'false'),
            ('COUNTER_MODEL', 'CONTROL_7000_MS'), ('GUARD_START_MS', now_ms())]
    cases, neg, work, stopped = {}, {}, None, True
    try:
        src, ver = read(REPO / SOURCE[0]), read(REPO / VERSION[0])
        got = check_source(src, ver)
        rows += [('SOURCE_RESULT', 'PASS')] + [(f'SOURCE_{n.upper()}', f'{s} {d}') for n, s, d in BLOCKS]
        work = prepare(temp, got)[0]
        for name, mode, expect in GUARDS:
            ok, line, halted = guard(work, gdir, name, mode, expect)
            cases[name], stopped = ok, stopped and halted
            rows += [(f'CASE_{name}', line), (f'CASE_{name}_RESULT', 'PASS' if ok else 'FAIL')]
            if not halted:
                break
        neg = negatives(src, ver, got, temp, work) if stopped else {}
        rows += [(f'NEG_{k}', 'PASS' if v else 'FAIL') for k, v in neg.items()]
    except Exception as x:
        rows.append(('GUARD_STOP', ': '.join(map(str, x.args)) if isinstance(x, Stop) else f'HELPER_ERROR: {x!r}'))
    clean, hits = finish(gdir, work, temp, stopped)
    text, count, size = listing(gdir)
    passed = (len(cases) == 4 and all(cases.values()) and len(neg) == 8 and all(neg.values())
              and clean == 'REMOVED' and hits == 0 and size <= 458752)
    rows += [('GUARD_CASES', len(cases)), ('NEGATIVE_CHECKS', len(neg)), ('CLEANUP', clean),
             ('SECRET_SCAN', f'REDACTED_FILES {hits}' if hits else 'CLEAN'), ('GUARD_EVIDENCE_BYTES', size),
             ('GUARD_FILES_SHA256', sha(text.encode())), ('HELPER_SHA256', sha(read(HERE))),
             ('RUN_ID', os.environ.get('GITHUB_RUN_ID', 'UNAVAILABLE')), ('GUARD_END_MS', now_ms()),
             ('GUARD_RESULT', 'PASS' if passed else 'FAIL')]
    put(gdir / 'receipt.env', rows)
    print(''.join(f'{k}={str(v)[:300]}\n' for k, v in rows if k.startswith(('CASE_', 'NEG_', 'GUARD_'))), end='')
    return 0 if passed else 1


def binding(gdir):
    # The run bindings, the clock start, and the same-run PASS receipt that binds its
    # retained guard files: a record without its evidence is no PASS.
    e, now, r = os.environ, now_ms(), kv(gdir / 'receipt.env')
    want = {'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
            'GITHUB_RUN_ATTEMPT': '1', 'RUNNER_OS': 'Linux', 'RUNNER_ARCH': 'X64'}
    wrong, t0 = [k for k, v in want.items() if e.get(k) != v], e.get('M3D_T0_MS', '')
    if wrong or not e.get('GITHUB_WORKFLOW_REF', '').endswith(f'/{NAME}.yml@refs/heads/main') or not os.getuid():
        raise Stop('CONTRACT_VIOLATION', f'wrong run binding {wrong}')
    if not re.fullmatch(r'[1-9][0-9]*', t0) or not now - 600000 <= int(t0) <= now:
        raise Stop('TIME_LIMIT', f'M3D_T0_MS {t0!r}')
    if not (record_ok(read(gdir / 'receipt.env')) and r.get('GUARD_RESULT') == 'PASS'
            and r.get('HELPER_SHA256') == sha(read(HERE)) and r.get('RUN_ID') == e.get('GITHUB_RUN_ID')
            and r.get('GUARD_FILES_SHA256') == sha(listing(gdir, ('receipt.env',))[0].encode())):
        raise Stop('GUARD_NOT_PASSED', 'no same-run PASS receipt binds the guard files')
    return int(t0)


def provision(root, st):
    # The stop proof of the provision step: an empty run_bounded group and no new root installer.
    idir = root / 'install'
    r, rows = kv(idir / 'install.env'), procs()
    group, up, result = r.get('CHILD_GROUP', ''), r.get('START_UPTIME', ''), r.get('INSTALL_RESULT', 'UNAVAILABLE')
    child = stop(int(group)) if group.isdigit() else 'NOT_STARTED' if result == 'NOT_ATTEMPTED' else 'NOT_RECORDED'
    ticks = int(float(up) * os.sysconf('SC_CLK_TCK')) if re.fullmatch(r'\d+\.\d+', up) else None
    new = None if rows is None or ticks is None else [
        x for x in rows if x[4] >= ticks and x[5] == 0 and x[1] != 'Z' and 2 not in (x[0], x[2])]
    stays = None if new is None else [x for x in new if x[6] in INSTALLER]
    halted = child in ('EMPTY', 'STOPPED', 'NOT_STARTED') and stays == []
    put(idir / 'stop.env', [('CHILD_GROUP_STOP', child), ('NEW_ROOT_PROCESSES', 'UNREADABLE' if new is None else
        ' '.join(f'{x[0]}:{x[6]}' for x in new[:200]) or 'NONE'), ('LIB_SHA256', sha(read(idir / 'lib.sh')))]
        + [(f'FILE_{n[:-4].upper()}', ' '.join(map(str, keep(idir / n, m)))) for n, m in (
            ('install.log', STREAM), ('timeout.log', PREFIX))] + [('INSTALL_STOP', 'VERIFIED' if halted else 'NOT_VERIFIED')])
    if not halted:
        st['stopped'] = False
        raise Stop('INSTALL_STOP_UNVERIFIED', 'no stop proof of the provision')
    if not record_ok(read(idir / 'install.env')) or result != 'SUCCEEDED' or not read(Path(BASHRC)) \
            or sha(read(idir / 'lib.sh')) != BLOCKS[5][2]:
        raise Stop('ENVIRONMENT_UNAVAILABLE', f'the provision result is {result}')
    return sha(read(Path(BASHRC)))


def native_probe(work, root, mode, st):
    if END[0] - now_ms() < ENTRY_MS:
        raise Stop('TIME_LIMIT', f'{mode} needs {ENTRY_MS} ms before T0 + 720 s')
    pdir = root / ('probe-' + mode)
    env = {'HOME': str(work / f'{mode}-home'), 'TMPDIR': str(work / f'{mode}-tmp'), 'PATH': PATH0,
           'LC_ALL': 'C', 'LANG': 'C'}
    r = probe(work, pdir, mode, BASHRC, 79, env, LIMIT_MS / 1000 + 10)
    end = outcome(r, mode == 'T')
    st['stopped'] = st['stopped'] and 'NOT_STOPPED' not in (r['DRIVER_GROUP_STOP'], r['OPERATION_GROUP_STOP'])
    keys = [x.partition(b'=')[0].decode('utf-8', 'replace') for x in r['out'].split(b'\n')[:-1]]
    put(pdir / 'probe.env', [('PROBE', mode), ('OUTCOME', end), ('COUNTER_MODEL', 'HISTORICAL_LIMIT_SEED'),
        ('VECTOR', f'bash -c "$METRIC_IDENTITY_SCRIPT" identity openfoam2512-default {BASHRC}'),
        ('TRACE_DELTA', 'BASH_ENV=prelude.sh, the only difference from B' if mode == 'T' else 'NONE'),
        ('LAST_COMPLETE_KEY', keys[-1] if keys else 'NONE'), ('TRACE_FRAMES', r['trace'].count(b'\n')),
        ('TRACE_LAST_FRAME', r['last'][:300] or 'NONE')] + r['rec'])
    return end


def native():
    temp = runner_temp()
    root, e = temp / NAME, os.environ
    if root.is_symlink() or not root.is_dir():
        raise Stop('GUARD_NOT_PASSED', f'no {root}')
    st = {'terminal': 'EVIDENCE_LIMIT', 'limit': 'the diagnostic did not reach its end', 'observation': 'NOT_OBSERVED',
          'B': 'NOT_RUN', 'T': 'NOT_RUN', 'stopped': True}
    work, rows = None, []
    try:
        t0 = binding(root / 'guard')
        END[0] = t0 + 720000
        rows += [('T0_MS', t0), ('WORK_END_MS', END[0])]
        work, hashes = prepare(temp, check_source(read(REPO / SOURCE[0]), read(REPO / VERSION[0])))
        put(root / 'identities.env', [('SOURCE_ORIGIN', 'M 0f5982a01efffdcfffb446fa704cd7511af50b36')] + hashes
            + [(f'SOURCE_{n.upper()}', f'{s} {d}') for n, s, d in BLOCKS] + [('HELPER_SHA256', sha(read(HERE))),
            ('WORKFLOW_SHA256', sha(read(REPO / f'.github/workflows/{NAME}.yml'))), ('PYTHON', sys.version)]
            + [(k, e.get(k)) for k in ('GITHUB_SHA', 'GITHUB_WORKFLOW_REF', 'GITHUB_RUN_ID', 'ImageOS', 'ImageVersion')]
            + [(f'TOOL_{t.upper()}', sha(read(Path('/usr/bin', t)))) for t in ('bash', 'timeout', 'prlimit')]
            + [('PRODUCER', 'run 38773149173 Case 7 sequence 3: 124 TIMEOUT at 89921 ms, no partial output'),
               ('DIFFERENCES', 'five-name environment; AS and CPU ceilings; seeded counters')])
        rows.append(('BASHRC_SHA256', provision(root, st)))
        st['B'] = native_probe(work, root, 'B', st)
        if trace_allowed(st['B'], True, st['stopped'], END[0] - now_ms()):
            st['T'] = native_probe(work, root, 'T', st)
        st['terminal'], st['observation'], st['limit'] = verdict(st['B'], st['T'])
    except Exception as x:
        violation = isinstance(x, Stop) and x.args[0] == 'CONTRACT_VIOLATION'
        st['terminal'] = 'CONTRACT_VIOLATION' if violation else 'EVIDENCE_LIMIT'
        st['limit'] = ': '.join(map(str, x.args)) if isinstance(x, Stop) else f'HELPER_ERROR: {x!r}'
    clean, hits = finish(root, work, temp, st['stopped'])
    _, count, size = listing(root)
    if hits:
        st['terminal'], st['limit'] = 'CONTRACT_VIOLATION', f'SECRET_EXPOSURE: {hits} retained files were redacted'
    elif count + 2 > FILES or size + 2 * RECORD > PACKET:
        st['terminal'], st['limit'] = 'EVIDENCE_LIMIT', f'PACKET_LIMIT: {count} files and {size} bytes'
    elif clean != 'REMOVED' and st['terminal'] == 'REVIEW_REQUIRED':
        st['terminal'], st['limit'] = 'EVIDENCE_LIMIT', f"CLEANUP_UNVERIFIED after: {st['limit']}"
    put(root / 'result.env', [('DIAGNOSTIC_CONTEXT', 'NO_CASE'), ('M3_ACCEPTANCE_EVIDENCE', 'false')]
        + [(k, st[x]) for k, x in (('TERMINAL_CLASSIFICATION', 'terminal'), ('OBSERVATION', 'observation'),
                                   ('EVIDENCE_LIMIT', 'limit'), ('B_RESULT', 'B'), ('T_RESULT', 'T'))]
        + [('CLEANUP', clean), ('SECRET_SCAN', 'REDACTED' if hits else 'CLEAN')] + rows + [('FINISH_MS', now_ms())])
    text, count, size = listing(root, ('inventory.tsv',))
    (root / 'inventory.tsv').write_text(text + f'TOTAL\t{count}\t{size}\n')
    print(f"m3 identity diagnostic: {st['terminal']} {st['observation']}: {st['limit']}")
    return 0 if st['terminal'] == 'REVIEW_REQUIRED' and clean == 'REMOVED' else 1


def main(argv):
    mode = entry(argv)
    if mode is None:
        print('usage: m3-identity-diagnostic.py [--self-test]', file=sys.stderr)
        return 2
    try:
        return self_test() if mode == 'self-test' else native()
    except Stop as s:
        print('m3 identity diagnostic:', *s.args, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
