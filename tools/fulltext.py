#!/usr/bin/env python3
"""Full-text resolver: find the best *legitimate* free copy of a paper.

Tries, in order of reliability:
  1. Europe PMC  (PMC full text + PDF render)      — biomedical, includes preprints
  2. OpenAlex    (best_oa_location + locations)    — broadest OA index, no key
  3. Unpaywall   (only with a real UNPAYWALL_EMAIL) — the OA authority
  4. Semantic Scholar openAccessPdf                — catches author-posted copies
  5. arXiv / bioRxiv / medRxiv                     — preprint DOI shapes
  6. Crossref link[]                               — publisher-declared free PDFs

Deliberately kept separate: Sci-Hub. It is NOT part of the legitimate free-copy
chain above; when every OA source comes up empty, `resolve()` falls back to the
Sci-Hub client in ~/.hermes/mcp/scihub_client.py (mirror rotation + ALTCHA
proof-of-work solver) and marks the result host="Sci-Hub", ft_version="sci-hub"
so callers can label it honestly. Note Sci-Hub froze new uploads in 2020-21, so
it only helps for older literature.

Library: stdlib only (Sci-Hub is reached by subprocess, not an import).
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = "hermes-fulltext/1.0 (research bot; contact: abduel)"
TIMEOUT = 25
MAILTO = os.environ.get("OPENALEX_MAILTO", "research-bot@example.com")


def ssl_ctx():
    """macOS framework pythons ship without a CA store wired into urllib."""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:  # noqa: BLE001
        pass
    for ca in ("/etc/ssl/cert.pem", "/opt/homebrew/etc/openssl@3/cert.pem"):
        try:
            return ssl.create_default_context(cafile=ca)
        except Exception:  # noqa: BLE001
            continue
    return ssl.create_default_context()


CTX = ssl_ctx()


def get(url: str, timeout: int = TIMEOUT) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        return r.read()


def get_json(url: str) -> dict:
    return json.loads(get(url).decode("utf-8", "replace"))


# Many OA hosts 403 a bot-shaped UA but serve a browser one.
BROWSER_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")


def verify_pdf(url: str, max_seconds: int = 12) -> bool:
    """Does this URL actually return PDF bytes? 1 KB range probe, no download."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": BROWSER_UA, "Range": "bytes=0-1023",
            "Accept": "application/pdf,*/*"})
        with urllib.request.urlopen(req, timeout=max_seconds, context=CTX) as r:
            ctype = (r.headers.get("Content-Type") or "").lower()
            head = r.read(1024)
        return "pdf" in ctype or head[:5] == b"%PDF-"
    except Exception:  # noqa: BLE001 - a failed probe is just "not verified"
        return False


def _safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception:  # noqa: BLE001 - every route is best effort
        return None


# ---------------------------------------------------------------- routes
def europepmc(doi: str) -> list[dict]:
    """PMC landing page (always open), Europe PMC page, then PDF renders.

    Europe PMC's pdf=render endpoint sits behind Cloudflare and 403s scripted
    requests, so a PMC *landing* page is the honest primary route: it works in a
    browser and carries its own PDF button.
    """
    q = f'DOI:"{doi}"'
    d = get_json("https://www.ebi.ac.uk/europepmc/webservices/rest/search?query="
                 + urllib.parse.quote(q) + "&format=json&resultType=core&pageSize=1")
    hits = (d.get("resultList") or {}).get("result", [])
    if not hits:
        return []
    r = hits[0]
    out = []
    pmcid = r.get("pmcid") or ""
    is_oa = r.get("isOpenAccess") == "Y"
    if pmcid:
        out.append({"url": f"https://pmc.ncbi.nlm.nih.gov/articles/{pmcid}/",
                    "host": "PubMed Central", "kind": "oa_page", "version": "publisher"})
        out.append({"url": f"https://europepmc.org/articles/{pmcid}?pdf=render",
                    "host": "Europe PMC", "kind": "pdf", "version": "publisher"})
    # A PubMed record WITHOUT a PMCID is abstract-only: it indexes every article,
    # open or not, so it is not a full-text route and must not be offered as one.
    if not pmcid and not is_oa:
        return []
    if is_oa and r.get("fullTextUrlList"):
        for u in (r["fullTextUrlList"].get("fullTextUrl") or []):
            if u.get("availability") == "Open access" and u.get("url"):
                out.append({"url": u["url"], "host": u.get("site", "Europe PMC"),
                            "kind": "pdf" if u.get("documentStyle") == "pdf" else "oa_page",
                            "version": u.get("documentStyle", "")})
    return [o for o in out if o["url"]]


def openalex(doi: str) -> list[dict]:
    d = get_json("https://api.openalex.org/works/https://doi.org/"
                 + urllib.parse.quote(doi) + f"?mailto={MAILTO}")
    out = []
    best = d.get("best_oa_location") or {}
    if best.get("pdf_url"):
        out.append({"url": best["pdf_url"], "host": (best.get("source") or {}).get(
            "display_name") or "OpenAlex", "kind": "pdf", "version": best.get("version") or ""})
    for loc in (d.get("locations") or [])[:8]:
        if not loc.get("is_oa"):
            continue
        u = loc.get("pdf_url")
        if u:
            out.append({"url": u, "host": (loc.get("source") or {}).get("display_name") or "",
                        "kind": "pdf", "version": loc.get("version") or ""})
        elif loc.get("landing_page_url"):
            out.append({"url": loc["landing_page_url"], "host": (loc.get("source") or {}).get(
                "display_name") or "", "kind": "landing", "version": loc.get("version") or ""})
    return out


def unpaywall(doi: str) -> list[dict]:
    email = os.environ.get("UNPAYWALL_EMAIL", "")
    if not email or "@" not in email or "example.com" in email:
        return []
    d = get_json("https://api.unpaywall.org/v2/" + urllib.parse.quote(doi)
                 + "?email=" + urllib.parse.quote(email))
    out = []
    for loc in [d.get("best_oa_location")] + (d.get("oa_locations") or []):
        if not loc:
            continue
        u = loc.get("url_for_pdf") or loc.get("url")
        if u:
            out.append({"url": u, "host": loc.get("host_type") or "Unpaywall",
                        "kind": "pdf" if loc.get("url_for_pdf") else "landing",
                        "version": loc.get("version") or ""})
    return out


def semanticscholar(doi: str) -> list[dict]:
    d = get_json("https://api.semanticscholar.org/graph/v1/paper/DOI:"
                 + urllib.parse.quote(doi) + "?fields=openAccessPdf,isOpenAccess,externalIds")
    p = d.get("openAccessPdf") or {}
    if p.get("url"):
        return [{"url": p["url"], "host": "Semantic Scholar", "kind": "pdf", "version": ""}]
    return []


def preprints(doi: str) -> list[dict]:
    out = []
    m = re.match(r"10\.48550/arxiv\.(.+)$", doi, re.I)
    if m:
        aid = m.group(1)
        out.append({"url": f"https://arxiv.org/pdf/{aid}", "host": "arXiv",
                    "kind": "pdf", "version": "preprint"})
    m = re.match(r"10\.1101/(.+)$", doi)
    if m:
        slug = m.group(1)
        for host in ("www.biorxiv.org", "www.medrxiv.org"):
            out.append({"url": f"https://{host}/content/{doi}v1.full.pdf", "host": host,
                        "kind": "pdf", "version": "preprint"})
    return out


def crossref(doi: str) -> list[dict]:
    d = get_json("https://api.crossref.org/works/" + urllib.parse.quote(doi)
                 + f"?mailto={MAILTO}")
    out = []
    for link in ((d.get("message") or {}).get("link") or []):
        if "pdf" in (link.get("content-type") or ""):
            out.append({"url": link.get("URL", ""), "host": link.get("content-version") or "Crossref",
                        "kind": "pdf", "version": link.get("content-version") or ""})
    return [o for o in out if o["url"]]


def library_routes(doi: str, title: str = "") -> list[dict]:
    """Legal routes for a closed paper: SJSU holdings, Scholar, author, ILL."""
    q = urllib.parse.quote(doi if doi else title)
    out = []
    if doi:
        out.append({
            "url": "https://csu-sjsu.primo.exlibrisgroup.com/openurl/01CALS_SJO/01CALS_SJO"
                   f"?rft_id=info:doi/{urllib.parse.quote(doi)}",
            "host": "SJSU OneSearch",
            "kind": "library", "version": "",
            "note": "link resolver: lands on the full-text option when the library licenses it"})
    out += [
        {"url": f"https://csu-sjsu.primo.exlibrisgroup.com/discovery/search?query=any,contains,{q}",
         "host": "SJSU Library", "kind": "library", "version": "",
         "note": "catalog search by title when there is no DOI"},
        {"url": f"https://scholar.google.com/scholar?q={q}", "host": "Google Scholar",
         "kind": "library", "version": "", "note": "shows SJSU full-text links when signed in"},
        {"url": f"https://doi.org/{doi}" if doi else "", "host": "Publisher", "kind": "landing",
         "version": "", "note": "publisher page, or email the corresponding author"},
    ]
    return [r for r in out if r.get("url")]


# ------------------------------------------------------- preprint title checks
# OA indexes occasionally attach the WRONG preprint to a DOI (a cited paper, a
# merged record). Linking that silently would put a different paper's PDF behind
# a briefing headline, so every preprint-host candidate has to prove its title.
PREPRINT_HOSTS = ("arxiv", "biorxiv", "medrxiv", "research square", "researchsquare",
                  "cold spring harbor", "ssrn", "preprints.org", "chemrxiv")
_STOP = {"the", "a", "an", "of", "for", "and", "in", "on", "with", "to", "by",
         "from", "via", "using", "based", "into", "towards", "toward", "is", "are"}


def _title_tokens(s: str) -> set[str]:
    words = re.findall(r"[a-z0-9]+", (s or "").lower())
    return {w for w in words if len(w) > 2 and w not in _STOP}


def title_match(a: str, b: str, threshold: float = 0.6) -> bool | None:
    """Overlap of significant title words. None when either title is unusable."""
    ta, tb = _title_tokens(a), _title_tokens(b)
    if not ta or not tb:
        return None
    inter = len(ta & tb)
    return inter / min(len(ta), len(tb)) >= threshold


def _arxiv_id(url: str) -> str:
    m = re.search(r"arxiv\.org/(?:pdf|abs)/([0-9]{4}\.[0-9]{4,5}|[a-z\-]+/\d{7})", url, re.I)
    if m:
        return m.group(1)
    m = re.search(r"10\.48550/arxiv\.(.+)$", url, re.I)
    return m.group(1) if m else ""


def _preprint_title(url: str) -> str:
    """Best-effort title of the thing at a preprint URL, '' when unknown."""
    aid = _arxiv_id(url)
    if aid:
        try:
            x = get(f"http://export.arxiv.org/api/query?id_list={aid}").decode("utf-8", "replace")
            return re.sub(r"\s+", " ", x.split("<entry>")[1].split("<title>")[1]
                          .split("</title>")[0]).strip()
        except Exception:  # noqa: BLE001
            return ""
    m = re.search(r"10\.1101/(.+)$", url)
    if m and ("biorxiv" in url or "medrxiv" in url):
        server = "medrxiv" if "medrxiv" in url else "biorxiv"
        try:
            d = get_json(f"https://api.biorxiv.org/details/{server}/{m.group(1)}/na")
            col = (d.get("collection") or [])
            if col:
                return col[0].get("title", "")
        except Exception:  # noqa: BLE001
            return ""
    try:  # generic: the page's <title> or a citation_title meta
        html = get(url, timeout=15).decode("utf-8", "replace")[:200000]
        m2 = re.search(r'<meta[^>]+name="citation_title"[^>]+content="([^"]+)"', html, re.I)
        if m2:
            return m2.group(1)
        m3 = re.search(r"<title>(.*?)</title>", html, re.S | re.I)
        if m3:
            return re.sub(r"\s+", " ", m3.group(1)).strip()
    except Exception:  # noqa: BLE001
        return ""
    return ""


def check_preprint(route: dict, title: str) -> bool | None:
    """True/False when we could compare titles, None when it stays unverified."""
    host = (route.get("host") or "").lower()
    if not any(h in host for h in PREPRINT_HOSTS):
        return None
    if not title:
        return None
    return title_match(title, _preprint_title(route.get("url", "")))


SCIHUB_PY = pathlib.Path.home() / ".hermes/mcp/scihub-venv/bin/python"
SCIHUB_CLI = pathlib.Path.home() / ".hermes/mcp/scihub_client.py"


def scihub(doi: str, timeout: int = 90) -> list[dict]:
    """Last-resort Sci-Hub lookup via the sidecar client (mirror rotation + ALTCHA).

    Runs out-of-process because it needs the `requests` venv, and because the
    briefing's system python3 is stdlib-only. Never raises.
    """
    if not (SCIHUB_PY.exists() and SCIHUB_CLI.exists() and doi):
        return []
    try:
        r = subprocess.run([str(SCIHUB_PY), str(SCIHUB_CLI), "json", doi],
                           capture_output=True, text=True, timeout=timeout)
        data = json.loads((r.stdout or "").strip() or "{}")
    except Exception:  # noqa: BLE001 - a dead mirror is not fatal
        return []
    if data.get("status") == "success" and data.get("pdf_url"):
        return [{"url": data["pdf_url"], "host": "Sci-Hub", "kind": "pdf",
                 "version": "sci-hub", "mirror": data.get("mirror", "")}]
    return []


ROUTES = {
    "europepmc": europepmc,
    "openalex": openalex,
    "unpaywall": unpaywall,
    "semanticscholar": semanticscholar,
    "preprints": preprints,
    "crossref": crossref,
}


def resolve(doi: str, *, title: str = "", short_circuit: bool = True,
            verify: bool = True, max_workers: int = 6,
            use_scihub: bool = True) -> dict:
    """Best free full-text route for one DOI.

    short_circuit: stop launching new routes once any PDF candidate turns up
    (fast path for briefing runs, where 12 items resolve in a few seconds).
    verify: probe the top PDF candidates for real PDF bytes, so a link that 403s
    to scripts is never presented as a download.
    """
    doi = (doi or "").strip().replace("https://doi.org/", "")
    out = {"doi": doi, "title": title, "is_oa": False, "pdf": "", "free_url": "",
           "ft_kind": "", "ft_version": "", "ft_note": "", "host": "",
           "routes": [], "errors": {}, "source_count": 0}
    if not doi:
        return out

    found: list[dict] = []
    if short_circuit:
        # Ordered probes, stop as soon as a PDF turns up.
        for name in ("europepmc", "preprints", "openalex", "semanticscholar",
                     "unpaywall", "crossref"):
            try:
                got = ROUTES[name](doi) or []
            except Exception as e:  # noqa: BLE001
                out["errors"][name] = f"{type(e).__name__}: {e}"[:120]
                continue
            out["source_count"] += 1
            if got:
                found.extend(got)
            if any(r.get("kind") == "pdf" for r in found):
                break
    else:
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futs = {pool.submit(ROUTES[n], doi): n for n in ROUTES}
            for fut, name in futs.items():
                try:
                    found.extend(fut.result() or [])
                except Exception as e:  # noqa: BLE001
                    out["errors"][name] = f"{type(e).__name__}: {e}"[:120]

    seen: set[str] = set()
    routes: list[dict] = []
    for r in found:
        u = (r.get("url") or "").strip()
        if not u or u in seen:
            continue
        seen.add(u)
        routes.append(r)
    # PDFs first, then OA pages; preprint PDFs are the most reliably open.
    routes.sort(key=lambda r: (r.get("kind") != "pdf", r.get("version") != "preprint"))
    out["routes"] = routes

    pdfs = [r for r in routes if r.get("kind") == "pdf"]
    pages = [r for r in routes if r.get("kind") == "oa_page"]

    chosen = None
    unverified = None
    checked = 0
    for cand in pdfs:
        if checked >= 4:
            break
        checked += 1
        tc = check_preprint(cand, title)
        cand["title_ok"] = tc
        if tc is False:
            continue  # a different paper's preprint: never link it
        if not (chosen or unverified) or tc is True:
            ok = verify_pdf(cand["url"]) if verify else True
            if ok:
                if tc is True or not any(h in (cand.get("host") or "").lower()
                                         for h in PREPRINT_HOSTS):
                    chosen = cand
                    break
                if unverified is None:
                    unverified = cand
                    continue
    if chosen is None and unverified is not None:
        chosen = unverified
        out["ft_note"] = "preprint version — title could not be confirmed"

    if chosen:
        out.update(is_oa=True, pdf=chosen["url"], free_url=chosen["url"],
                   ft_kind="pdf", host=chosen.get("host") or "",
                   ft_version=chosen.get("version") or "")
    elif pages:
        # Open page (PMC / publisher OA) that works in a browser, even if the
        # PDF endpoint refuses scripted requests.
        out.update(is_oa=True, free_url=pages[0]["url"], ft_kind="page",
                   host=pages[0].get("host") or "",
                   ft_version=pages[0].get("version") or "")
    else:
        # Every legitimate OA source came up empty. Last resort: Sci-Hub, clearly
        # marked so the UI can label it (host/version), and never presented as OA.
        sh = scihub(doi) if (use_scihub and doi) else []
        if sh:
            out.update(is_oa=False, free_url=sh[0]["url"], ft_kind="pdf",
                       host="Sci-Hub", ft_version="sci-hub",
                       ft_note="via Sci-Hub (unlicensed mirror)")
            out["scihub"] = sh[0]["url"]
        out["library"] = [r for r in library_routes(doi, title) if r.get("url")]
    return out


def fetch_pdf_text(url: str, *, max_chars: int = 40000, max_pages: int | None = None,
                   timeout: int = 90) -> str:
    """Download a PDF and dump its text with the PDFKit helper.

    The helper is a tiny Swift binary (tools/pdftext) so no pip dependency is
    needed. Returns "" when the download or the extraction fails.
    """
    import shutil
    import subprocess
    import tempfile

    helper = os.path.expanduser("~/.hermes/tools/bin/pdftext")
    if not os.path.exists(helper):
        return ""
    tmpdir = tempfile.mkdtemp(prefix="ft-")
    path = os.path.join(tmpdir, "paper.pdf")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": BROWSER_UA,
                                                  "Accept": "application/pdf,*/*"})
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r, open(path, "wb") as fh:
            shutil.copyfileobj(r, fh, length=1 << 20)
        cmd = [helper, path] + ([str(max_pages)] if max_pages else [])
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if out.returncode != 0:
            return ""
        text = re.sub(r"[ \t]+", " ", out.stdout)
        return text[:max_chars]
    except Exception:  # noqa: BLE001 - extraction is best effort
        return ""
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def scihub_text(doi: str, max_chars: int = 40000, timeout: int = 180) -> str:
    """Extract text via the Sci-Hub client (it sends the Referer the CDN requires)."""
    if not (SCIHUB_PY.exists() and SCIHUB_CLI.exists() and doi):
        return ""
    try:
        r = subprocess.run([str(SCIHUB_PY), str(SCIHUB_CLI), "text", doi],
                           capture_output=True, text=True, timeout=timeout)
        return (r.stdout or "")[:max_chars]
    except Exception:  # noqa: BLE001
        return ""


def get_full_text(doi: str, *, title: str = "", max_chars: int = 40000,
                  max_pages: int | None = None) -> dict:
    """Resolve and read: best free route, then plain text when it is a PDF."""
    r = resolve(doi, title=title)
    if r.get("ft_kind") == "pdf" and r.get("free_url"):
        if "sci-hub" in (r.get("host") or "").lower():
            text = scihub_text(doi, max_chars=max_chars)
        else:
            text = fetch_pdf_text(r["free_url"], max_chars=max_chars, max_pages=max_pages)
        r["text"] = text
        r["text_source"] = r.get("host", "") if text else ""
    else:
        r["text"] = ""
    return r


def main() -> int:
    import argparse
    import sys
    ap = argparse.ArgumentParser(description="Find a legitimate free full text for a DOI.")
    ap.add_argument("doi", nargs="+")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--deep", action="store_true", help="probe every route in parallel")
    ap.add_argument("--library", action="store_true", help="also show closed-access lift routes")
    ap.add_argument("--text", action="store_true", help="download and print the PDF text")
    ap.add_argument("--pages", type=int, help="with --text: stop after N pages")
    args = ap.parse_args()

    if args.text:
        for d in args.doi:
            r = get_full_text(d, max_pages=args.pages)
            print(f"\n===== {d} =====")
            if r.get("text"):
                print(f"[{r['host']} pdf, {len(r['text'])} chars]\n")
                print(r["text"])
            elif r.get("free_url"):
                print(f"no text extractor result; free copy: {r['free_url']}")
            else:
                print("closed — no open copy found.")
                for lib in r.get("library", []):
                    print(f"  {lib['url']}  [{lib['host']}]")
        return 0

    results = [resolve(d, short_circuit=not args.deep) for d in args.doi]
    if args.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return 0
    for r in results:
        print(f"\n{r['doi']}")
        if r["ft_kind"] == "pdf":
            print(f"  FREE PDF ({r['host']}): {r['free_url']}")
            for other in r["routes"][1:4]:
                if other["url"] != r["free_url"] and other.get("kind") in ("pdf", "oa_page"):
                    print(f"  also {other['kind']}: {other['url']}  [{other.get('host','')}]")
        elif r["ft_kind"] == "page":
            print(f"  FREE FULL TEXT PAGE ({r['host']}): {r['free_url']}")
            print("  (page carries a PDF button; its direct PDF endpoint refuses scripted fetches)")
        else:
            print("  closed — no open copy found"
                  + (f" (probed {r['source_count']} routes)" if r["source_count"] else ""))
            if args.library:
                for lib in r.get("library", []):
                    print(f"  {lib['kind']}: {lib['url']}  [{lib['host']}] {lib.get('note','')}")
        if r["errors"] and args.deep:
            print(f"  errors: {r['errors']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
