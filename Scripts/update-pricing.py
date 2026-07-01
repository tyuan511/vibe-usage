#!/usr/bin/env python3
"""Refreshes Sources/VibeUsagePricing/Resources/model_prices.json from
LiteLLM's community-maintained pricing dataset.

Usage: python3 Scripts/update-pricing.py

Keeps only Anthropic (Claude) and OpenAI (gpt-5 / o-series / codex) entries,
since those are the two sources VibeUsage ships adapters for. Extend the
`is_relevant` filter here (and Scripts/build the new adapter) when adding a
new agent's model family.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

SOURCE_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json"
DEST = Path(__file__).resolve().parent.parent / "Sources/VibeUsagePricing/Resources/model_prices.json"
DATE_SUFFIX_RE = re.compile(r"-\d{8}$")


def family_of(key: str) -> str:
    return DATE_SUFFIX_RE.sub("", key)


def is_relevant(key: str, entry: dict) -> bool:
    provider = entry.get("litellm_provider", "")
    kl = key.lower()
    if provider == "anthropic" and "claude" in kl:
        return True
    if provider == "openai" and (
        kl.startswith("gpt-5") or kl.startswith("o1") or kl.startswith("o3") or kl.startswith("o4")
        or "codex" in kl
    ):
        return True
    return False


def main() -> None:
    with urllib.request.urlopen(SOURCE_URL) as resp:
        data = json.load(resp)

    out: dict[str, dict[str, float]] = {}
    for key, entry in data.items():
        if not isinstance(entry, dict) or not is_relevant(key, entry):
            continue
        in_cost = entry.get("input_cost_per_token")
        out_cost = entry.get("output_cost_per_token")
        if in_cost is None or out_cost is None:
            continue
        fam = family_of(key)
        rate = {
            "inputPerMillion": round(in_cost * 1_000_000, 6),
            "outputPerMillion": round(out_cost * 1_000_000, 6),
        }
        cache_write = entry.get("cache_creation_input_token_cost")
        cache_read = entry.get("cache_read_input_token_cost")
        if cache_write is not None:
            rate["cacheWritePerMillion"] = round(cache_write * 1_000_000, 6)
        if cache_read is not None:
            rate["cacheReadPerMillion"] = round(cache_read * 1_000_000, 6)
        # Prefer the un-prefixed / non-provider-qualified key as canonical when
        # a family has already been recorded from a "provider/model" alias.
        if fam not in out or "/" not in key:
            out[fam] = rate

    DEST.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {len(out)} model families to {DEST}", file=sys.stderr)


if __name__ == "__main__":
    main()
