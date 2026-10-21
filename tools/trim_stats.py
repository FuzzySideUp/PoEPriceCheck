#!/usr/bin/env python3
"""Drops league-mechanic stat groups from a PoE 1 trade stats.json snapshot.

Crucible, mercenary, scourge, sanctum and ultimatum templates never appear on the items this tool
prices, and some share text with real mods, so a tooltip line could match one of them instead.
Run: python3 -I tools/trim_stats.py Data/poe1/stats.json
"""
import json
import sys

DROP = {"scourge", "mercenary", "ultimatum", "sanctum", "crucible"}


def main():
    path = sys.argv[1]
    stats = json.load(open(path))
    stats["result"] = [g for g in stats["result"] if g["id"] not in DROP]
    with open(path, "w") as f:
        json.dump(stats, f, separators=(",", ":"), ensure_ascii=False)
    print("kept " + ", ".join(f"{g['id']} ({len(g['entries'])})" for g in stats["result"]))


if __name__ == "__main__":
    main()
