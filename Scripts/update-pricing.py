#!/usr/bin/env python3
"""Refreshes Sources/VibeUsagePricing/Resources/model_prices.json from
LiteLLM's community-maintained pricing dataset.

Usage: python3 Scripts/update-pricing.py

Keeps pricing entries for the model families VibeUsage adapters resolve to:
Anthropic Claude, OpenAI/Codex, Google Gemini, Alibaba Qwen, Moonshot Kimi,
GitHub Copilot, DeepSeek, and xAI Grok. Extend `is_relevant` when adding a
new agent whose logs report a distinct model family.
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

SOURCE_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/model_prices_and_context_window_backup.json"
DEST = Path(__file__).resolve().parent.parent / "Sources/VibeUsagePricing/Resources/model_prices.json"
DATE_SUFFIX_RE = re.compile(r"-\d{8}$")

# Wire names seen in local agent logs that LiteLLM keys under a dated/suffixed name.
FAMILY_ALIASES: dict[str, str] = {
    "kimi-k2": "kimi-k2-0905-preview",
}


def bare_key(key: str) -> str:
    return key.split("/")[-1]


def family_of(key: str) -> str:
    return DATE_SUFFIX_RE.sub("", bare_key(key))


def is_relevant(key: str, entry: dict) -> bool:
    provider = entry.get("litellm_provider", "")
    kl = key.lower()
    bare = bare_key(kl)

    if provider == "anthropic" and "claude" in kl:
        return True
    if provider == "openai" and (
        bare.startswith("gpt-5")
        or bare.startswith("gpt-4")
        or bare.startswith("o1")
        or bare.startswith("o3")
        or bare.startswith("o4")
        or "codex" in bare
    ):
        return True
    if provider == "gemini" and bare.startswith("gemini"):
        return True
    if provider == "vertex_ai-language-models" and bare.startswith("gemini") and "embedding" not in bare:
        return True
    if provider == "dashscope" and "qwen" in bare:
        return True
    if provider == "openrouter" and "/qwen/" in kl:
        return True
    if provider == "moonshot" and "kimi" in bare:
        return True
    if provider == "github_copilot":
        return True
    if provider == "deepseek":
        return True
    if provider == "xai" and "grok" in bare:
        return True
    if provider in {"zai", "zhipu", "zhipuai"} and "glm" in bare:
        return True
    if provider == "minimax" and "minimax" in bare:
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

    for alias, canonical in FAMILY_ALIASES.items():
        if alias not in out and canonical in out:
            out[alias] = out[canonical]

    DEST.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {len(out)} model families to {DEST}", file=sys.stderr)


if __name__ == "__main__":
    main()
