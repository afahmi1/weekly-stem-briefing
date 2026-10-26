#!/usr/bin/env python3
"""Weekly STEM Briefing — a field-balanced, triple-ranked digest.

What changed (v3): the old build was bio/medicine-skewed because two of its three
paper sources were bio-only (bioRxiv) and biomed-only (PubMed). This version pulls
one broad window of peer-reviewed work from OpenAlex, classifies every paper into a
canonical STEM field with our own classifier (OpenAlex's own label is unreliable),
and then selects a field-BALANCED set so physics, chemistry, CS, math, materials,
earth, neuro, engineering, immunology, medicine and biology all get a seat.

Every paper is then enriched (stem_enrich.py, pure Python so the widget's refresh
button keeps working) with:
  - a one-sentence plain summary
  - three 0-100 axes:  Market (public-market relevance + the tickers it moves),
    Field (scientific impact), You (personal appeal to Abduel)
  - a composite the whole list is ranked by.

Each paper also gets a free full-text link (tools/fulltext.py) or a sci-hub
fallback. Writes:
  ~/Library/Application Support/WeeklyStemBriefing/briefing.json   (the Mac widget)
  ~/.hermes/profiles/research/notes/weekly-stem-briefing-<date>.md (notes vault)

Usage:
  weekly_stem_briefing.py                      # last 7 days, defaults
  weekly_stem_briefing.py --top 14 --headlines 4
  weekly_stem_briefing.py --no-fulltext        # skip resolver (fast)
  weekly_stem_briefing.py --dry-run
"""
from __future__ import annotations
import argparse, datetime as dt, json, pathlib, sys, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

try:
    import defusedxml.ElementTree as SAFE_ET  # type: ignore
    def parse_xml(text):
        return SAFE_ET.fromstring(text)
except Exception:  # noqa: BLE001
    def parse_xml(text):
        if "<!DOCTYPE" in text[:4000]:
            raise ValueError("refusing XML with a DOCTYPE (entity-expansion guard)")
        return ET.fromstring(text)

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import weekly_stem as ws       # OpenAlex fetch, scoring, resolver, helpers
import stem_enrich as en       # classify / summarize / 3-axis scoring
import direct_pdf              # publisher direct-PDF endpoint finder (skip the landing page)

OUT = pathlib.Path.home() / "Library" / "Application Support" / "WeeklyStemBriefing"
# Notes go to the research vault when it exists (Abduel's setup); otherwise beside
# the app, so a shared install doesn't create a stray profile dir on someone else's Mac.
_RESEARCH = pathlib.Path.home() / ".hermes" / "profiles" / "research"
NOTES = (_RESEARCH / "notes") if _RESEARCH.exists() else (pathlib.Path.home() / "WeeklyStemBriefing" / "notes")

# A few varied feeds (not bio-only) for the light headlines strip.
FEEDS = [
    ("Nature", "https://www.nature.com/nature.rss"),
    ("ScienceDaily", "https://www.sciencedaily.com/rss/top/science.xml"),
    ("Ars Technica", "https://feeds.arstechnica.com/arstechnica/science"),
    ("Quanta", "https://www.quantamagazine.org/feed/"),
]

# Field display order + the quota each gets in the balanced pass. Tuned so the
# physical sciences are guaranteed a presence instead of being crowded out.
FIELD_ORDER = ["Medicine", "Bio", "Neuro", "Immuno", "Physics", "Astronomy",
               "Chemistry", "Materials", "CS", "Engineering", "Earth", "Math", "Pharma"]
PER_FIELD_CAP = 2          # at most this many per field in the balanced set
PER_JOURNAL_CAP = 1        # at most this many per journal (maximize variety)


def get_text(url, timeout=30):
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) stem-briefing/3.0",
        "Accept": "application/rss+xml, application/xml, text/xml, */*"})
    with urllib.request.urlopen(req, timeout=timeout, context=ws.CTX) as r:
        return r.read().decode("utf-8", "replace")


def fetch_openalex_pool(start, end, pages=2, per_page=200):
    """Broad window pull across all of OpenAlex, newest-cited first, several pages."""
    out = []
    base_flt = (f"from_publication_date:{start},to_publication_date:{end},"
                f"type:article,is_retracted:false")
    for pg in range(1, pages + 1):
        url = ("https://api.openalex.org/works?"
               + urllib.parse.urlencode({
                   "filter": base_flt, "per-page": per_page, "page": pg,
                   "sort": "cited_by_count:desc", "mailto": ws.MAILTO})
               + "&select=id,doi,title,publication_date,primary_location,cited_by_count,"
                 "open_access,authorships,primary_topic,abstract_inverted_index,language")
        try:
            res = ws.get_json(url).get("results", [])
        except Exception as e:  # noqa: BLE001
            print(f"openalex page {pg} failed: {type(e).__name__}: {e}", file=sys.stderr)
            break
        if not res:
            break
        out.extend(res)
    return out


def select_balanced(items, target):
    """Round-robin across STEM fields so every science is represented.

    Within a field, higher composite wins. Caps per field and per journal keep
    the list varied; a second pass fills any remaining slots by composite.
    """
    by_field = {}
    for it in sorted(items, key=lambda i: -i.get("composite", 0)):
        if it["cat"] == "STEM":          # unclassifiable / non-science catch-all: skip
            continue
        by_field.setdefault(it["cat"], []).append(it)

    picked, used_journals, used_titles, field_count = [], {}, set(), {}

    def take(it):
        j = ws.norm(it.get("journal", ""))
        t = ws.norm(it.get("title", ""))
        if t in used_titles:
            return False
        if used_journals.get(j, 0) >= PER_JOURNAL_CAP and j:
            return False
        if field_count.get(it["cat"], 0) >= PER_FIELD_CAP:
            return False
        picked.append(it)
        used_titles.add(t)
        used_journals[j] = used_journals.get(j, 0) + 1
        field_count[it["cat"]] = field_count.get(it["cat"], 0) + 1
        return True

    # round-robin: one per field per lap, following FIELD_ORDER then any extras
    order = FIELD_ORDER + [f for f in by_field if f not in FIELD_ORDER]
    cursor = {f: 0 for f in by_field}
    changed = True
    while len(picked) < target and changed:
        changed = False
        for f in order:
            if len(picked) >= target:
                break
            lst = by_field.get(f, [])
            while cursor.get(f, 0) < len(lst):
                it = lst[cursor[f]]
                cursor[f] += 1
                if take(it):
                    changed = True
                    break
    # fill any leftover slots by composite, relaxing the per-field cap
    if len(picked) < target:
        for it in sorted(items, key=lambda i: -i.get("composite", 0)):
            if len(picked) >= target:
                break
            if it["cat"] == "STEM":
                continue
            t = ws.norm(it.get("title", ""))
            if t in used_titles:
                continue
            picked.append(it)
            used_titles.add(t)
    return picked


def fetch_headlines(per_feed):
    def local(tag):
        return tag.rsplit("}", 1)[-1]
    rows = []
    for source, url in FEEDS:
        try:
            root = parse_xml(get_text(url))
        except Exception as e:  # noqa: BLE001
            print(f"feed {source} failed: {type(e).__name__}: {e}", file=sys.stderr)
            continue
        entries = [e for e in root.iter() if local(e.tag) in ("item", "entry")]
        taken = 0
        for e in entries:
            title = link = ""
            for ch in e:
                lt = local(ch.tag)
                if lt == "title" and not title:
                    title = (ch.text or "").strip()
                elif lt == "link" and not link:
                    link = (ch.text or "").strip() or ch.attrib.get("href", "").strip()
            if title and link:
                rows.append({"kind": "headline", "source": source,
                             "title": ws.clean(title), "url": link})
                taken += 1
                if taken >= per_feed:
                    break
    return rows


def add_scihub(items):
    for it in items:
        it.setdefault("ft_kind", "")
        it.setdefault("ft_url", "")
        it.setdefault("ft_host", "")
        it["scihub"] = ""
        if it.get("ft_kind") not in ("pdf", "page") and it.get("doi"):
            it["scihub"] = f"https://sci-hub.ru/{it['doi']}"


def _has_pdf(it: dict) -> bool:
    """Can he actually open this? Free/sci-hub full text, or a real PDF endpoint."""
    if it.get("ft_kind") in ("pdf", "page") and it.get("ft_url"):
        return True
    return bool(it.get("pdf_direct"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--top", type=int, default=14, help="field-balanced papers to keep")
    ap.add_argument("--backfill", type=int, default=6,
                    help="extra candidates resolved so unreachable papers can be replaced")
    ap.add_argument("--headlines", type=int, default=4, help="per feed")
    ap.add_argument("--pages", type=int, default=2, help="OpenAlex pages (x200) to scan")
    ap.add_argument("--no-fulltext", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--end", help="ISO end date (default today)")
    args = ap.parse_args()

    end = dt.date.fromisoformat(args.end) if args.end else dt.date.today()
    start = end - dt.timedelta(days=args.days)

    # 1. broad pull, score, classify, enrich
    works = fetch_openalex_pool(start, end, pages=args.pages)
    pool = [ws.to_item(w) for w in works]
    pool = [i for i in pool if i["title"] and i["journal"]]
    scanned = len(pool)
    for it in pool:
        it["kind"] = "paper"; it["source"] = "journal"
        en.enrich(it)

    # 2. field-balanced selection. Over-select by a few: anything we cannot reach a
    # PDF for is dropped after resolution, so keep spares to fill the list back up.
    want = args.top
    papers = select_balanced(pool, want + max(0, args.backfill))
    papers.sort(key=lambda i: -i.get("composite", 0))

    # 3. full text: legit OA -> Sci-Hub -> publisher direct PDF endpoint
    ft_stats = {"resolved": 0, "pdf": 0, "page": 0, "closed": 0}
    if not args.no_fulltext and papers:
        ft_stats = ws.attach_fulltext(papers)
    add_scihub(papers)

    # Still closed? Find the publisher's direct PDF endpoint so a click skips the
    # landing page (the library proxy unlocks it once he's signed in).
    for it in papers:
        it.setdefault("pdf_direct", "")
        it.setdefault("pdf_probe", "")
        if it.get("ft_kind") not in ("pdf", "page") and "sci-hub" not in (it.get("ft_host") or "").lower():
            try:
                r = direct_pdf.resolve(it.get("doi", ""))
                it["pdf_direct"] = r.get("pdf_direct", "")
                it["pdf_probe"] = r.get("probe", "")
            except Exception as e:  # noqa: BLE001
                print(f"direct_pdf {it.get('doi')}: {type(e).__name__}", file=sys.stderr)

    # 4. DROP anything with no reachable PDF (free, Sci-Hub, or a real publisher
    # direct-PDF endpoint). A paper he cannot open is not worth a slot.
    dropped = 0
    if not args.no_fulltext:
        reachable = [p for p in papers if _has_pdf(p)]
        dropped = len(papers) - len(reachable)
        papers = reachable[:want]

    headlines = fetch_headlines(args.headlines)

    fields_covered = sorted({p["cat"] for p in papers})
    scihub_n = sum(1 for p in papers if "sci-hub" in (p.get("ft_host") or "").lower())

    stats = [
        {"label": "Ranked", "value": str(len(papers))},
        {"label": "Fields", "value": str(len(fields_covered))},
        {"label": "Sci-Hub", "value": str(scihub_n)},
        {"label": "Dropped", "value": str(dropped)},
    ]

    # sections: one ranked research list + grouped headlines
    sections = [{"id": "ranked", "title": "Ranked across the sciences", "items": papers}]
    for source, _ in FEEDS:
        its = [h for h in headlines if h["source"] == source]
        if its:
            sections.append({"id": f"hl-{source}", "title": f"Headlines \u00b7 {source}", "items": its})

    # flat rows for the widget
    rows = []
    for sec in sections:
        rows.append({"type": "section", "text": sec["title"]})
        for it in sec["items"]:
            if it.get("kind") == "headline":
                rows.append({"type": "headline", "title": it["title"],
                             "url": it["url"], "source": it["source"]})
            else:
                rows.append({
                    "type": "paper", "title": it.get("title", ""),
                    "journal": it.get("journal", ""), "field": it.get("cat", ""),
                    "date": it.get("date", ""), "cites": it.get("cites"),
                    "score": it.get("score"), "oa": it.get("oa", False),
                    "doi": it.get("doi", ""), "url": it.get("url", ""),
                    "ft_kind": it.get("ft_kind", ""), "ft_url": it.get("ft_url", ""),
                    "ft_host": it.get("ft_host", ""), "scihub": it.get("scihub", ""),
                    "pdf_direct": it.get("pdf_direct", ""),
                    "pdf_probe": it.get("pdf_probe", ""),
                    "summary": it.get("summary", ""),
                    "m_score": it.get("m_score", 0), "f_score": it.get("f_score", 0),
                    "p_score": it.get("p_score", 0), "composite": it.get("composite", 0),
                    "tickers": it.get("tickers", []),
                    "abstract": (it.get("abstract") or "")[:400],
                })

    payload = {
        "title": "Weekly STEM Briefing",
        "subtitle": f"Week of {start.isoformat()} \u2192 {end.isoformat()}",
        "generated": dt.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "window": {"start": start.isoformat(), "end": end.isoformat(), "days": args.days},
        "scanned": scanned, "fulltext": ft_stats,
        "axes": {"m": "Market impact", "f": "Field impact", "p": "Personal appeal"},
        "fields_covered": fields_covered,
        "stats": stats, "sections": sections, "rows": rows,
    }

    if args.dry_run:
        print(json.dumps({k: v for k, v in payload.items()
                          if k not in ("sections", "rows")}, indent=2))
        print(f"\nkept {len(papers)} across {len(fields_covered)} fields: {fields_covered}")
        print(f"{'FIELD':<11}{'M':>4}{'F':>4}{'Y':>4}{'CMP':>6}  TICKERS  TITLE")
        for p in papers:
            print(f"{p['cat']:<11}{p['m_score']:>4}{p['f_score']:>4}{p['p_score']:>4}"
                  f"{p['composite']:>6}  {','.join(p['tickers']) or '-':<12} {p['title'][:46]}")
        return 0

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "briefing.json").write_text(json.dumps(payload, indent=1, ensure_ascii=False))

    NOTES.mkdir(parents=True, exist_ok=True)
    md = [f"# Weekly STEM Briefing {end.isoformat()}\n",
          f"Window {start} to {end} \u00b7 {scanned} scanned \u00b7 {len(papers)} ranked across "
          f"{len(fields_covered)} fields ({', '.join(fields_covered)}) \u00b7 "
          f"{len(headlines)} headlines\n",
          "\nRanked by composite of **Market** / **Field** / **Personal** (0-100 each).\n"]
    md.append("\n## Ranked across the sciences\n")
    for i, it in enumerate(papers, 1):
        md.append(f"\n### {i}. {it.get('title','')}\n")
        bits = [f"*{it.get('journal','')}*", it.get("cat", ""), it.get("date", "")]
        if it.get("cites") is not None:
            bits.append(f"{it['cites']} cites")
        md.append(" \u00b7 ".join(b for b in bits if b) + "\n")
        md.append(f"\n{it.get('summary','')}\n")
        tick = (" \u00b7 tickers: " + ", ".join(it["tickers"])) if it.get("tickers") else ""
        md.append(f"\n`Market {it['m_score']} | Field {it['f_score']} | "
                  f"Personal {it['p_score']} | composite {it['composite']}`{tick}\n")
        k = it.get("ft_kind")
        host = (it.get("ft_host") or "")
        if "sci-hub" in host.lower():
            md.append(f"\n[Sci-Hub PDF]({it.get('ft_url')}) \u2014 unlicensed mirror, not OA")
        elif k == "pdf":
            md.append(f"\n[free PDF]({it.get('ft_url')})")
        elif k == "page":
            md.append(f"\n[full text]({it.get('ft_url')})")
        elif it.get("scihub"):
            md.append(f"\n[sci-hub]({it['scihub']}) (paywalled)")
        if it.get("doi"):
            md.append(f" \u00b7 [doi](https://doi.org/{it['doi']})")
        md.append("\n")
    for sec in sections[1:]:
        md.append(f"\n## {sec['title']}\n")
        for h in sec["items"]:
            md.append(f"- [{h['title']}]({h['url']})\n")
    (NOTES / f"weekly-stem-briefing-{end.isoformat()}.md").write_text("".join(md))

    print(f"briefing: {len(papers)} ranked across {len(fields_covered)} fields "
          f"({dropped} dropped: no reachable PDF) -> {OUT/'briefing.json'}")
    print(f"full text: {ft_stats.get('pdf',0)} PDF, {ft_stats.get('page',0)} page, "
          f"{ft_stats.get('closed',0)} closed")
    for p in papers[:5]:
        print(f"  cmp {p['composite']:>5}  M{p['m_score']:>3} F{p['f_score']:>3} "
              f"Y{p['p_score']:>3}  {p['cat']:<10} {p['title'][:46]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
