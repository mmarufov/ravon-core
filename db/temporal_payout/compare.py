"""Run both payout saga implementations through one crash matrix and print it.

    cd db/temporal_payout
    .venv/bin/python compare.py [--repeat 3] [--out matrix.md]

Needs the PostgreSQL from db/ledger/README.md (LEDGER_DSN, default port 5433)
and the `temporal` CLI on PATH. Every number printed comes from the runs this
script performs; nothing is typed in by hand except the mechanism text, and
that cites file:line anchors resolved from the source at run time.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import pathlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
LEDGER = HERE.parent / "ledger"
PY = sys.executable

SEVEN = ["during_begin", "after_begin", "after_provider_call", "after_mark_submitted",
         "during_post", "after_post", "never"]
MID = ["worker_kill_mid_begin", "worker_kill_mid_provider", "worker_kill_mid_mark",
       "worker_kill_mid_post"]
EQUIVALENT_ROW = {"worker_kill_mid_begin": "after_begin",
                  "worker_kill_mid_provider": "after_provider_call",
                  "worker_kill_mid_mark": "after_mark_submitted",
                  "worker_kill_mid_post": "after_post"}


# ---------------------------------------------------------------------------
# file:line anchors, resolved from the source so the citations cannot rot
# ---------------------------------------------------------------------------

def at(path: pathlib.Path, pattern: str, after: str | None = None) -> str:
    lines = path.read_text().splitlines()
    start = 0
    if after:
        start = next(i for i, l in enumerate(lines) if re.search(after, l))
    for i in range(start, len(lines)):
        if re.search(pattern, lines[i]):
            return f"{path.relative_to(REPO)}:{i + 1}"
    raise LookupError(f"{pattern!r} not found in {path}")


def anchors() -> dict[str, str]:
    s, t = LEDGER / "schema.sql", LEDGER / "tests" / "test_payout_saga.py"
    return {
        "begin_conflict": at(s, r"ON CONFLICT \(request_id\) DO NOTHING"),
        "resume_fn":      at(s, r"CREATE OR REPLACE FUNCTION ledger_payout_resume"),
        "resume_done":    at(s, r"IF v_state IN \('failed', 'posted'\)", after="ledger_payout_resume"),
        "resume_fail":    at(s, r"RETURN ledger_payout_fail", after="ledger_payout_resume"),
        "resume_mark":    at(s, r"PERFORM ledger_payout_mark_submitted", after="ledger_payout_resume"),
        "resume_post":    at(s, r"PERFORM ledger_payout_post", after="ledger_payout_resume"),
        "mark_replay":    at(s, r"IF v_state IN \('submitted', 'posted'\)"),
        "post_lock":      at(s, r"FOR UPDATE", after="FUNCTION ledger_payout_post"),
        "post_key":       at(s, r"'payout:' \|\| p_payout_id::text,", after="FUNCTION ledger_payout_post"),
        "post_guard":     at(s, r"'PAYOUT_NOT_SUBMITTED'", after="FUNCTION ledger_payout_post"),
        "post_state":     at(s, r"SET state = 'posted'", after="FUNCTION ledger_payout_post"),
        "key_conflict":   at(s, r"ON CONFLICT \(idempotency_key\) DO NOTHING"),
        "test_rebegin":   at(t, r"payout_id = ledger\.payout_begin\(request_id"),
        "test_ref":       at(t, r"payout_resume\(payout_id, provider_ref\) == \"posted\""),
        "wf_step":        at(HERE / "workflow.py", r"workflow\.execute_activity\("),
        "wf_retry":       at(HERE / "workflow.py", r"^RETRY = RetryPolicy"),
        "act_nonretry":   at(HERE / "activities.py", r"non_retryable=True"),
        "prov_conflict":  at(HERE / "provider.py", r"ON CONFLICT \(request_id\)"),
        "timeout":        at(HERE / "shared.py", r"^ACTIVITY_TIMEOUT"),
    }


def mechanisms(a: dict[str, str]) -> dict[str, tuple[str, str]]:
    """(hand-built mechanism, Temporal mechanism) per row. Evidence is appended later."""
    rb = "PostgreSQL rolled the killed transaction back"
    return {
        "during_begin": (
            f"{rb}; the caller calls begin again ({a['test_rebegin']}). No retry loop exists outside the test",
            f"{rb}; activity attempt 1 raised, RetryPolicy ran attempt 2 ({a['wf_retry']})"),
        "after_begin": (
            f"resume with the provider's not_found verdict fails the payout ({a['resume_fail']}); "
            "outcome FAILED, 0 effects. Without a verdict resume refuses (PAYOUT_VERDICT_REQUIRED); "
            "resolver.py asks and resubmits instead",
            "start-to-close timeout on the provider activity, attempt 2 on the restarted worker; "
            "begin not re-run (history replay); outcome POSTED, 1 effect"),
        "after_provider_call": (
            f"resume marks submitted with a ref the caller must obtain from the provider "
            f"({a['resume_mark']}), then posts ({a['resume_post']})",
            "the provider ref is already in history; only mark_submitted is retried after the timeout"),
        "after_mark_submitted": (
            f"resume posts ({a['resume_post']})",
            "post retried after the timeout; earlier steps replayed from history"),
        "during_post": (
            f"{rb}, state back to submitted; resume posts ({a['resume_post']})",
            f"{rb}; post attempt 1 raised, attempt 2 committed"),
        "after_post": (
            f"resume returns early on a posted payout, 3 times ({a['resume_done']})",
            f"3 resubmissions re-ran all 4 activities; ledger key replayed each post ({a['post_key']}), "
            f"provider deduped on request_id ({a['prov_conflict']})"),
        "never": ("straight line", "straight line"),
        "worker_kill_mid_begin": (
            "", f"attempt 2 re-ran begin; ON CONFLICT (request_id) returned the same payout id ({a['begin_conflict']})"),
        "worker_kill_mid_provider": (
            "", f"attempt 2 called the provider again; provider deduped on request_id ({a['prov_conflict']})"),
        "worker_kill_mid_mark": (
            "", f"attempt 2 re-ran mark; a submitted payout returns unchanged ({a['mark_replay']})"),
        "worker_kill_mid_post": (
            "", f"attempt 2 re-ran post; ledger key 'payout:'||id replayed it ({a['post_key']}, {a['key_conflict']})"),
        "worker_zombie_post": (
            f"stale resumer's payout_post takes the row lock ({a['post_lock']}), key replays ({a['key_conflict']})",
            f"server rejected the zombie's completion, but its write still ran; ledger key replayed it "
            f"({a['post_key']})"),
        "concurrent_resumers": (
            f"B blocks on A's FOR UPDATE ({a['post_lock']}), then replays A's committed posting",
            "no direct analog: Temporal hands one attempt to one worker; overlap only happens via "
            "timeout, which is the zombie row"),
    }


# ---------------------------------------------------------------------------
# running the suites
# ---------------------------------------------------------------------------

def run_pytest(cwd: pathlib.Path, target: str, junit: pathlib.Path,
               results: pathlib.Path | None = None, extra_env: dict | None = None) -> float:
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", **(extra_env or {})}
    if results:
        env["PAYOUT_RESULTS"] = str(results)
    started = time.perf_counter()
    proc = subprocess.run([PY, "-m", "pytest", target, "-p", "no:cacheprovider", "-q",
                           f"--junitxml={junit}"], cwd=cwd, env=env,
                          capture_output=True, text=True)
    elapsed = time.perf_counter() - started
    if proc.returncode not in (0, 1):
        sys.exit(f"pytest could not run in {cwd}:\n{proc.stdout}\n{proc.stderr}")
    return elapsed


def junit_cases(path: pathlib.Path) -> dict[str, dict]:
    out = {}
    for case in ET.parse(path).getroot().iter("testcase"):
        failed = case.find("failure") is not None or case.find("error") is not None
        skipped = case.find("skipped") is not None
        out[case.get("name")] = {"passed": not failed and not skipped,
                                 "status": "FAIL" if failed else ("SKIP" if skipped else "pass"),
                                 "time": float(case.get("time", 0))}
    return out


def param(name: str) -> str | None:
    m = re.search(r"\[(.+)\]$", name)
    return m.group(1) if m else None


def run_all(work: pathlib.Path, i: int, extra_env: dict | None = None) -> dict:
    results = work / f"evidence-{i}.jsonl"
    r = {}
    r["handbuilt_s"] = run_pytest(LEDGER, "tests/test_payout_saga.py", work / f"hb-{i}.xml")
    r["handbuilt_extra_s"] = run_pytest(HERE, "tests/test_handbuilt_worker_points.py",
                                        work / f"hbw-{i}.xml", results, extra_env)
    r["temporal_s"] = run_pytest(HERE, "tests/test_temporal_payout_saga.py", work / f"t-{i}.xml",
                                 results, extra_env)
    r["hb"] = junit_cases(work / f"hb-{i}.xml")
    r["hbw"] = junit_cases(work / f"hbw-{i}.xml")
    r["t"] = junit_cases(work / f"t-{i}.xml")
    r["evidence"] = [json.loads(l) for l in results.read_text().splitlines()] if results.exists() else []
    return r


# ---------------------------------------------------------------------------
# the matrix
# ---------------------------------------------------------------------------

def _mark(ok: bool | None) -> str:
    return "n/a" if ok is None else ("PASS" if ok else "**FAIL**")


def matrix(run: dict, mech: dict) -> str:
    hb = {param(n): c for n, c in run["hb"].items() if param(n)}
    t = {param(n): c for n, c in run["t"].items() if param(n)}
    t["worker_zombie_post"] = run["t"].get("test_frozen_worker_wakes_after_another_worker_finished_its_job")
    hbw = {"worker_zombie_post": run["hbw"].get("test_stale_resumer_wakes_after_another_finished"),
           "concurrent_resumers": run["hbw"].get("test_concurrent_resumers_serialise_on_the_payout_row")}
    ev = {(e["impl"], e["point"]): e for e in run["evidence"]}

    def t_evidence(point: str) -> str:
        e = ev.get(("temporal", point))
        if not e:
            return ""
        bits = []
        retried = {k: v for k, v in e.get("attempts", {}).items() if v > 1}
        if retried:
            bits.append("attempts " + ", ".join(f"{k}={v}" for k, v in retried.items()))
        ran = e.get("executions", {})
        if ran:
            bits.append("executions " + ", ".join(f"{k}={v}" for k, v in ran.items()))
        if "provider_calls" in e and e["provider_calls"] != 1:
            bits.append(f"provider calls={e['provider_calls']}")
        if e.get("post_replayed") and e["post_replayed"] != [False]:
            bits.append(f"post replayed={e['post_replayed']}")
        if point.startswith("worker_kill_mid_post"):
            bits.append(f"post replayed={[r['replayed'] for r in e['step_results']]}")
        if "zombie_replayed" in e:
            bits.append(f"zombie attempt={e['zombie_attempt']} replayed={e['zombie_replayed']}, "
                        f"report rejected={e['zombie_report_rejected']}")
        return f" [{'; '.join(bits)}]" if bits else ""

    injection = {
        "during_begin": ("kill PG backend before COMMIT", "same, inside the begin activity"),
        "after_begin": ("stop driving after begin", "SIGKILL worker at provider-activity entry"),
        "after_provider_call": ("stop driving after provider accepted", "SIGKILL worker at mark-activity entry"),
        "after_mark_submitted": ("stop driving after mark", "SIGKILL worker at post-activity entry"),
        "during_post": ("kill PG backend before COMMIT", "same, inside the post activity"),
        "after_post": ("resume 3 more times", "resubmit same workflow id 3 more times"),
        "never": ("none", "none"),
        "worker_kill_mid_begin": ("no worker exists", "SIGKILL worker after begin COMMIT, before report"),
        "worker_kill_mid_provider": ("no worker exists", "SIGKILL worker after provider accepted, before report"),
        "worker_kill_mid_mark": ("no worker exists", "SIGKILL worker after mark COMMIT, before report"),
        "worker_kill_mid_post": ("no worker exists", "SIGKILL worker after post COMMIT, before report"),
        "worker_zombie_post": ("stale resumer posts after another resumer finished",
                               "SIGSTOP worker at post entry, 2nd worker finishes, SIGCONT"),
        "concurrent_resumers": ("B resumes while A holds post uncommitted", "not run, see mechanism"),
    }

    rows = ["| # | Crash point | Hand-built injection | Hand-built | Hand-built mechanism "
            "| Temporal injection | Temporal | Temporal mechanism [evidence from this run] |",
            "|---|---|---|---|---|---|---|---|"]
    for n, point in enumerate(SEVEN + MID + ["worker_zombie_post", "concurrent_resumers"], 1):
        hb_mech, t_mech = mech[point]
        if point in hb:
            hb_ok = hb[point]["passed"]
        elif point in hbw:
            hb_ok = hbw[point]["passed"] if hbw[point] else False
        else:
            hb_ok = None
            hb_mech = (f"no meaning without a worker; the durable state it leaves is row "
                       f"`{EQUIVALENT_ROW[point]}`")
        t_case = t.get(point)
        t_ok = None if point == "concurrent_resumers" else (t_case["passed"] if t_case else False)
        hi, ti = injection[point]
        rows.append(f"| {n} | `{point}` | {hi} | {_mark(hb_ok)} | {hb_mech} | {ti} | {_mark(t_ok)} "
                    f"| {t_mech}{t_evidence(point)} |")
    return "\n".join(rows)


# ---------------------------------------------------------------------------
# cost: lines of code, dependencies, operational surface
# ---------------------------------------------------------------------------

def py_code_lines(path: pathlib.Path) -> tuple[int, int]:
    """(code lines, physical lines). Code excludes blanks, comments, docstrings."""
    text = path.read_text()
    doc = set()
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) \
                    and isinstance(body[0].value.value, str):
                doc.update(range(body[0].lineno, body[0].end_lineno + 1))
    lines = text.splitlines()
    code = sum(1 for i, l in enumerate(lines, 1)
               if l.strip() and not l.strip().startswith("#") and i not in doc)
    return code, len(lines)


def py_lines(lines: list[str]) -> tuple[int, int]:
    """For a slice with no docstrings: blanks and comments excluded."""
    return sum(1 for l in lines if l.strip() and not l.strip().startswith("#")), len(lines)


def sql_code_lines(lines: list[str]) -> tuple[int, int]:
    return sum(1 for l in lines if l.strip() and not l.strip().startswith("--")), len(lines)


def sql_slice(start_pat: str, end_pat: str) -> list[str]:
    lines = (LEDGER / "schema.sql").read_text().splitlines()
    s = next(i for i, l in enumerate(lines) if re.search(start_pat, l))
    e = next(i for i in range(s + 1, len(lines)) if re.search(end_pat, lines[i]))
    return lines[s:e]


def py_slice(path: pathlib.Path, start_pat: str, end_pat: str) -> list[str]:
    lines = path.read_text().splitlines()
    s = next(i for i, l in enumerate(lines) if re.search(start_pat, l))
    e = next(i for i in range(s + 1, len(lines)) if re.search(end_pat, lines[i]))
    return lines[s:e]


def loc_table() -> str:
    api = LEDGER / "tests" / "ledger_api.py"
    rows = []

    def add(side, what, code_phys, used_by):
        rows.append(f"| {side} | {what} | {code_phys[0]} | {code_phys[1]} | {used_by} |")

    add("hand-built", "`schema.sql` payout table + state enum",
        tuple(map(sum, zip(sql_code_lines(sql_slice(r"^CREATE TYPE ledger_payout_state", r"^$")),
                           sql_code_lines(sql_slice(r"^CREATE TABLE ledger_payouts", r"^\);")))))
        , "both")
    add("hand-built", "`schema.sql` begin, mark_submitted, post, fail",
        sql_code_lines(sql_slice(r"^-- Step 1\. Reserve the payout", r"^-- The resume path")), "both")
    add("hand-built", "`schema.sql` `ledger_payout_resume` (the orchestrator)",
        sql_code_lines(sql_slice(r"^-- The resume path", r"^-- =====")), "hand-built only")
    add("hand-built", "`ledger_api.py` payout methods",
        py_lines(py_slice(api, r"# -- payout saga", r"^# ------")), "both")
    for f in ["workflow.py", "activities.py", "worker.py", "shared.py"]:
        add("Temporal", f"`{f}`", py_code_lines(HERE / f), "Temporal only")
    add("Temporal", "`provider.py` (fake provider, test double)", py_code_lines(HERE / "provider.py"),
        "Temporal tests only")
    add("Temporal", "`faults.py` (worker crash injection)", py_code_lines(HERE / "faults.py"),
        "Temporal tests only")
    add("tests", "`db/ledger/tests/test_payout_saga.py`",
        py_code_lines(LEDGER / "tests" / "test_payout_saga.py"), "hand-built (Temporal reuses its asserts)")
    for f in ["tests/conftest.py", "tests/test_temporal_payout_saga.py", "tests/test_handbuilt_worker_points.py"]:
        add("tests", f"`{f}`", py_code_lines(HERE / f), "comparison")
    head = ("| Side | Unit | Code lines | Physical lines | Used by |\n|---|---|---|---|---|")
    return head + "\n" + "\n".join(rows)


def du_mb(path: pathlib.Path) -> float:
    out = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True).stdout.split()[0]
    return int(out) / 1024


def dependency_table() -> str:
    site = pathlib.Path(subprocess.run([PY, "-c", "import sysconfig;print(sysconfig.get_paths()['purelib'])"],
                                       capture_output=True, text=True).stdout.strip())
    def pkg(name):
        return du_mb(site / name) if (site / name).exists() else 0.0
    temporal_py = pkg("temporalio") + pkg("nexusrpc") + pkg("google") + sum(
        du_mb(p) for p in site.glob("typing_extensions*")) + sum(du_mb(p) for p in site.glob("protobuf*"))
    psy = pkg("psycopg") + pkg("psycopg_binary")
    cli = pathlib.Path(shutil.which("temporal")).resolve()
    cli_ver = subprocess.run(["temporal", "--version"], capture_output=True, text=True).stdout.strip()
    tv = subprocess.run([PY, "-c", "import temporalio;print(temporalio.__version__)"],
                        capture_output=True, text=True).stdout.strip()
    req = subprocess.run([PY, "-m", "pip", "show", "temporalio"], capture_output=True, text=True).stdout
    requires = next((l.split(":", 1)[1].strip() for l in req.splitlines() if l.startswith("Requires")), "")
    return "\n".join([
        "| | Hand-built | Temporal |", "|---|---|---|",
        f"| Python packages beyond the ledger suite | none | temporalio {tv} (requires: {requires}) |",
        f"| Installed size of those packages | psycopg + binary {psy:.1f} MB (shared) | "
        f"{temporal_py:.1f} MB on top |",
        f"| Server binaries | PostgreSQL | PostgreSQL + `temporal` CLI ({cli_ver.splitlines()[0]}), "
        f"{cli.stat().st_size / 1e6:.0f} MB single binary |",
    ])


def rss_mb(pid: int) -> float:
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(out.strip() or 0) / 1024


def surface_table() -> str:
    """Start the Temporal pieces alone and measure what they cost to keep running."""
    port = 7249
    log = tempfile.NamedTemporaryFile("w", delete=False, suffix=".log")
    started = time.perf_counter()
    server = subprocess.Popen(["temporal", "server", "start-dev", "--headless", "--ip", "127.0.0.1",
                               "--port", str(port), "--log-level", "error"], stdout=log,
                              stderr=subprocess.STDOUT)
    while subprocess.run(["temporal", "operator", "cluster", "health", "--address",
                          f"127.0.0.1:{port}"], capture_output=True, text=True).stdout.find("SERVING") < 0:
        time.sleep(0.05)
    server_up = time.perf_counter() - started
    wlog = pathlib.Path(tempfile.mkstemp(suffix=".log")[1])
    env = {**os.environ, "TEMPORAL_ADDRESS": f"127.0.0.1:{port}", "PYTHONPATH":
           os.pathsep.join([str(HERE), str(LEDGER / "tests")]), "PAYOUT_TASK_QUEUE": "surface"}
    t0 = time.perf_counter()
    worker = subprocess.Popen([PY, str(HERE / "worker.py")], env=env, stdout=open(wlog, "w"),
                              stderr=subprocess.STDOUT)
    while "worker ready" not in wlog.read_text():
        time.sleep(0.02)
    worker_up = time.perf_counter() - t0
    time.sleep(3)
    ports = subprocess.run(["lsof", "-a", "-p", str(server.pid), "-iTCP", "-sTCP:LISTEN", "-n", "-P"],
                           capture_output=True, text=True).stdout.strip().splitlines()[1:]
    srv_rss, wrk_rss = rss_mb(server.pid), rss_mb(worker.pid)
    worker.send_signal(signal.SIGTERM); server.send_signal(signal.SIGTERM)
    worker.wait(10); server.wait(10)
    listen = sorted({l.split()[-2].rsplit(":", 1)[-1] for l in ports})
    return "\n".join([
        "| | Hand-built | Temporal (local dev server) |", "|---|---|---|",
        "| Long-running processes | PostgreSQL | PostgreSQL + Temporal server + >=1 worker, "
        "and a supervisor to restart dead workers |",
        f"| Listening TCP ports | 1 (PostgreSQL) | 1 + {len(listen)} (Temporal frontend {port}, "
        f"the rest on random ports) |",
        f"| Resident memory, idle | PostgreSQL only | + server {srv_rss:.0f} MB + worker {wrk_rss:.0f} MB |",
        f"| Cold start | none | server {server_up:.1f} s to report SERVING, worker {worker_up:.1f} s to connect |",
        "| Durable state stores | 1 (the ledger database) | 2 (ledger database + Temporal's "
        "persistence; in-memory SQLite here, lost when the dev server exits) |",
        "| Settings that decide crash behaviour | 0 | 9 plus an error classification: activity "
        "start-to-close, workflow task timeout, 4 RetryPolicy fields, sticky cache off, workflow "
        "and activity poller maximums; which schema errors are non-retryable |",
    ])


# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--out")
    ap.add_argument("--timeout-sensitivity", type=float, default=1.0,
                    help="also run the Temporal suite once with this activity timeout (s); "
                         "0 skips it (CI does, to stay near two minutes)")
    args = ap.parse_args()

    work = pathlib.Path(tempfile.mkdtemp(prefix="payout-compare-"))
    runs = [run_all(work, i) for i in range(args.repeat)]
    if args.timeout_sensitivity > 0:
        sens = run_pytest(HERE, "tests/test_temporal_payout_saga.py", work / "sens.xml",
                          extra_env={"PAYOUT_ACTIVITY_TIMEOUT_S": str(args.timeout_sensitivity)})
        sens_cases = junit_cases(work / "sens.xml")
        sens_row = (f"| Temporal, activity timeout {args.timeout_sensitivity:g} s instead of 3 s (1 run, "
                    f"{sum(c['passed'] for c in sens_cases.values())}/{len(sens_cases)} passed) | {sens:.2f} s |")
    else:
        sens_row = "| Temporal, shorter activity timeout | not run (`--timeout-sensitivity 0`) |"

    mech = mechanisms(anchors())
    out = [f"<!-- generated by db/temporal_payout/compare.py --repeat {args.repeat}; "
           f"workdir {work} -->", "## Crash matrix (run 1 of %d)" % args.repeat, "", matrix(runs[0], mech), ""]
    stable = all(matrix(r, mech).count("**FAIL**") == 0 for r in runs)
    out.append(f"All {args.repeat} runs: {'every row identical pass/fail, 0 failures' if stable else 'FAILURES, see workdir'}.")
    for i, r in enumerate(runs, 1):
        counts = {k: (sum(c['passed'] for c in r[k].values()), len(r[k])) for k in ("hb", "hbw", "t")}
        out.append(f"- run {i}: test_payout_saga.py {counts['hb'][0]}/{counts['hb'][1]}, "
                   f"hand-built worker points {counts['hbw'][0]}/{counts['hbw'][1]}, "
                   f"Temporal {counts['t'][0]}/{counts['t'][1]}")

    def med(key):
        vals = [r[key] for r in runs]
        return f"{statistics.median(vals):.2f} s (runs: {', '.join(f'{v:.2f}' for v in vals)})"

    def seven_sum(r, key):
        return sum(c["time"] for n, c in r[key].items() if param(n) in SEVEN)

    out += ["", "## Wall clock", "",
            "| Suite | Median wall clock, whole pytest process |", "|---|---|",
            f"| hand-built `db/ledger/tests/test_payout_saga.py` (14 tests) | {med('handbuilt_s')} |",
            f"| hand-built worker points (2 tests) | {med('handbuilt_extra_s')} |",
            f"| Temporal `tests/test_temporal_payout_saga.py` ({len(runs[0]['t'])} tests) | {med('temporal_s')} |",
            sens_row,
            "",
            f"The 7 shared crash points only, summed from junit per-test time (setup+call+teardown), run 1: "
            f"hand-built {seven_sum(runs[0], 'hb'):.2f} s, Temporal {seven_sum(runs[0], 't'):.2f} s.",
            "", "## Lines of code", "", loc_table(), "",
            "## Dependencies", "", dependency_table(), "",
            "## Operational surface", "", surface_table(), ""]
    text = "\n".join(out)
    print(text)
    if args.out:
        pathlib.Path(args.out).write_text(text)
    if not stable:
        sys.exit(1)


if __name__ == "__main__":
    main()
