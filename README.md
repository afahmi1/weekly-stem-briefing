# Weekly STEM Briefing

A macOS desktop widget that shows a weekly, **field-balanced** digest of new
peer-reviewed science — 14 papers across ~10 disciplines, each with a one-line
summary, a free-PDF link where one exists, and three 0-100 scores:

| Axis | What it measures |
|---|---|
| **M — Market impact** | likelihood this moves a publicly traded company (shows tickers) |
| **F — Field impact** | how much the result matters to *its own* field/industry (novelty, translational reach, breadth, magnitude — not just journal prestige) |
| **Y — Your appeal** | how relevant it is to **you**, from a keyword file you edit (`stem_interests.json`) |

Ranking = weighted mix of the three (defaults 30% / 35% / 35%).

Every paper is filtered so you can actually open it: the click goes **straight to a
PDF** (free copy, Sci-Hub, or the publisher's direct PDF endpoint through your
library proxy). Papers with no reachable PDF are **dropped** from the issue.

---

## Requirements

- macOS 14+ with **Command Line Tools** (`xcode-select --install`) — provides `swiftc`
- Python 3.9+ at `/usr/bin/python3` (ships with macOS)
- Optional: [Claude CLI](https://claude.ai/download) for the in-widget "Ask AI" button

No pip installs needed for the core briefing. (The optional Sci-Hub lookup uses a
separate venv — see *Sci-Hub* below.)

---

## Install

```bash
# 1. put this folder in your home directory, then build the app
cd ~/WeeklyStemBriefing
bash build-app.sh

# 2. generate the first briefing (takes ~30-45s)
/usr/bin/python3 tools/weekly_stem_briefing.py

# 3. launch it
./build/WeeklyStemBriefing.app/Contents/MacOS/WeeklyStemBriefing
```

To start it at login, save this as `~/Library/LaunchAgents/local.weeklystembriefing.plist`
(replace `YOURNAME`), then `launchctl load` it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.weeklystembriefing</string>
  <key>ProgramArguments</key><array>
    <string>/Users/YOURNAME/WeeklyStemBriefing/build/WeeklyStemBriefing.app/Contents/MacOS/WeeklyStemBriefing</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
```

```bash
launchctl load ~/Library/LaunchAgents/local.weeklystembriefing.plist
```

The widget appears top-right. Drag it anywhere by the top bar. The ✨ menu-bar icon
has Refresh, Show/Hide, and the library-proxy switcher.

---

## Personalize it — `tools/stem_interests.json`

**This is the file to edit.** It controls the **Y** score and the ranking weights, so
the feed reorders itself around what *you* care about.

```json
{
  "axis_weights": { "market": 0.30, "field": 0.35, "personal": 0.35 },

  "interests": [
    {
      "label": "Surgical robotics",
      "weight": 100,
      "match": ["da vinci", "surgical robot", "robotic surgery", "haptics"]
    },
    {
      "label": "Mycology",
      "weight": 90,
      "match": ["fungal", "mycorrhiza", "mushroom", "spore"]
    }
  ]
}
```

- `match` — lowercase substrings searched in the title, abstract and journal. The
  **highest-weight matching block wins** the paper's Y score, so put your most
  specific interests at a high `weight`.
- `weight` — 0-100. A paper hitting nothing scores 15 (still readable, just ranked low).
- Add/remove blocks freely. Keep the file valid JSON (commas!).
- `axis_weights` — how much each axis drives the order. Want pure curiosity? Set
  `"personal": 0.8, "market": 0.1, "field": 0.1`. Want industry news? Flip market up.

Changes apply on the next build of the briefing: click ↻ in the widget, or run
`/usr/bin/python3 tools/weekly_stem_briefing.py`.

A valid block needs only `match`; `label` and `weight` are optional (default 15).

---

## Full text — how the click resolves

1. **Free / open access** (Europe PMC, OpenAlex, Unpaywall, Semantic Scholar,
   arXiv/bioRxiv, Crossref) → opens the PDF directly.
2. **Sci-Hub** (optional, see below) → opens its PDF directly, marked `SCI-HUB`.
3. **Publisher direct PDF** (`tools/direct_pdf.py`) → the publisher's own PDF endpoint,
   opened through **your library proxy**.
4. If none of those exist, the paper is dropped from the issue.

### Set your own library proxy

Paywalled clicks are routed through a university EZproxy. The default is SJSU
(`https://libaccess.sjlibrary.org/login?url=`) with BU as an alternate. **Change this
for your own school** in `Sources/main.swift`:

```swift
static func proxyPrefix(_ lib: String) -> String {
    lib == "BU" ? "https://ezproxy.bu.edu/login?url="
                : "https://libaccess.sjlibrary.org/login?url="   // <-- your proxy here
}
```

then rebuild: `bash build-app.sh`. The pattern is almost always
`https://<your-ezproxy-host>/login?url=<target>`.

### Sci-Hub (optional)

`~/WeeklyStemBriefing/tools/fulltext.py` calls a sidecar client if it exists at
`~/.hermes/mcp/scihub_client.py`; without it the resolver just skips Sci-Hub. To enable:

```bash
python3 -m venv ~/.hermes/mcp/scihub-venv
~/.hermes/mcp/scihub-venv/bin/pip install requests pypdf
# then place scihub_client.py there (solves the mirror's proof-of-work captcha)
```

Sci-Hub stopped ingesting papers in ~2021, so it only helps for older literature.
Unlicensed mirror — your call whether to use it.

---

## Files

```
WeeklyStemBriefing/
├── README.md                  # this file
├── build-app.sh               # builds the .app with swiftc (no Xcode)
├── Sources/main.swift         # the widget (AppKit + SwiftUI)
└── tools/
    ├── weekly_stem_briefing.py  # orchestrator: pull -> balance -> enrich -> write
    ├── stem_interests.json      # ← EDIT THIS (your interests + axis weights)
    ├── stem_enrich.py           # field classifier, summarizer, 3-axis scoring
    ├── weekly_stem.py           # OpenAlex fetch, prestige scoring, fulltext pass
    ├── fulltext.py              # legit OA resolver, then Sci-Hub
    └── direct_pdf.py            # publisher direct-PDF endpoint finder
```

Output: `~/Library/Application Support/WeeklyStemBriefing/briefing.json` (the widget reads
this) and a markdown copy in `tools/`-adjacent notes if a research profile exists.

### Useful flags

```bash
/usr/bin/python3 tools/weekly_stem_briefing.py --dry-run     # print the table, write nothing
/usr/bin/python3 tools/weekly_stem_briefing.py --top 20      # more papers
/usr/bin/python3 tools/weekly_stem_briefing.py --no-fulltext # fast, no PDF resolution
/usr/bin/python3 tools/weekly_stem_briefing.py --days 14     # wider window
```

---

## Optional: the "Ask AI" button

Each card has a ✨ ASK pill that opens a chat about that one paper. It shells out to the
`claude` CLI (`~/.local/bin/claude`). If you don't have it, the button shows a clear
"not found" message and everything else still works.

## Optional: Hermes integration

If you run [Hermes Agent](https://hermes-agent.nousresearch.com), drop `skill/SKILL.md`
into `~/.hermes/skills/research/weekly-stem-briefing/` so your agent knows how to refresh
and explain the briefing, and schedule it:

```
cron: 0 6 * * 1   /usr/bin/python3 ~/WeeklyStemBriefing/tools/weekly_stem_briefing.py
```

---

## Caveats

- Scores are keyword heuristics, not predictions. Tune `stem_interests.json` (Y),
  `_MARKET` in `stem_enrich.py` (M tickers), or `_FI_*` in the same file (F).
- Publisher PDF endpoints change; `direct_pdf.py` probes before using one, and anything
  unverified is skipped. Add a DOI prefix to `candidates()` if your field's publisher is
  missing.
- Ad-hoc signed app: first launch may need right-click → Open, or
  `xattr -dr com.apple.quarantine build/WeeklyStemBriefing.app`.
