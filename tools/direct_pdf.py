#!/usr/bin/env python3
"""Find a publisher's *direct PDF* URL for a DOI, so a click can skip the
landing page and go straight at the file (through the library proxy).

A landing page (https://doi.org/10.1038/xyz) needs a human to click "Download
PDF". Most big publishers expose a predictable PDF endpoint instead, and the
library proxy will serve it to a subscribed user. We build that URL from the DOI
prefix and PROBE it, so a dead guess is never handed to the user:

  verified   -> returns PDF bytes (rare for closed access without a session)
  paywalled  -> 401/402/403: the endpoint exists, the proxy login unlocks it
  invalid    -> 404/410 or no PDF signals: reject the guess

stdlib only (urllib), so the briefing's system python3 can import it directly.
"""
from __future__ import annotations

import json
import re
import ssl
import urllib.error
import urllib.request

BROWSER_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")

# DOI prefixes whose PDF path is stable even though probing hits a bot wall.
TRUSTED_PATTERNS = {"10.1149", "10.1088"}


def _ctx():
    for ca in ("/etc/ssl/cert.pem", "/opt/homebrew/etc/openssl@3/cert.pem"):
        try:
            return ssl.create_default_context(cafile=ca)
        except Exception:  # noqa: BLE001
            continue
    return ssl.create_default_context()


CTX = _ctx()


def _strip(doi: str) -> str:
    d = (doi or "").strip()
    return re.sub(r"^https?://(dx\.)?doi\.org/", "", d, flags=re.I)


def candidates(doi: str) -> list[str]:
    """Publisher-specific direct-PDF URL guesses, most likely first."""
    doi = _strip(doi)
    if not doi or "/" not in doi:
        return []
    prefix, suf = doi.split("/", 1)
    p = prefix.lower()
    out: list[str] = []
    if p == "10.1038":                                  # Nature portfolio
        out += [f"https://www.nature.com/articles/{suf}.pdf"]
    elif p == "10.1126":                                # Science / AAAS
        out += [f"https://www.science.org/doi/pdf/{doi}"]
    elif p == "10.1073":                                # PNAS
        out += [f"https://www.pnas.org/doi/pdf/{doi}"]
    elif p in ("10.1007", "10.1186"):                   # Springer / BMC
        out += [f"https://link.springer.com/content/pdf/{doi}.pdf"]
    elif p == "10.1021":                                # ACS
        out += [f"https://pubs.acs.org/doi/pdf/{doi}"]
    elif p in ("10.1002", "10.1111", "10.1006"):        # Wiley
        out += [f"https://onlinelibrary.wiley.com/doi/pdfdirect/{doi}"]
    elif p == "10.1016":                                # Elsevier
        out += [f"https://www.sciencedirect.com/science/article/pii/{suf}/pdfft"]
    elif p == "10.1103":                                # APS
        out += [f"https://journals.aps.org/prl/pdf/{doi}"]
    elif p == "10.7554":                                # eLife
        out += [f"https://elifesciences.org/articles/{suf.split('.')[0]}.pdf"]
    elif p == "10.1055":                                # Thieme
        out += [f"https://www.thieme-connect.com/products/ejournals/pdf/{doi}.pdf"]
    elif p == "10.7326":                                # Annals of Internal Medicine (ACP)
        out += [f"https://www.acpjournals.org/doi/pdf/{doi}"]
    elif p == "10.1056":                                # NEJM
        out += [f"https://www.nejm.org/doi/pdf/{doi}"]
    elif p == "10.1177":                                # SAGE
        out += [f"https://journals.sagepub.com/doi/pdf/{doi}"]
    elif p == "10.1148":                                # Radiology (RSNA)
        out += [f"https://pubs.rsna.org/doi/pdf/{doi}"]
    elif p == "10.1161":                                # Circulation (AHA)
        out += [f"https://www.ahajournals.org/doi/pdf/{doi}"]
    elif p == "10.1152":                                # American Physiological Society
        out += [f"https://journals.physiology.org/doi/pdf/{doi}"]
    elif p == "10.1149":                                # ECS (hosted by IOP)
        out += [f"https://iopscience.iop.org/article/{doi}/pdf"]
    elif p == "10.1085":                                # Rockefeller
        out += [f"https://rupress.org/jem/article-pdf/{suf}"]
    return out


def _json(url: str, timeout: int = 20):
    req = urllib.request.Request(url, headers={"User-Agent": BROWSER_UA,
                                               "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def _zenodo(doi: str):
    """Zenodo is open access but the file name is arbitrary: ask its API."""
    rid = _strip(doi).split("zenodo.")[-1]
    if not rid.isdigit():
        return None
    try:
        data = _json(f"https://zenodo.org/api/records/{rid}")
        for f in (data.get("files") or []):
            u = (f.get("links") or {}).get("self")
            if u:
                return {"doi": _strip(doi), "pdf_direct": u, "probe": "verified",
                        "direct": True}
    except Exception:  # noqa: BLE001
        return None
    return None


def probe(url: str, timeout: int = 15) -> str:
    """Classify a URL: verified | paywalled | redirect | invalid | error."""
    req = urllib.request.Request(url, headers={
        "User-Agent": BROWSER_UA, "Range": "bytes=0-1023",
        "Accept": "application/pdf,*/*"})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            ctype = (r.headers.get("Content-Type") or "").lower()
            head = r.read(1024)
        if head[:5] == b"%PDF-" or "pdf" in ctype:
            return "verified"
        # A ".pdf" path that answers 200 with HTML is a publisher gate
        # ("sign in to download") — real endpoint, unlocks through the proxy.
        if url.lower().endswith(".pdf"):
            return "gated"
        return "invalid"
    except urllib.error.HTTPError as e:
        if e.code in (401, 402, 403):
            return "paywalled"
        if e.code in (301, 302, 303, 307, 308):
            return "redirect"
        return "invalid"
    except Exception:  # noqa: BLE001
        return "error"


def _from_landing(doi: str):
    """Follow the DOI to the publisher page and grab its own PDF/download link."""
    target = f"https://doi.org/{_strip(doi)}"
    try:
        req = urllib.request.Request(target, headers={"User-Agent": BROWSER_UA})
        with urllib.request.urlopen(req, timeout=20, context=CTX) as r:
            html = r.read(400000).decode("utf-8", "replace")
            base = r.geturl()
    except Exception:  # noqa: BLE001
        return None
    hrefs = re.findall(r'(?:href|src)\s*=\s*"([^"]+)"', html)
    seen, cands = set(), []
    for h in hrefs:
        low = h.lower()
        if any(k in low for k in ("/pdf", ".pdf", "pdfdirect", "pdfft", "stamp.jsp")):
            if h.startswith("//"):
                h = "https:" + h
            elif h.startswith("/"):
                h = base.split("/", 3)[0] + "//" + base.split("/", 3)[2] + h
            elif not h.startswith("http"):
                continue
            if h not in seen:
                seen.add(h)
                cands.append(h)
    for u in cands[:3]:
        v = probe(u)
        if v in ("verified", "paywalled", "gated"):
            return {"doi": _strip(doi), "pdf_direct": u, "probe": v, "direct": True}
    return None


def resolve(doi: str, probe_it: bool = True) -> dict:
    """Best direct PDF endpoint for a DOI (paywalled endpoints included)."""
    if _strip(doi).startswith("10.5281/zenodo."):
        z = _zenodo(doi)
        if z:
            return z
    for url in candidates(doi):
        verdict = probe(url) if probe_it else "unverified"
        if verdict in ("verified", "paywalled", "gated"):
            return {"doi": _strip(doi), "pdf_direct": url, "probe": verdict,
                    "direct": True}
    if probe_it:
        land = _from_landing(doi)
        if land:
            return land
        # Publishers whose PDF path is stable but whose site bot-walls probes
        # (Radware/Cloudflare). A real browser through the proxy loads fine.
        if _strip(doi).split("/")[0].lower() in TRUSTED_PATTERNS:
            c = candidates(doi)
            if c:
                return {"doi": _strip(doi), "pdf_direct": c[0], "probe": "unverified",
                        "direct": True}
    return {"doi": _strip(doi), "pdf_direct": "", "probe": "", "direct": False}


if __name__ == "__main__":
    import json
    import sys
    for d in sys.argv[1:] or ["10.1038/s41586-026-11172-5"]:
        print(json.dumps(resolve(d)))
