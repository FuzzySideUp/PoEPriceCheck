#!/usr/bin/env python3
"""Builds Data/poe2/base_items.json: base type name -> trade category.

Inputs: a RePoE-fork PoE2 base_items dump (https://repoe-fork.github.io/poe2/base_items.min.json)
and the trade2 items.json snapshot. Run: python3 -I tools/gen_base_items.py <repoe.json> Data/poe2
"""
import json
import sys

CLASS_TO_CATEGORY = {
    "Body Armour": "armour.chest", "Helmet": "armour.helmet", "Gloves": "armour.gloves",
    "Boots": "armour.boots", "Shield": "armour.shield", "Buckler": "armour.buckler",
    "Focus": "armour.focus", "Quiver": "armour.quiver",
    "Amulet": "accessory.amulet", "Ring": "accessory.ring", "Belt": "accessory.belt",
    "One Hand Mace": "weapon.onemace", "Two Hand Mace": "weapon.twomace",
    "Warstaff": "weapon.warstaff", "Spear": "weapon.spear", "Bow": "weapon.bow",
    "Crossbow": "weapon.crossbow", "Talisman": "weapon.talisman",
    "One Hand Sword": "weapon.onesword", "Two Hand Sword": "weapon.twosword",
    "Dagger": "weapon.dagger", "One Hand Axe": "weapon.oneaxe", "Two Hand Axe": "weapon.twoaxe",
    "Flail": "weapon.flail", "Claw": "weapon.claw", "Staff": "weapon.staff",
    "Wand": "weapon.wand", "Sceptre": "weapon.sceptre",
    "Jewel": "jewel", "LifeFlask": "flask.life", "ManaFlask": "flask.mana",
    "UtilityFlask": "flask.charm", "Relic": "sanctum.relic",
    "Map": "map.waystone", "TowerAugmentation": "map.tablet",
    "Active Skill Gem": "gem.activegem", "Support Skill Gem": "gem.supportgem",
    "Meta Skill Gem": "gem.metagem",
}


def main():
    repoe_path, out_dir = sys.argv[1], sys.argv[2]
    repoe = json.load(open(repoe_path))
    trade = json.load(open(f"{out_dir}/items.json"))
    trade_types = {e["type"] for g in trade["result"] for e in g["entries"]}

    out = {}
    for item in repoe.values():
        cat = CLASS_TO_CATEGORY.get(item.get("item_class"))
        name = item.get("name")
        if not cat or not name or item.get("release_state") == "unreleased":
            continue
        if name not in trade_types:
            continue
        out.setdefault(name, cat)

    with open(f"{out_dir}/base_items.json", "w") as f:
        json.dump(dict(sorted(out.items())), f, indent=0, ensure_ascii=False)
    print(f"wrote {len(out)} base types")


if __name__ == "__main__":
    main()
