#!/usr/bin/env python3
"""XACA-1786-001: generate the ticket-lamp lane fixture FROM THE WRITER, not by hand.

A fixture an author invents is a vacuous green (XACA-1549 lost two gate rounds to one: it invented `status: "in_review"`).
This script builds throw-away boards in a temp dir and drives the REAL writer, kanban-hooks/release_orchestrator.py
(start_run, assign_lane, record_state, write_tokens, close_run, write_summary), then runs the REAL RELEASE_FILTER (taken
verbatim from hooks/register.tsx) with real jq over each board. It writes:

    tests/lanes.fixture.json   the canonical data
    tests/lanes.fixture.ts     the same data as a module (a mod's tests cannot import .json), loaded by lanes.test.tsx

tests/test_xaca1786_lanes_fixture.py regenerates both and fails when they differ from the committed files, so a change to
the writer, to the XACA-1808 token contract or to the jq filter breaks the suite until this is re-run:

    /opt/homebrew/bin/python3 claude-mods/ticket-lamp/tests/gen_lanes_fixture.py          # rewrite
    /opt/homebrew/bin/python3 claude-mods/ticket-lamp/tests/gen_lanes_fixture.py --check  # exit 1 when stale

DETERMINISM: every writer call takes an injected `now=` (the writers' own clock parameter), so run ids and every `since`
stamp are fixed. Scratch boards live in a temp dir and are never the real kanban board. Needs jq.
"""
import datetime
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "kanban-hooks"))
import orchestrator_state as ostate  # noqa: E402
import release_orchestrator as ro  # noqa: E402

REGISTER = HERE.parent / "hooks" / "register.tsx"
TOKEN_CONTRACT = ROOT / "tests" / "fixtures" / "xaca-1808" / "orchestration-tokens.contract.json"
OUT_JSON = HERE / "lanes.fixture.json"
OUT_TS = HERE / "lanes.fixture.ts"

REL = "REL-2026-Q4-070"
T0 = datetime.datetime(2026, 11, 13, 19, 38, 0, tzinfo=datetime.timezone.utc)


def at(seconds):
    return T0 + datetime.timedelta(seconds=seconds)


def sub(n, status, item):
    return {"id": "%s-%03d" % (item, n), "title": "Subitem %d" % n, "status": status}


def item(iid, title, subs):
    return {"id": iid, "title": title, "status": "in_progress", "releaseAssignment": {"releaseId": REL},
            "subitems": [sub(i + 1, s, iid) for i, s in enumerate(subs)]}


BACKLOG = [
    item("XACA-9001", "Lane one ticket: wire the gates", ["completed", "completed", "cancelled", "in_progress", "todo"]),
    item("XACA-9002", "Lane two ticket: ask a question", ["completed", "todo", "todo"]),
    item("XACA-9003", "Queued ticket behind lane one", ["todo"]),
    item("XACA-9004", "Queued ticket behind lane two", ["todo"]),
    item("XACA-9005", "Third lane ticket", ["todo", "todo"]),
    item("XACA-0000", "Ticket named in the XACA-1808 contract", ["completed", "todo"]),
]
PLAN = {"waves": [{"wave": 1, "items": [{"id": "XACA-9001"}, {"id": "XACA-9002"}, {"id": "XACA-9005"}]},
                  {"wave": 2, "items": [{"id": "XACA-9003"}, {"id": "XACA-9004"}]}]}


def block(model, inp, cc, cr, out, turns):
    return {"model": model, "input": inp, "cacheCreate": cc, "cacheRead": cr, "output": out, "turns": turns}


def contract_tokens():
    """The XACA-1808 contract file, minus its `_comment`."""
    data = json.loads(TOKEN_CONTRACT.read_text())
    data.pop("_comment", None)
    return data


def read_filter():
    """RELEASE_FILTER exactly as jq receives it: the template literal in register.tsx, with `\\\\` un-escaped."""
    text = REGISTER.read_text()
    m = re.search(r"const RELEASE_FILTER = `(.*?)`\n", text, re.S)
    if not m:
        raise SystemExit("gen_lanes_fixture: RELEASE_FILTER not found in %s" % REGISTER)
    return m.group(1).replace("\\\\", "\\")


class Scenario:
    def __init__(self, tmp, name, maxp, plan=PLAN, backlog=None):
        self.kd = Path(tmp) / name
        self.kd.mkdir()
        self.bf = self.kd / "academy-board.json"
        self.bf.write_text(json.dumps({"backlog": backlog if backlog is not None else BACKLOG, "releases": [{"id": REL}]}))
        self.run = ro.start_run(str(self.bf), str(self.kd), REL, plan, "academy:picard", maxp, now=at(0)) if maxp else None
        self.t = 0

    def tick(self):
        self.t += 10
        return at(self.t)

    def assign(self, iid, lane=None):
        return ro.assign_lane(str(self.bf), str(self.kd), REL, self.run, iid, lane=lane, now=self.tick())

    def state(self, iid, to, **kw):
        ro.record_state(str(self.bf), str(self.kd), REL, self.run, iid, to, now=self.tick(), **kw)

    def tokens(self, tokens):
        ro.write_tokens(str(self.bf), REL, self.run, tokens)

    def mutate(self, fn):
        """Synthetic corruption only (a shape the writer never produces), through the writer's own locked write path."""
        ro.write_summary(str(self.bf), REL, fn)

    def rerun(self, maxp, plan=PLAN):
        """A RE-RUN through the real start_run: close the active run first (start_run refuses otherwise). The writer keeps every
        occupied lane and drops only the empty lanes above the new max, which is how an occupied lane ends up above maxParallel."""
        self.close()
        self.run = ro.start_run(str(self.bf), str(self.kd), REL, plan, "academy:picard", maxp, now=self.tick())

    def close(self):
        ro.close_run(str(self.bf), str(self.kd), REL, self.run, now=self.tick())

    def orchestration(self):
        return json.loads(self.bf.read_text())["releases"][0].get("orchestration")


def build_scenarios(tmp):
    out = {}

    def put(name, sc, note, synthetic=False):
        out[name] = {"note": note, "synthetic": synthetic, "orchestration": sc.orchestration(), "board": str(sc.bf)}

    # 1. The headline shape: maxParallel 2, lane 1 in review with a PR, lane 2 waiting on an answer, a queue behind each.
    s = Scenario(tmp, "two_lanes", 2)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.state("XACA-9001", "RUNNING")
    s.state("XACA-9001", "IN_REVIEW", prNumber=1320)
    s.state("XACA-9002", "QUESTION_PENDING")
    s.tokens({"run": block("claude-fable-5-2", 1300, 210000, 1010000, 5400, 40),
              "perItem": {"XACA-9001": block("claude-fable-5-2", 1200, 200000, 1000000, 5000, 30)},
              "coordinator": block(None, 0, 0, 0, 0, 0), "updatedAt": "2026-11-13T19:38:00.000Z",
              "complete": True, "unattributed": 0, "modelMismatch": []})
    put("two_lanes", s, "maxParallel 2: lane 1 IN_REVIEW with PR #1320 and tokens, lane 2 QUESTION_PENDING with no tokens entry, queued tickets dealt round-robin behind both lanes")

    # 2. Coding and merged.
    s = Scenario(tmp, "coding_merged", 2)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.state("XACA-9001", "RUNNING")
    s.state("XACA-9002", "MERGED_PENDING_DONE", prNumber=1321)
    put("coding_merged", s, "lane 1 RUNNING (coding), lane 2 MERGED_PENDING_DONE")

    # 3. Dead-ish states keep their lane.
    s = Scenario(tmp, "stalled_crashed_failed", 3)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.assign("XACA-9005")
    s.state("XACA-9001", "STALLED")
    s.state("XACA-9002", "CRASHED")
    s.state("XACA-9005", "FAILED")
    put("stalled_crashed_failed", s, "maxParallel 3: STALLED, CRASHED and FAILED all keep their lanes (current stays set)")

    # 4. A freed lane: DONE nulls `current`, the lane number stays, the ticket is in `finished`.
    s = Scenario(tmp, "freed_lane", 2)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.state("XACA-9001", "RUNNING")
    s.state("XACA-9001", "DONE")
    s.state("XACA-9002", "RUNNING")
    s.tokens({"run": block("claude-fable-5-2", 20, 200, 2000, 10, 4),
              "perItem": {"XACA-9001": block("claude-fable-5-2", 10, 100, 1000, 5, 2),
                          "XACA-9002": block("claude-fable-5-2", 10, 100, 1000, 5, 2)},
              "coordinator": block(None, 0, 0, 0, 0, 0), "updatedAt": "2026-11-13T19:38:00.000Z",
              "complete": True, "unattributed": 0, "modelMismatch": []})
    put("freed_lane", s, "lane 1 freed after DONE (current null, queue still dealt), lane 2 RUNNING; XACA-9001 in finished with tokens")

    # 5. Closed run: no lane lines.
    s = Scenario(tmp, "closed_run", 2)
    s.assign("XACA-9001")
    s.state("XACA-9001", "DONE")
    s.close()
    put("closed_run", s, "run closed (closedAt set): runActive false, no lanes")

    # 6. No orchestration at all.
    s = Scenario(tmp, "no_orchestration", 0)
    put("no_orchestration", s, "a release that never ran orchestrated")

    # 7. XACA-1808 contract block, verbatim.
    s = Scenario(tmp, "contract_tokens", 1, plan={"waves": [{"wave": 1, "items": [{"id": "XACA-0000"}]}]})
    s.assign("XACA-0000")
    s.state("XACA-0000", "RUNNING")
    s.tokens(contract_tokens())
    put("contract_tokens", s, "tokens = the XACA-1808 contract file verbatim (minus _comment); lane item is XACA-0000")

    # 8. maxParallel SHRANK below an occupied lane, produced by the REAL writer (a re-run with a smaller max_parallel). The
    # writer keeps occupied lanes above the max ("a human decides"), and the lamp must draw every one of them. Rows are listed in
    # tests/test_xaca1786_lanes_fixture.py and hooks/lanes.test.tsx as (lane number, ticket id) and asserted at every layer.
    s = Scenario(tmp, "over_cap", 2)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.state("XACA-9001", "RUNNING")
    s.state("XACA-9002", "RUNNING")
    s.rerun(1)
    put("over_cap", s, "re-run with maxParallel 1 while lanes 1 and 2 are both occupied: the writer keeps both and the lamp draws both")

    s = Scenario(tmp, "shrunk_all_occupied", 3)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.assign("XACA-9005")
    for iid in ("XACA-9001", "XACA-9002", "XACA-9005"):
        s.state(iid, "RUNNING")
    s.rerun(2)
    put("shrunk_all_occupied", s, "re-run with maxParallel 3 -> 2, all three lanes occupied: all three are drawn")

    # An occupied dead lane above the max, empty lanes below it (the reviewer's reproduction), once per dead state.
    for dead in ("STALLED", "CRASHED", "FAILED"):
        s = Scenario(tmp, "overcap_%s" % dead.lower(), 3)
        s.assign("XACA-9001")
        s.assign("XACA-9002")
        s.assign("XACA-9005")
        s.state("XACA-9001", "DONE")
        s.state("XACA-9002", "DONE")
        s.state("XACA-9005", dead)
        s.rerun(2)
        put("overcap_%s" % dead.lower(), s,
            "re-run with maxParallel 3 -> 2: lanes 1 and 2 freed (empty), lane 3 holds a %s ticket: it keeps lane 3 and must be drawn" % dead)

    # A lane-number GAP the writer really produces: maxParallel 4 -> 2 with only lane 4 occupied leaves lanes 1, 2 and 4.
    s = Scenario(tmp, "lane_gap", 4)
    s.assign("XACA-9001", lane=4)
    s.state("XACA-9001", "RUNNING")
    s.rerun(2)
    put("lane_gap", s, "re-run with maxParallel 4 -> 2, only lane 4 occupied: lanes 1, 2 and 4 exist (no lane 3)")

    # Shapes the writer never writes (its lanes always start at 1 and carry no duplicates), so they are SYNTHETIC.
    s = Scenario(tmp, "lane_gap_missing_first", 3)
    s.assign("XACA-9001", lane=2)
    s.state("XACA-9001", "RUNNING")
    def drop_lane_one(o):    # a mutator must return None (a returned value REPLACES the whole orchestration block)
        o["maxParallel"] = 2
        o["lanes"] = [lane for lane in o["lanes"] if lane["lane"] != 1]

    s.mutate(drop_lane_one)
    put("lane_gap_missing_first", s, "lane 1 missing, lane 2 occupied, empty lane 3 above maxParallel 2", synthetic=True)

    s = Scenario(tmp, "empty_above_max_dropped", 3)
    s.assign("XACA-9001")
    s.state("XACA-9001", "RUNNING")
    s.mutate(lambda o: o.update({"maxParallel": 1}))
    put("empty_above_max_dropped", s, "NEGATIVE CONTROL: lanes 2 and 3 are EMPTY and above maxParallel 1, so they are dropped", synthetic=True)

    s = Scenario(tmp, "empty_above_max_beside_occupied", 4)
    s.assign("XACA-9001", lane=4)
    s.state("XACA-9001", "STALLED")
    s.mutate(lambda o: o.update({"maxParallel": 2}))
    put("empty_above_max_beside_occupied", s,
        "NEGATIVE CONTROL: empty lane 3 above maxParallel 2 is dropped while occupied lane 4 beside it is kept", synthetic=True)

    # The jq pass sorts by lane number and keeps the FIRST of a duplicate number (the writer's own by_no.setdefault rule).
    s = Scenario(tmp, "lanes_duplicate_no", 2)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    def add_second_lane_one(o):
        o["lanes"].append({"lane": 1, "since": o["lanes"][0]["since"], "queue": [],
                           "current": {"id": "XACA-9005", "status": "RUNNING", "stage": "coding", "prNumber": None}})

    s.mutate(add_second_lane_one)
    put("lanes_duplicate_no", s, "a second entry numbered lane 1 (the first wins, as in the writer): lines are L1 XACA-9001 and L2 XACA-9002", synthetic=True)

    s = Scenario(tmp, "lanes_out_of_order", 2)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.mutate(lambda o: o["lanes"].reverse())
    put("lanes_out_of_order", s, "lanes stored as [lane 2, lane 1]: drawn in lane-number order", synthetic=True)

    # /ticket "open tickets" de-dupe: every open ticket of the release is already a lane's current or in a queue.
    s = Scenario(tmp, "all_open_in_run", 2, backlog=BACKLOG[:5])
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.state("XACA-9001", "RUNNING")
    s.state("XACA-9002", "RUNNING")
    put("all_open_in_run", s, "the release's 5 open tickets are all in lane currents or queues")

    # 9. Malformed shapes the writer never writes; the reader must fail towards "?" / no lines.
    s = Scenario(tmp, "lanes_not_array", 2)
    s.mutate(lambda o: o.update({"lanes": "oops"}))
    put("lanes_not_array", s, "lanes is a string", synthetic=True)

    s = Scenario(tmp, "unknown_stage", 2)
    s.assign("XACA-9001")
    s.mutate(lambda o: o["lanes"][0]["current"].update({"status": "WARP_CORE_BREACH", "stage": "teleporting"}))
    put("unknown_stage", s, "an unrecognised status and stage", synthetic=True)

    s = Scenario(tmp, "missing_current", 2)
    def drop_current(o):
        for lane in o["lanes"]:
            lane.pop("current", None)

    s.mutate(drop_current)
    put("missing_current", s, "lanes without a `current` key", synthetic=True)

    s = Scenario(tmp, "current_not_object", 2)
    s.mutate(lambda o: o["lanes"][0].update({"current": "XACA-9001"}))
    put("current_not_object", s, "current is a bare string", synthetic=True)

    s = Scenario(tmp, "tokens_bad_item", 2)
    s.assign("XACA-9001")
    s.assign("XACA-9002")
    s.tokens({"run": block("m", 1, 1, 1, 1, 1),
              "perItem": {"XACA-9001": {"model": "m", "input": "lots", "cacheCreate": 1, "cacheRead": 1, "output": 1, "turns": 1}}})
    put("tokens_bad_item", s, "perItem entry for the current ticket has a non-numeric field; XACA-9002 is missing from perItem", synthetic=True)

    s = Scenario(tmp, "tokens_bad_block", 2)
    s.assign("XACA-9001")
    s.tokens({"run": "many", "perItem": "oops"})
    put("tokens_bad_block", s, "tokens.perItem is not an object", synthetic=True)

    return out


def jq_view(jq_filter, board):
    r = subprocess.run(["jq", "-c", "--arg", "id", REL, jq_filter, board], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("gen_lanes_fixture: jq failed on %s: %s" % (board, r.stderr.strip()))
    return json.loads(r.stdout)


def build():
    if not shutil.which("jq"):
        raise SystemExit("gen_lanes_fixture: jq is required (fail closed)")
    jq_filter = read_filter()
    with tempfile.TemporaryDirectory(prefix="xaca1786-lanes-") as tmp:
        scenarios = build_scenarios(tmp)
        for sc in scenarios.values():
            sc["view"] = jq_view(jq_filter, sc.pop("board"))
    return {
        "_comment": "GENERATED by tests/gen_lanes_fixture.py from kanban-hooks/release_orchestrator.py and the RELEASE_FILTER in "
                    "hooks/register.tsx. Do not edit by hand; tests/test_xaca1786_lanes_fixture.py fails when this is stale.",
        "release": REL,
        "stateStage": dict(ro.STATE_STAGE),
        "states": list(ostate.STATES),
        "laneFreeingStates": list(ro.LANE_FREEING_STATES),
        "tokenContract": contract_tokens(),
        "scenarios": scenarios,
    }


def render():
    data = build()
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    ts = ("// GENERATED by tests/gen_lanes_fixture.py. Do not edit: tests/test_xaca1786_lanes_fixture.py regenerates it from the\n"
          "// real writer (kanban-hooks/release_orchestrator.py) and fails when this file differs. A mod test cannot import .json,\n"
          "// so lanes.fixture.json is mirrored here as a module.\n"
          "export const LANES_FIXTURE = " + text.rstrip("\n") + "\n")
    return text, ts


def main(argv):
    text, ts = render()
    if "--check" in argv:
        stale = [p.name for p, want in ((OUT_JSON, text), (OUT_TS, ts)) if not p.exists() or p.read_text() != want]
        if stale:
            print("STALE: %s (re-run %s)" % (", ".join(stale), Path(__file__).name))
            return 1
        print("fresh")
        return 0
    OUT_JSON.write_text(text)
    OUT_TS.write_text(ts)
    print("wrote %s and %s" % (OUT_JSON.name, OUT_TS.name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
