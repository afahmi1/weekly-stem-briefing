"""Regression test: the briefing window chains forward and only rebuilds once closed.

Run: python3 ~/.hermes/profiles/research/tools/test_window_chain.py
Pure function, no network, no writes, no dependence on the real briefing.json.

The contract Abduel asked for: a briefing reading 2026-10-29 -> 2026-11-05 must, on
11/06, rebuild as 2026-11-05 -> 2026-11-12, and roll again the day after each end date.
"""
import datetime as dt, pathlib, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from weekly_stem_briefing import resolve_window

D = dt.date
prev = (D(2026, 10, 29), D(2026, 11, 5))
fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}\n     got  {got}\n     want {want}")


# no previous file: first run covers the trailing week
check("first run, no previous window",
      resolve_window(D(2026, 11, 7), None, 7), (D(2026, 10, 31), D(2026, 11, 7), False, None))

# mid-window (11/05, the day it was generated): still current, nothing to do
check("window still open on its end date",
      resolve_window(D(2026, 11, 5), prev, 7), (None, None, False, prev))

# the day after the end date: chain to 11/05 -> 11/12
check("rolls the day after the end date",
      resolve_window(D(2026, 11, 6), prev, 7), (D(2026, 11, 5), D(2026, 11, 12), True, None))

# and again a week later, from the newly written window
check("second roll",
      resolve_window(D(2026, 11, 13), (D(2026, 11, 5), D(2026, 11, 12)), 7),
      (D(2026, 11, 12), D(2026, 11, 19), True, None))

# missed weeks: build the earliest outstanding window, never skip content
check("catch-up after two missed weeks",
      resolve_window(D(2026, 11, 20), prev, 7), (D(2026, 11, 5), D(2026, 11, 12), True, None))

# --force rebuilds the open window in place
check("force on an open window",
      resolve_window(D(2026, 11, 5), prev, 7, force=True),
      (D(2026, 10, 29), D(2026, 11, 5), False, None))

# --dry-run is allowed through an open window (fast-pass check writes nothing)
check("dry-run on an open window",
      resolve_window(D(2026, 11, 5), prev, 7, dry_run=True),
      (D(2026, 10, 29), D(2026, 11, 5), False, None))

# explicit --end wins over the chain
check("pinned end date",
      resolve_window(D(2026, 11, 6), prev, 7, pin_end=D(2026, 11, 20)),
      (D(2026, 11, 13), D(2026, 11, 20), False, None))

# contiguous: each window starts exactly where the previous one ended
s, e, _, _ = resolve_window(D(2026, 11, 6), prev, 7)
check("windows tile", s, prev[1])

print("ALL PASS" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
