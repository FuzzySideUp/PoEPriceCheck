#!/usr/bin/env python3
"""Builds Data/<game>/base_items.json: base type name -> trade category.

Inputs: a RePoE-fork base_items dump (PoE 2: https://repoe-fork.github.io/poe2/base_items.min.json,
PoE 1: https://repoe-fork.github.io/base_items.min.json) and the trade items.json snapshot.
Run: python3 -I tools/gen_base_items.py <repoe.json> Data/poe2 [poe1|poe2]
"""
import json
import sys

CLASS_TO_CATEGORY_POE2 = {
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

CLASS_TO_CATEGORY_POE1 = {
    "Body Armour": "armour.chest", "Helmet": "armour.helmet", "Gloves": "armour.gloves",
    "Boots": "armour.boots", "Shield": "armour.shield", "Quiver": "armour.quiver",
    "Amulet": "accessory.amulet", "Ring": "accessory.ring", "Belt": "accessory.belt",
    "Trinket": "accessory.trinket",
    "Claw": "weapon.claw", "Dagger": "weapon.basedagger", "Rune Dagger": "weapon.runedagger",
    "One Hand Axe": "weapon.oneaxe", "One Hand Sword": "weapon.basesword",
    "Thrusting One Hand Sword": "weapon.rapier", "One Hand Mace": "weapon.basemace",
    "Sceptre": "weapon.sceptre", "Wand": "weapon.wand", "Bow": "weapon.bow",
    "Staff": "weapon.basestaff", "Warstaff": "weapon.warstaff", "Two Hand Axe": "weapon.twoaxe",
    "Two Hand Mace": "weapon.twomace", "Two Hand Sword": "weapon.twosword", "FishingRod": "weapon.rod",
    "Jewel": "jewel.base", "AbyssJewel": "jewel.abyss",
    "LifeFlask": "flask", "ManaFlask": "flask", "HybridFlask": "flask", "UtilityFlask": "flask",
    "Tincture": "tincture", "Relic": "sanctum.relic", "Map": "map",
    "Active Skill Gem": "gem.activegem", "Support Skill Gem": "gem.supportgem",
}


def main():
    repoe_path, out_dir = sys.argv[1], sys.argv[2]
    game = sys.argv[3] if len(sys.argv) > 3 else "poe2"
    classes = CLASS_TO_CATEGORY_POE1 if game == "poe1" else CLASS_TO_CATEGORY_POE2
    repoe = json.load(open(repoe_path))
    trade = json.load(open(f"{out_dir}/items.json"))
    trade_types = {e["type"] for g in trade["result"] for e in g["entries"]}

    out = {}
    for item in repoe.values():
        cat = classes.get(item.get("item_class"))
        name = item.get("name")
        if game == "poe1" and cat == "jewel.base" and name and "Cluster Jewel" in name:
            cat = "jewel.cluster"
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
