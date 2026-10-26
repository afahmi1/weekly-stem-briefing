#!/usr/bin/env python3
"""Enrichment for the Weekly STEM Briefing — pure Python, no LLM, Python 3.9-safe.

Three jobs, all deterministic so they survive the widget's refresh button (which
calls /usr/bin/python3 directly, with no agent in the loop):

  1. classify_field(item)  -> a canonical STEM field, from journal + title + abstract
     (OpenAlex's own field label is unreliable, so we don't trust it).
  2. summarize(item)        -> one plain-language sentence (~180 chars).
  3. score_axes(item)       -> {"market","field","personal","composite", "tickers"}
     each 0-100. market = public-market relevance (+ the tickers it moves),
     field = scientific impact, personal = appeal to Abduel specifically.

Tune the weight of each axis in the composite via AXIS_WEIGHTS.
"""
from __future__ import annotations

import json
import os
import re

# ----------------------------------------------------------------------------
# Field classification. Order matters: first keyword table that hits wins, so
# the more specific / higher-signal fields are checked first.
# ----------------------------------------------------------------------------
_FIELD_KW = [
    # CS first: LLM/ML terms are high-signal and must beat a stray "lattice"/"space".
    ("CS", ["neural network", "deep learning", "machine learning", "transformer", "algorithm",
            "language model", "llm", "large language", "reinforcement learning", "computer vision",
            "diffusion model", "generative ai", "gpu", "benchmark", "dataset", "state space model"]),
    ("Astronomy", ["galaxy", "galactic", "cosmic ray", "quasar", "stellar", "supernova",
                   "exoplanet", "telescope", "dark matter", "dark energy", "black hole",
                   "astrophys", "nebula", "pulsar", "cosmolog", "interstellar", "gravitational wave"]),
    ("Physics", ["physical review", "quantum", "photon", "qubit", "superconduct", "plasma",
                 "neutrino", "boson", "spintron", "topolog", "particle physics", "lattice",
                 "antiferromagn", "tunnel junction", "laser", "optical cavity", "entangle"]),
    ("Materials", ["material", "alloy", "semiconductor", "nanostruct", "graphene", "thin film",
                   "perovskite", "2d material", "metamaterial", "ceramic", "composite",
                   "crystal", "metal-organic framework", "mof"]),
    ("Chemistry", ["catalys", "synthesis", "molecul", "chemical", "polymer", "organic",
                   "electrochem", "reaction mechanism", "compound", "ligand", "triangulene"]),
    ("Math", ["theorem", "manifold", "conjecture", "stochastic process", "topology",
              "algebraic", "geometr", "numerical analysis", "combinator", "borel", "probability measure"]),
    ("Earth", ["climate", "ocean", "seismic", "atmospher", "glacier", "geolog", "ice sheet",
               "earthquake", "warming", "sea level", "carbon emission", "wildfire", "permafrost"]),
    ("Neuro", ["neuron", "cortex", "cognit", "synap", "prefrontal", "neural circuit",
               "hippocamp", "dopamin", "brain", "insula", "interneuron"]),
    ("Engineering", ["robot", "actuator", "wearable sensor", "fabrication", "prosthe",
                     "microfluidic", "additive manufactur", "3d print", "soft robot"]),
    ("Immuno", ["t cell", "t-cell", "antibod", "immun", "antigen", "vaccine", "dendritic cell",
                "macrophage", "cytokine", "inflammasome", "antiviral"]),
    ("Medicine", ["patient", "clinical trial", "cancer", "tumor", "therapy", "disease",
                  "treatment", "diagnos", "carcinoma", "surviv", "cohort", "mortality",
                  "burden of disease"]),
    ("Bio", ["cell ", "gene ", "genom", "protein", "rna", "enzyme", "mutation", "evolution",
             "species", "organism", "crispr", "transcript", "phylogen", "receptor", "molecular"]),
]

# Map OpenAlex's own field label (the fallback) to our short canonical labels.
_OA_FIELD_MAP = {
    "medicine": "Medicine", "biochemistry, genetics and molecular biology": "Bio",
    "agricultural and biological sciences": "Bio", "immunology and microbiology": "Immuno",
    "pharmacology, toxicology and pharmaceutics": "Pharma", "neuroscience": "Neuro",
    "chemistry": "Chemistry", "chemical engineering": "Chemistry",
    "physics and astronomy": "Physics", "materials science": "Materials",
    "computer science": "CS", "mathematics": "Math", "engineering": "Engineering",
    "earth and planetary sciences": "Earth", "environmental science": "Earth",
    "energy": "Earth", "psychology": "Neuro", "health professions": "Medicine",
    "dentistry": "Medicine", "nursing": "Medicine", "veterinary": "Bio",
}

# STEM fields we actually surface, with a display colour hint the widget can ignore.
STEM_FIELDS = ["Physics", "Astronomy", "Chemistry", "Materials", "CS", "Math", "Earth",
               "Neuro", "Engineering", "Immuno", "Medicine", "Bio", "Pharma"]


def _hay(item: dict) -> str:
    return " ".join([
        (item.get("journal") or ""),
        (item.get("title") or ""),
        (item.get("abstract") or "")[:400],
    ]).lower()


def classify_field(item: dict) -> str:
    """Canonical STEM field from journal + title + abstract keywords."""
    hay = _hay(item)
    for field, kws in _FIELD_KW:
        if any(k in hay for k in kws):
            return field
    raw = (item.get("field") or "").strip().lower()
    if raw in _OA_FIELD_MAP:
        return _OA_FIELD_MAP[raw]
    # item['field'] may already be one of our short labels (from weekly_stem)
    short = (item.get("field") or "").strip()
    if short in STEM_FIELDS:
        return short
    return "STEM"


# ----------------------------------------------------------------------------
# One-sentence plain summary (extractive). Abstracts come from OpenAlex /
# bioRxiv; strip LaTeX, boilerplate, truncate at a sentence boundary.
# ----------------------------------------------------------------------------
_MATH = re.compile(r"\$[^$]*\$")
_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"\s+")


def summarize(item: dict, limit: int = 185) -> str:
    text = (item.get("abstract") or "").strip()
    text = _TAG.sub(" ", text)
    text = _MATH.sub("", text)
    text = re.sub(r"\\[a-zA-Z]+\{?", "", text)          # stray LaTeX commands
    text = _WS.sub(" ", text).strip()
    # drop a leading "Abstract" / "Summary" / "Background" label
    text = re.sub(r"^(abstract|summary|background)[:\s\-]+", "", text, flags=re.I)
    if not text:
        field = classify_field(item)
        jrnl = item.get("journal") or "a peer-reviewed journal"
        return f"New {field.lower()} result in {jrnl}. Open the paper for details."
    # first 1-2 sentences up to the limit
    sentences = re.split(r"(?<=[.!?])\s+", text)
    out = ""
    for s in sentences:
        if not out:
            out = s
        elif len(out) + 1 + len(s) <= limit:
            out = out + " " + s
        else:
            break
    if len(out) > limit:
        out = out[:limit].rsplit(" ", 1)[0].rstrip(",;:") + "\u2026"
    return out.strip()


# ----------------------------------------------------------------------------
# Market axis: which publicly traded names a result plausibly moves, and how
# strongly. (pattern, tickers, weight). Highest matched weight wins the score;
# every matched ticker is collected. Weights are a rough "how investable is this
# headline" prior, not advice.
# ----------------------------------------------------------------------------
_MARKET = [
    (["da vinci", "surgical robot", "robotic surgery", "minimally invasive surg",
      "soft surgical", "endoscop", "catheter-based"], ["ISRG"], 92),
    (["glp-1", "glp1", "semaglutide", "tirzepatide", "obesity drug", "weight loss drug",
      "incretin"], ["LLY", "NVO"], 90),
    (["large language model", "llm", "language model", "transformer", "foundation model",
      "deep learning", "generative ai", "diffusion model", "reinforcement learning",
      "neural network", "gpu", "ai model"], ["NVDA", "MSFT", "GOOGL"], 74),
    (["crispr", "gene editing", "base editing", "prime editing", "gene therapy"],
     ["CRSP", "NTLA", "VRTX", "BEAM"], 70),
    (["mrna", "messenger rna", "mrna vaccine"], ["MRNA", "PFE", "BNTX"], 66),
    (["car-t", "car t", "checkpoint inhibitor", "immunotherapy", "car-nk", "bispecific antibod",
      "antibody-drug conjugate"], ["MRK", "BMY", "GILD"], 60),
    (["quantum comput", "qubit", "quantum processor", "quantum error"], ["IBM", "IONQ", "GOOGL"], 62),
    (["semiconductor", "transistor", "photonic chip", "silicon photonic", "chiplet",
      "euv", "lithograph"], ["TSM", "NVDA", "ASML", "INTC"], 64),
    (["solid-state batter", "lithium metal", "battery electrode", "fast charging batter",
      "sodium-ion", "anode", "cathode"], ["TSLA", "QS", "ALB"], 58),
    (["perovskite", "photovoltaic", "solar cell", "tandem solar"], ["FSLR", "ENPH"], 54),
    (["alzheimer", "amyloid", "dementia", "tau protein", "neurodegener"], ["LLY", "BIIB", "EISAI"], 60),
    (["medical imaging", "ct scan", "mri", "diagnostic imaging", "ultrasound imaging",
      "radiolog"], ["GEHC", "PHG", "SIEGY"], 56),
    (["continuous glucose", "insulin pump", "diabetes device"], ["DXCM", "PODD", "MDT"], 58),
    (["superconduct"], ["IBM"], 40),
    (["fusion", "tokamak", "plasma confinement"], [], 42),
    (["catalys", "green hydrogen", "carbon capture", "electrolyz"], ["LIN", "APD"], 38),
    (["space", "satellite", "rocket", "launch vehicle", "orbital"], ["RKLB", "LMT"], 36),
    (["pfas", "forever chemical", "water treatment"], ["ECL", "XYL"], 34),
    (["clinical trial", "phase iii", "phase 3", "fda approval", "oncology", "cancer"],
     ["XBI"], 32),
    (["vaccine", "antiviral", "pathogen", "outbreak", "pandemic"], ["PFE", "MRK"], 30),
]


def market_axis(item: dict):
    hay = _hay(item)
    best = 0
    tickers = []
    for pats, tks, w in _MARKET:
        if any(p in hay for p in pats):
            best = max(best, w)
            for t in tks:
                if t not in tickers:
                    tickers.append(t)
    if best == 0:
        best = 8  # baseline: pure science, no obvious public-market read
    return min(100, best), tickers[:4]


# ----------------------------------------------------------------------------
# Personal axis: appeal to YOU. Loaded from stem_interests.json so this can be
# shared and retuned without touching code:
#   {"axis_weights": {"market":0.30,"field":0.35,"personal":0.35},
#    "interests": [{"label":"...","weight":90,"match":["keyword","..."]}, ...]}
# Looked for next to this file, then in Application Support. Falls back to the
# defaults below (Abduel's own) when no config exists.
# ----------------------------------------------------------------------------
DEFAULT_INTERESTS = [
    (["da vinci", "surgical robot", "robotic surgery", "minimally invasive surg",
      "intuitive surgical", "ion bronch", "endoscop", "teleoperat", "haptic"], 100),
    (["prosthe", "grip strength", "grasp", "emg", "electromyograph", "biomechanic",
      "finger", "hand function", "tendon", "orthosis", "exoskeleton"], 92),
    (["3d print", "additive manufactur", "fused deposition", "fdm", "stereolithograph",
      "bioprint", "lattice structure"], 86),
    (["medical device", "implant", "biomaterial", "tissue engineer", "biosensor",
      "wearable", "catheter", "fda"], 74),
    (["brain-computer", "brain computer", "neural interface", "neuroprosthe", "bci",
      "neural implant", "motor cortex"], 78),
    (["bird", "avian", "ornitholog", "songbird", "vocalisation", "vocalization",
      "saxicola", "plumage", "migrat"], 68),
    (["large language model", "llm", "ai agent", "autonomous agent", "language model",
      "reinforcement learning", "diagnosis with language"], 66),
    (["robot", "actuator", "soft robot", "control system", "sensor fusion"], 60),
    (["surg", "operating room", "clinical workflow", "patient outcome"], 52),
    (["market", "equity", "trading", "financial", "portfolio", "econometr"], 46),
]

DEFAULT_AXIS_WEIGHTS = {"market": 0.30, "field": 0.35, "personal": 0.35}


def _interests_paths():
    here = os.path.dirname(os.path.abspath(__file__))
    yield os.path.join(here, "stem_interests.json")
    yield os.path.join(os.path.expanduser("~"), "Library", "Application Support",
                       "WeeklyStemBriefing", "interests.json")


def _load_interests():
    """(list of (patterns, weight), axis_weights). Never raises."""
    for p in _interests_paths():
        try:
            if not os.path.exists(p):
                continue
            with open(p, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:  # noqa: BLE001 - a bad config must not break the briefing
            continue
        rows = []
        for b in (data.get("interests") or []):
            pats = [str(x).lower() for x in (b.get("match") or []) if str(x).strip()]
            if pats:
                try:
                    rows.append((pats, int(b.get("weight", 15))))
                except Exception:  # noqa: BLE001
                    continue
        aw = {}
        for k, v in (data.get("axis_weights") or {}).items():
            if k in DEFAULT_AXIS_WEIGHTS:
                try:
                    aw[k] = float(v)
                except Exception:  # noqa: BLE001
                    pass
        if rows:
            return rows, aw
    return DEFAULT_INTERESTS, {}


_PERSONAL, _AW_OVERRIDE = _load_interests()


def personal_axis(item: dict) -> int:
    hay = _hay(item)
    best = 0
    for pats, w in _PERSONAL:
        if any(p in hay for p in pats):
            best = max(best, w)
    if best == 0:
        best = 15
    return min(100, best)


# ----------------------------------------------------------------------------
# Field axis = how much this result moves its own field / industry, NOT generic
# prestige. Built from signals of significance, reach and applicability in the
# paper itself, plus a smaller prestige/citation prior. Pure Python, 0-100.
#   - novelty: is this a new thing, a first, a discovery?
#   - industry/translational: does it reach a product, clinic, or process?
#   - breadth: does it reshape the whole field (review, consortium, standard)?
#   - magnitude: a quantified leap (outperforms, orders of magnitude, record)?
# ----------------------------------------------------------------------------
_FI_NOVELTY = ["for the first time", "first demonstration", "breakthrough", "unprecedented",
               "landmark", "paradigm", "newly discovered", "we discover", "milestone",
               "previously unknown", "novel mechanism", "first-in"]
_FI_INDUSTRY = ["clinical trial", "phase 3", "phase iii", "phase ii", "fda", "therapy",
                "treatment", "vaccine", "medical device", "wearable", "diagnostic",
                "manufactur", "scalable", "scale-up", "commercial", "deployment",
                "industrial", "mass production", "yield", "cost-effective", "throughput",
                "approved", "real-world", "translational", "point-of-care"]
_FI_BREADTH = ["systematic review", "meta-analysis", "consortium", "global burden",
               "nationwide", "guideline", "benchmark", "roadmap", "standard", "framework",
               "population-scale", "atlas", "pan-cancer", "genome-wide"]
_FI_MAGNITUDE = ["outperform", "state-of-the-art", "orders of magnitude", "-fold", "fold higher",
                 "record", "highest", "fastest", "efficiency of", "near-perfect",
                 "significantly outperform", "surpass", "world record"]


def _count_hits(hay: str, terms, each: int, cap: int) -> int:
    hits = sum(1 for t in terms if t in hay)
    return min(cap, hits * each)


def field_axis(item: dict) -> int:
    hay = _hay(item)
    # prestige/citation prior (a flagship journal or fast cites is weak evidence
    # a result matters to its field) — kept small so it can't dominate.
    prestige = 0
    s = item.get("score")
    if s is not None:
        prestige = int(round(max(0.0, min(1.0, (float(s) - 1.0) / 1.6)) * 26))
    cites = item.get("cites") or 0
    cite_comp = min(12, int(cites) * 2)

    novelty = _count_hits(hay, _FI_NOVELTY, 9, 24)
    industry = _count_hits(hay, _FI_INDUSTRY, 9, 32)
    breadth = _count_hits(hay, _FI_BREADTH, 9, 26)
    magnitude = _count_hits(hay, _FI_MAGNITUDE, 6, 18)

    total = prestige + cite_comp + novelty + industry + breadth + magnitude
    return max(12, min(100, total))


AXIS_WEIGHTS = dict(DEFAULT_AXIS_WEIGHTS)
AXIS_WEIGHTS.update(_AW_OVERRIDE)


def score_axes(item: dict) -> dict:
    m, tickers = market_axis(item)
    f = field_axis(item)
    p = personal_axis(item)
    comp = (AXIS_WEIGHTS["market"] * m + AXIS_WEIGHTS["field"] * f +
            AXIS_WEIGHTS["personal"] * p)
    return {"market": m, "field": f, "personal": p,
            "composite": round(comp, 1), "tickers": tickers}


def enrich(item: dict) -> dict:
    """Attach summary, canonical field, and the three axes to an item in place."""
    item["cat"] = classify_field(item)
    item["summary"] = summarize(item)
    ax = score_axes(item)
    item["m_score"] = ax["market"]
    item["f_score"] = ax["field"]
    item["p_score"] = ax["personal"]
    item["composite"] = ax["composite"]
    item["tickers"] = ax["tickers"]
    return item
