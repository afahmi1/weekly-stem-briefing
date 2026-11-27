"""Regression test: the STEM briefing never shows a paper older than ~6 months.

Run: python3 ~/.hermes/profiles/research/tools/test_window_floor.py
No network, no writes (--dry-run, OpenAlex fetch stubbed with fixed records).
"""
import contextlib, io, pathlib, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import weekly_stem_briefing as w

KEEP = "Primordial gravitational wave constraints from pulsar timing"
STALE = {
    "STALE NOV 2025 quantum gravity paper": ("2025-11-02", 2025),
    "STALE MAR 2026 quantum gravity paper": ("2026-03-01", 2026),
    "UNDATED 2026 quantum gravity paper": ("", 2026),   # year alone can't prove age
}


def work(title, date, year):
    return {"title": title, "doi": f"https://doi.org/10.9999/{year}.{abs(hash(title)) % 9999}",
            "publication_date": date, "publication_year": year, "cited_by_count": 500,
            "primary_location": {"source": {"display_name": f"Nature {title[:6]}"}},
            "open_access": {"is_oa": True}, "authorships": [], "primary_topic": {},
            "abstract_inverted_index": {}}


seen_windows = []


def fake(start, end, pages=2, per_page=200):
    seen_windows.append((start, end))
    return [work(t, d, y) for t, (d, y) in STALE.items()] + [work(KEEP, str(end - w.dt.timedelta(days=3)), end.year)]


def run(argv):
    w.fetch_openalex_pool = fake
    w.previous_window = lambda: None          # hermetic: ignore what is on disk today
    w.attach_fulltext = lambda items, workers=6: {"resolved": 0, "pdf": 0, "page": 0, "closed": 0}
    sys.argv = ["weekly_stem_briefing.py", "--dry-run", "--no-fulltext", *argv]
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        w.main()
    return out.getvalue(), err.getvalue()


fails = 0
for argv in ([], ["--days", "900"], ["--max-age-days", "9999"]):
    out, err = run(argv)
    start, end = seen_windows[-1]
    span = (end - start).days
    ok_span = span <= w.MAX_AGE_DAYS
    ok_drop = f"dropped {len(STALE)} papers" in err
    ok_stale = not any(t[:40] in out for t in STALE)
    ok_keep = KEEP[:40] in out
    good = ok_span and ok_drop and ok_stale and ok_keep
    fails += not good
    print(f"{'PASS' if good else 'FAIL'} argv={argv or '(defaults)'} query span={span}d "
          f"dropped_line={ok_drop} stale_hidden={ok_stale} fresh_kept={ok_keep}")
print("ALL PASS" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
