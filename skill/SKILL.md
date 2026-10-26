---
name: weekly-stem-briefing
description: "Use when generating, refreshing, or explaining Abduel's Weekly STEM Briefing."
version: 2.0.0
author: Hermes Agent
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [research, briefing, openalex, rss, fulltext, widget, cron, ranking]
    related_skills: [global-literature-search]
---

# Weekly STEM Briefing

A field-balanced, triple-ranked weekly digest of peer-reviewed science, with a free
full-text link (or sci-hub fallback) for every paper. Feeds a native macOS widget and a
Monday-morning text.

## Generator

```bash
python3 ~/.hermes/profiles/research/tools/weekly_stem_briefing.py            # last 7 days
python3 ~/.hermes/profiles/research/tools/weekly_stem_briefing.py --dry-run  # print table, no write
python3 ~/.hermes/profiles/research/tools/weekly_stem_briefing.py --no-fulltext  # fast, no links
```

Flags: `--days 7`, `--top 14` (papers kept after balancing), `--headlines 4` (per feed),
`--pages 2` (OpenAlex pages x200 to scan), `--end YYYY-MM-DD`.

## How it works (v3 — the de-skew rewrite)

v1/v2 were bio/medicine-heavy because two of three paper sources were bio-only (bioRxiv)
and biomed-only (PubMed). v3 drops those and instead:

1. **Broad pull** — one OpenAlex window (`type:article`, newest-cited first, ~2x200 pool).
2. **Classify** every paper into a canonical STEM field with OUR classifier
   (`stem_enrich.classify_field`, journal + title + abstract keywords). OpenAlex's own
   field label is unreliable, so it is only a last-resort fallback. CS keywords are checked
   first so an LLM paper never lands in Physics.
3. **Field-balanced select** (`select_balanced`) — round-robin across fields (`FIELD_ORDER`,
   `PER_FIELD_CAP=2`, `PER_JOURNAL_CAP=1`) so physics, chemistry, CS, math, materials, earth,
   neuro, engineering, immuno, medicine, bio all get a seat. The non-science `STEM` catch-all
   is skipped. Typically 14 papers across ~12 fields.
4. **Enrich** (`stem_enrich.enrich`, pure Python — no LLM, so the widget refresh button still
   works): a one-sentence `summary`, and three 0-100 axes —
   - **Market** (`m_score`) = public-market relevance + the `tickers` it plausibly moves
     (e.g. surgical robotics -> ISRG, GLP-1 -> LLY/NVO, LLM -> NVDA/MSFT/GOOGL).
   - **Field** (`f_score`) = how much the result moves its own field/industry (NOT generic
     prestige): keyword signals of novelty, industry/translational reach, breadth
     (review/consortium/standard) and quantified magnitude, plus a small prestige/citation
     prior. Retune via `_FI_*` lists in `stem_enrich.py`.
   - **You** (`p_score`) = personal appeal tuned to Abduel (surgical robotics/Intuitive,
     prosthetics/grip/EMG/3D-print, med devices, BCI, birds, AI agents, trading).
   - `composite` = 0.30 M + 0.35 F + 0.35 You (tune `AXIS_WEIGHTS` in `stem_enrich.py`).
5. **Rank** the kept set by `composite` (hero = top). Plus a light headlines strip from 4
   varied feeds (Nature, ScienceDaily, Ars Technica, Quanta).

Every kept paper is run through `tools/fulltext.py` (PMC, OpenAlex, Unpaywall, Semantic
Scholar, arXiv/bioRxiv, Crossref): badge `PDF` / `FULL TEXT` / `OPEN`. Resolver pass ~15-20s
for 14 items.

**Reaching full text (widget click).** `Store.articleURL` always aims at readable text:
1. resolved free full text / Sci-Hub PDF -> opens the file directly;
2. publisher's **direct PDF endpoint** (`tools/direct_pdf.py`, built from the DOI prefix and
   probed: `verified` = free PDF, `paywalled`/`gated` = endpoint real, proxy unlocks it)
   -> opened **through the library proxy** so a click lands on the PDF, not a landing page;
3. only if neither exists, the DOI/article page through the proxy.

`direct_pdf` covers Nature, Science/AAAS, PNAS, Springer/BMC, ACS, Wiley, Elsevier, APS, eLife,
Thieme, ACP, NEJM, SAGE, RSNA, AHA, APS-physio, ECS/IOP, Rockefeller, and Zenodo (via its API).
It also falls back to following the DOI to the publisher page and scraping its own PDF link.
`TRUSTED_PATTERNS` (10.1149/10.1088) accept the pattern when a bot wall blocks the probe.
Current coverage runs ~13/14 papers straight to a PDF; a publisher whose own DOI target 404s
(the residual case) can't be helped. Library: SJSU `libaccess.sjlibrary.org/login?url=<url>`
(default) or BU `ezproxy.bu.edu/login?url=<url>`, switchable in the menu bar (persisted in
`WSBLibrary`).
**Sci-hub is labeled only when it is the actual source** — the resolver sets host="Sci-Hub",
`ft_version="sci-hub"`, which the widget renders as an orange `SCI-HUB` badge. A paywalled
paper with no Sci-Hub copy shows `via SJSU/BU`.

## Files

- `tools/weekly_stem_briefing.py` — orchestrator (pull, balance, enrich, write).
- `tools/stem_enrich.py` — classifier + summarizer + 3-axis scorer. **Edit the keyword/ticker
  tables here** to retune market/personal scoring. 3.9-safe (the widget calls system python3).
- `tools/weekly_stem.py` — OpenAlex fetch, prestige/citation `score`, `attach_fulltext`.
- `tools/fulltext.py` — the free-full-text resolver (legit OA chain, then Sci-Hub).
- `tools/direct_pdf.py` — publisher direct-PDF endpoint finder (skip the landing page).

## Outputs

- `~/Library/Application Support/WeeklyStemBriefing/briefing.json` — the Mac widget reads this.
  Schema: `{title, subtitle, generated, window, scanned, fulltext, axes, fields_covered,
  stats[], sections[], rows[]}`. `rows` is flat `section`/`paper`/`headline`. Each `paper`
  carries `summary, m_score, f_score, p_score, composite, tickers[]`.
- `~/.hermes/profiles/research/notes/weekly-stem-briefing-<date>.md` — notes vault copy.

## Widget

Native SwiftUI/AppKit panel (no Xcode): `~/WeeklyStemBriefing/` (`Sources/main.swift`,
`build-app.sh`). **380x470** (small). Each card shows field tag, title, 1-line summary, the
three M/F/Y meters, ticker chips, and a free-text badge. Hero = top composite pick.

- **Ask AI** — every card (hero + rows) has a ✨ ASK pill. It opens an in-widget chat about
  that one paper: it shells out to the `claude` CLI (`claude -p`, found at ~/.local/bin/claude),
  so it uses Abduel's logged-in Claude with no API key. The prompt carries the paper's
  title/journal/field/DOI/summary/abstract and the running Q&A; the system line tells it to be
  brief and NOT invent findings when the abstract is missing. Code: `Store.runClaude` +
  `ChatView`/`ChatBubble`. The shell-out sets HOME/USER/LOGNAME/PATH explicitly — claude needs
  USER/LOGNAME or it reports "Not logged in" under a launchd-minimal env.
- Rebuild: `bash ~/WeeklyStemBriefing/build-app.sh`
- Offscreen checks: `...WeeklyStemBriefing --render /tmp/wsb.png` (briefing; shows first 3
  entries so chrome fits the frame — the live app scrolls), `--render /tmp/c.png --chat`
  (chat view with a seeded Q&A; the TextField renders as a yellow box in ImageRenderer, an
  artifact only), and `--ask-test` (headless end-to-end test of the Claude shell-out — prints
  a real answer about the top paper). `swiftc` here has NO SwiftUI macro plugin, so `@State`
  is unavailable; keep view-local mutable state on the `Store` (`@Published`) instead.
- Relaunch: `pkill -x WeeklyStemBriefing; launchctl kickstart -k gui/$(id -u)/local.abduel.weeklystembriefing`
- **Movable**: launches in the normal (freely draggable) layer every time — drag it anywhere
  by the background or the top grabber pill. It does NOT float above other windows. The menu-bar
  ✨ has "Pin to desktop (behind windows)" to switch to the stationary desktop layer, plus
  Refresh, Move: top-right/center, Show/Hide, Open data folder. Starts at login via
  `~/Library/LaunchAgents/local.abduel.weeklystembriefing.plist`.

## Cron

Research profile cron "Weekly STEM briefing" (`0 6 * * 1`) runs the generator and texts the
top 3 over BlueBubbles. Report each as: title (italic); journal · field; M/F/You + composite;
tickers if any; free PDF / open page / paywalled with the link when free.

## Pitfalls

- **Runs on `/usr/bin/python3` (system, 3.9.x)** when the widget refresh button calls it — no
  certifi, no defusedxml. Keep `stem_enrich.py`/`weekly_stem_briefing.py` 3.9-safe (no `match`,
  no runtime `X | Y` unions). Enrichment must stay pure-Python for the button to work.
- **OpenAlex field labels are unreliable** — always classify with `stem_enrich`, never trust
  `primary_topic.field`. The `fields/NN` filter is worse (a physics query returns healthcare);
  don't use it.
- **7-day citation counts are ~0**, so `cited_by_count:desc` is nearly arbitrary and prestige
  dominates `f_score`. That is fine — the point is balance + the other two axes, not raw cites.
- **Some OpenAlex works have no abstract** -> `summary` falls back to a generic one-liner.
- **Market/personal scores are keyword heuristics**, not advice. Retune the tables in
  `stem_enrich.py` (`_MARKET`, `_PERSONAL`, `AXIS_WEIGHTS`) as his interests shift.
- **No sci-hub for current papers** (it stopped adding ~2021); the free-text resolver is the
  real route, sci-hub is a convenience that often 404s on recent DOIs.
- `weekly_stem.py`'s own `main()` still writes the OLD single-source `StemBriefing/` payload;
  the merged widget reads `WeeklyStemBriefing/`. Run `weekly_stem_briefing.py`, not `weekly_stem.py`.
