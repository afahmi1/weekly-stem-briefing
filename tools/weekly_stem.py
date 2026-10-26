#!/usr/bin/env python3
"""Weekly STEM briefing: the most impactful peer-reviewed articles of the last 7 days.

Pulls from OpenAlex (journals only, no preprints) and scores each paper on journal
prestige, citation velocity and open-access availability. Then resolves a free
full text for every item (tools/fulltext.py: PMC, OpenAlex, Unpaywall, Semantic
Scholar, arXiv/bioRxiv, Crossref) so the digest links straight to something
readable. Writes a JSON payload the Mac widget reads, plus a markdown digest for
the notes vault.

Usage:
  weekly_stem.py                 # last 7 days, top 12
  weekly_stem.py --days 7 --top 15
  weekly_stem.py --dry-run       # print, do not write
  weekly_stem.py --no-fulltext   # skip the resolver pass (faster, no links)
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    import fulltext  # same directory: the free-full-text resolver
except Exception as _ft_exc:  # noqa: BLE001 - briefing must survive a missing resolver
    fulltext = None
    _FULLTEXT_IMPORT_ERROR = f"{type(_ft_exc).__name__}: {_ft_exc}"

OUT = pathlib.Path.home() / "Library" / "Application Support" / "StemBriefing"
NOTES = pathlib.Path.home() / ".hermes" / "profiles" / "research" / "notes"
MAILTO = "research-bot@example.com"

# Journal prestige prior. Tiers are deliberately coarse: the point is to stop a Nature
# paper from losing to a Scientific Reports paper that got two early citations.
TIERS = {
    3.0: [
        "nature", "science", "cell", "the new england journal of medicine", "lancet",
        "the lancet", "jama", "nature medicine", "nature biotechnology", "nature materials",
        "nature physics", "nature nanotechnology", "nature chemistry", "nature energy",
        "nature climate change", "nature machine intelligence", "science translational medicine",
        "science immunology", "science robotics", "physical review letters", "physical review x",
        "journal of the american chemical society", "angewandte chemie", "nature neuroscience",
        "nature cell biology", "nature genetics", "cancer cell", "immunity", "neuron",
        "cell stem cell", "nature biomedical engineering", "nature methods", "pnas",
        "proceedings of the national academy of sciences",
    ],
    2.0: [
        "nature communications", "science advances", "elife", "plos medicine", "bmj",
        "annals of internal medicine", "circulation", "european heart journal", "gut",
        "advanced materials", "acs nano", "biomaterials", "journal of clinical investigation",
        "the journal of clinical investigation", "genome biology", "ieee transactions on pattern analysis and machine intelligence",
        "ieee transactions on medical imaging", "nature reviews", "cell reports",
        "journal of the mechanical behavior of biomedical materials", "acta biomaterialia",
        "lancet infectious diseases", "the lancet infectious diseases", "nature reviews drug discovery",
        "npj digital medicine", "patterns", "med", "cell reports medicine",
    ],
    1.3: [
        "scientific reports", "plos one", "plos biology", "frontiers", "mdpi", "sensors",
        "materials", "applied sciences", "journal of clinical medicine", "cureus",
        "bmc", "international journal of molecular sciences", "acs omega", "rsc advances",
        "ieee access", "helpon", "heliyon",
    ],
}

FIELD_LABEL_RAW = {
    "Medicine": "Medicine", "Biology": "Biology", "Chemistry": "Chemistry",
    "Physics": "Physics", "Computer science": "CS", "Engineering": "Engineering",
    "Materials science": "Materials", "Mathematics": "Math",
    "Environmental science": "Earth", "Earth and planetary sciences": "Earth",
    "Neuroscience": "Neuro", "Psychology": "Psych", "Economics": "Econ",
    "Agricultural and biological sciences": "Bio", "Biochemistry, genetics and molecular biology": "Bio",
    "Health professions": "Health", "Immunology and microbiology": "Immuno",
    "Pharmacology, toxicology and pharmaceutics": "Pharma", "Chemical engineering": "ChemE",
}


def ssl_ctx():
    import ssl
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:  # noqa: BLE001
        for ca in ("/etc/ssl/cert.pem", "/opt/homebrew/etc/openssl@3/cert.pem"):
            try:
                return ssl.create_default_context(cafile=ca)
            except Exception:  # noqa: BLE001
                continue
    return ssl.create_default_context()


CTX = ssl_ctx()


def get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "stem-briefing/1.0",
                                              "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=40, context=CTX) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


FIELD_LABEL = {k.lower(): v for k, v in FIELD_LABEL_RAW.items()}


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "")).strip().lower()


ALIASES = {
    "proceedings of the national academy of sciences of the united states of america": "proceedings of the national academy of sciences",
    "the new england journal of medicine": "new england journal of medicine",
    "the lancet": "lancet",
    "the journal of clinical investigation": "journal of clinical investigation",
    "the lancet infectious diseases": "lancet infectious diseases",
    "angewandte chemie international edition": "angewandte chemie",
    "angewandte chemie (international ed. in english)": "angewandte chemie",
    "physical review letters (prl)": "physical review letters",
    "nature reviews. drug discovery": "nature reviews drug discovery",
    "nature reviews drug discovery": "nature reviews drug discovery",
}

# Exact normalized names only. A substring match here is a bug: "Statistical Science"
# and "Journal of Nonlinear Science" are not Science.
TIER_INDEX: dict[str, float] = {}
for _w, _names in TIERS.items():
    for _n in _names:
        TIER_INDEX[_n] = _w


def norm_journal(journal: str) -> str:
    j = norm(journal).rstrip(".")
    j = re.sub(r"\s*\(.*?\)\s*$", "", j)          # drop trailing parentheticals
    j = re.sub(r"^the\s+", "", j)
    return ALIASES.get(j, j)


def tier_for(journal: str) -> tuple[float, str]:
    j = norm_journal(journal)
    if not j:
        return 1.0, ""
    return TIER_INDEX.get(j, 1.0), (j if j in TIER_INDEX else "")


def clean(text: str | None) -> str:
    if not text:
        return ""
    text = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def abstract_from_inv(idx: dict | None) -> str:
    """OpenAlex stores abstracts as an inverted index."""
    if not idx:
        return ""
    slots: list[tuple[int, str]] = []
    for word, positions in idx.items():
        for p in positions:
            slots.append((p, word))
    slots.sort()
    return clean(" ".join(w for _, w in slots))[:1400]


def fetch_openalex(start: dt.date, end: dt.date, per_page: int = 200) -> list[dict]:
    flt = (f"from_publication_date:{start},to_publication_date:{end},"
           f"type:article,is_retracted:false")
    url = ("https://api.openalex.org/works?"
           + urllib.parse.urlencode({
               "filter": flt, "per-page": per_page,
               "sort": "cited_by_count:desc", "mailto": MAILTO})
           + "&select=id,doi,title,publication_date,primary_location,cited_by_count,"
             "open_access,authorships,primary_topic,abstract_inverted_index,language")
    return get_json(url).get("results", [])


def to_item(w: dict, score_parts: bool = True) -> dict:
    loc = w.get("primary_location") or {}
    src = loc.get("source") or {}
    journal = clean(src.get("display_name"))
    weight, tier_hit = tier_for(journal)
    cites = w.get("cited_by_count") or 0
    oa = (w.get("open_access") or {}).get("is_oa")
    topic = w.get("primary_topic") or {}
    field = ((topic.get("field") or {}).get("display_name")) or ""
    doi = (w.get("doi") or "").replace("https://doi.org/", "")
    authors = [clean(a.get("author", {}).get("display_name"))
               for a in (w.get("authorships") or [])[:4]]

    score = 0.65 * weight + 0.30 * math.log10(1 + cites) + (0.05 if oa else 0.0)
    item = {
        "title": clean(w.get("title")),
        "journal": journal,
        "date": w.get("publication_date") or "",
        "doi": doi,
        "url": f"https://doi.org/{doi}" if doi else (w.get("id") or ""),
        "authors": authors,
        "cites": cites,
        "oa": bool(oa),
        "field": FIELD_LABEL.get(field.lower(), field.split()[-1] if field else "STEM"),
        "abstract": abstract_from_inv(w.get("abstract_inverted_index")),
        "language": w.get("language") or "",
        "score": round(score, 3),
        "journal_tier": tier_hit,
    }
    return item


def attach_fulltext(items: list[dict], workers: int = 6) -> dict:
    """Resolve a free full text for each item. Mutates items, returns stats."""
    if fulltext is None:
        for it in items:
            it.update(ft_kind="", ft_url="", ft_host="", ft_note="resolver unavailable")
        return {"resolved": 0, "pdf": 0, "page": 0, "closed": 0,
                "error": _FULLTEXT_IMPORT_ERROR}

    def one(it: dict) -> dict:
        # Sci-Hub stopped ingesting new uploads in 2020-21, so a recent paper is a
        # guaranteed miss. Only spend the lookup when it can actually pay off.
        ym = re.search(r"(19|20)\d{2}", it.get("date") or "")
        use_sh = (int(ym.group(0)) <= 2021) if ym else True
        r = fulltext.resolve(it.get("doi", ""), title=it.get("title", ""),
                             use_scihub=use_sh)
        return {"kind": r.get("ft_kind", ""), "url": r.get("free_url", ""),
                "host": r.get("host", ""), "is_oa": r.get("is_oa", False)}

    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(one, items))

    stats = {"resolved": 0, "pdf": 0, "page": 0, "closed": 0}
    for it, r in zip(items, results):
        it["ft_kind"] = r["kind"]
        it["ft_url"] = r["url"]
        it["ft_host"] = r["host"]
        it["oa"] = bool(it.get("oa") or r["is_oa"])
        stats["resolved"] += 1
        stats["pdf" if r["kind"] == "pdf" else
              "page" if r["kind"] == "page" else "closed"] += 1
    return stats


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--per-page", type=int, default=200)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-fulltext", action="store_true",
                    help="skip the free-full-text resolver pass")
    ap.add_argument("--end", help="ISO end date (default: today)")
    args = ap.parse_args()

    end = dt.date.fromisoformat(args.end) if args.end else dt.date.today()
    start = end - dt.timedelta(days=args.days)

    try:
        works = fetch_openalex(start, end, args.per_page)
    except Exception as e:  # noqa: BLE001
        print(f"openalex fetch failed: {type(e).__name__}: {e}", file=sys.stderr)
        return 1

    items = [to_item(w) for w in works]
    items = [i for i in items if i["title"] and i["journal"]]

    # one paper per journal per briefing keeps the list varied
    seen_journal: dict[str, int] = {}
    picked: list[dict] = []
    for it in sorted(items, key=lambda i: -i["score"]):
        j = norm(it["journal"])
        if seen_journal.get(j, 0) >= 2:
            continue
        seen_journal[j] = seen_journal.get(j, 0) + 1
        picked.append(it)
        if len(picked) >= args.top:
            break

    ft_stats: dict = {}
    if not args.no_fulltext and picked:
        ft_stats = attach_fulltext(picked)
        if ft_stats.get("error"):
            print(f"fulltext resolver unavailable: {ft_stats['error']}", file=sys.stderr)

    payload = {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "window": {"start": start.isoformat(), "end": end.isoformat(), "days": args.days},
        "scanned": len(items),
        "count": len(picked),
        "fulltext": ft_stats,
        "items": picked,
    }

    if args.dry_run:
        print(json.dumps(payload, indent=2)[:3000])
        print(f"\n[dry run] scanned {len(items)}, kept {len(picked)}, fulltext {ft_stats}")
        return 0

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "briefing.json").write_text(json.dumps(payload, indent=1, ensure_ascii=False))
    (OUT / "briefing.js").write_text("window.BRIEFING=" +
                                     json.dumps(payload, ensure_ascii=False) + ";")

    NOTES.mkdir(parents=True, exist_ok=True)
    md = [f"# Weekly STEM briefing {end.isoformat()}\n",
          f"Window {start} to {end} · scanned {len(items)} journal articles · kept {len(picked)}"]
    if ft_stats:
        md.append(f" · free full text: {ft_stats.get('pdf', 0)} PDF, "
                  f"{ft_stats.get('page', 0)} open page, {ft_stats.get('closed', 0)} closed")
    md.append("\n")
    for i, it in enumerate(picked, 1):
        md.append(f"\n## {i}. {it['title']}\n")
        md.append(f"*{it['journal']}* · {it['date']} · {it['field']} · "
                  f"{it['cites']} cites · score {it['score']}\n")
        if it["authors"]:
            md.append(", ".join(it["authors"]) + "\n")
        md.append(f"[{it['url']}]({it['url']})\n")
        kind, ft_url, ft_host = it.get("ft_kind"), it.get("ft_url"), it.get("ft_host")
        if kind == "pdf":
            md.append(f"\n**Free PDF** ({ft_host}): {ft_url}\n")
        elif kind == "page":
            md.append(f"\n**Free full text** ({ft_host}): {ft_url}\n")
        elif it["doi"]:
            md.append("\n*Paywalled — no open copy found.* Scholar: "
                      f"https://scholar.google.com/scholar?q={it['doi']} · "
                      f"SJSU: https://csu-sjsu.primo.exlibrisgroup.com/discovery/search"
                      f"?query=any,contains,{it['doi']}\n")
        if it["abstract"]:
            md.append(f"\n{it['abstract'][:600]}\n")
    (NOTES / f"weekly-stem-{end.isoformat()}.md").write_text("".join(md))

    print(f"briefing: scanned {len(items)}, kept {len(picked)} -> "
          f"{OUT/'briefing.json'} and notes/weekly-stem-{end.isoformat()}.md")
    if ft_stats:
        print(f"full text: {ft_stats.get('pdf', 0)} free PDF, {ft_stats.get('page', 0)} "
              f"open page, {ft_stats.get('closed', 0)} closed")
    for it in picked[:5]:
        tag = {"pdf": "PDF", "page": "FT"}.get(it.get("ft_kind", ""), "--")
        print(f"  {it['score']:>5} {tag:>3}  {it['journal'][:30]:<30} {it['title'][:58]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
