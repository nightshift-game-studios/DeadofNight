#!/usr/bin/env python3
"""Batch C (DESIGN §23) data generator. Idempotent: run from the project root.

  python3 tools/gen_classes.py

Rewrites data/skill_tree.json (keeps every v2 node id + effects, re-lays the grid, adds the bigger tree),
writes data/class_items.json and adds the class legendary cards to data/run_picks.json.
"""
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TREE = os.path.join(ROOT, "data", "skill_tree.json")
CARDS = os.path.join(ROOT, "data", "run_picks.json")
ITEMS = os.path.join(ROOT, "data", "class_items.json")

# The 35 v2 node ids (pre-Batch C). Anything else in the file was made by this script and is rebuilt.
ORIGINAL_IDS = ["mk_root", "mk_aim", "mk_spotter", "mk_longcount", "mk_legend", "mk_key", "sp_root", "sp_powder", "sp_volt_coil", "sp_kindling", "sp_legend", "sp_key", "lg_spare", "lg_wide", "lg_lucky", "lg_black", "lg_gilded", "sv_root", "sv_skin", "sv_breath", "sv_harvest", "sv_legend", "sv_key", "fr_root", "fr_step", "fr_battery", "fr_skyplate", "fr_legend", "fr_key", "so_ram", "so_twin", "so_breacher", "sc_fed", "sc_ghost", "sc_racing_heart"]
tree = json.load(open(TREE))
by_id = {n["id"]: n for n in tree["nodes"] if n["id"] in ORIGINAL_IDS}


def node(id, name, branch, x, y, desc, values=None, effects=None, *, ranks=1, cost=None, requires=None,
         requires_any=None, group="", cls="", typ="passive", drawback="", ability="", requires_rank=None, tags=None):
    if id in by_id:
        raise SystemExit("duplicate node " + id)
    n = {"id": id, "name": name, "branch": branch, "type": typ, "keystone": typ == "keystone", "icon": id,
         "x": x, "y": y, "ranks": ranks, "cost": cost or [2] * ranks, "requires": requires or [],
         "requires_any": requires_any or [], "choice_group": group, "class": cls, "description": desc,
         "drawback": drawback, "values": values or {}, "effects": effects or [], "requires_rank": requires_rank or {},
         "unlocks_cards": [], "tags": tags or [branch]}
    if ability:
        n["ability"] = ability
    by_id[id] = n
    return n


def move(id, x, y, **kw):
    n = by_id[id]
    n["x"], n["y"] = x, y
    n.update(kw)


def E(script, params=None, on=None, iff=None):
    e = {"script": script, "params": params or {}}
    if on:
        e["on"] = on
    if iff:
        e["if"] = iff
    return e


# ------------------------------------------------------------------ general branches (rows 0-7)
# root r0, stat r1, fork r2 (A | B), follow-ups r3, legend r4, keystone r5 (centre) + doctrine fork r5 (sides),
# doctrine follow-ups r6, mastery r7.
GEN = {"marksman": 1, "sapper": 4, "ledger": 7, "survivor": 10, "freerunner": 13}
for pre, br, a, b in [("mk", "marksman", "mk_spotter", "mk_longcount"), ("sp", "sapper", "sp_volt_coil", "sp_kindling"),
                      ("sv", "survivor", "sv_breath", "sv_harvest"), ("fr", "freerunner", "fr_battery", "fr_skyplate")]:
    c = GEN[br]
    move(pre + "_root", c, 0)
    move({"mk": "mk_aim", "sp": "sp_powder", "sv": "sv_skin", "fr": "fr_step"}[pre], c, 1)
    move(a, c - 1, 2)
    move(b, c + 1, 2)
    move(pre + "_legend", c, 4)
    move(pre + "_key", c, 5)
c = GEN["ledger"]
move("lg_spare", c, 0); move("lg_wide", c - 1, 1); move("lg_lucky", c + 1, 1)
move("lg_black", c - 1, 2); move("lg_gilded", c + 1, 2)


def general(pre, br, a, b, a2, b2, d1, d2, d1b, d2b, mastery):
    c = GEN[br]
    node(*a2[:2], br, c - 1, 3, *a2[2:5], cost=[2], requires=[a])
    node(*b2[:2], br, c + 1, 3, *b2[2:5], cost=[2], requires=[b])
    node(*d1[:2], br, c - 1, 5, *d1[2:5], cost=[3], requires=[pre + "_legend"], group=pre + "_doctrine")
    node(*d2[:2], br, c + 1, 5, *d2[2:5], cost=[3], requires=[pre + "_legend"], group=pre + "_doctrine")
    node(*d1b[:2], br, c - 1, 6, *d1b[2:5], cost=[3], requires=[d1[0]])
    node(*d2b[:2], br, c + 1, 6, *d2b[2:5], cost=[3], requires=[d2[0]])
    node(*mastery[:2], br, c, 7, *mastery[2:5], ranks=2, cost=[2, 3], requires_any=[d1b[0], d2b[0]])


general("mk", "marksman", "mk_spotter", "mk_longcount",
    ("mk_painted", "Painted Target", "Precision hits on Marked zombies deal +{pct}% more.", {"pct": 25},
     [E("conditional_damage", {"cond": ["headshot", "target_marked"], "mult": 0.25})]),
    ("mk_patient", "Patient Barrel", "Standing still: +{pct}% gun damage.", {"pct": 20},
     [E("conditional_damage", {"cond": "still", "mult": 0.2, "sources": ["gun"]})]),
    ("mk_cadence", "Steady Cadence", "Each hit in a row: +{per_pct}% damage (max {max} stacks). A miss resets it.", {"per_pct": 3, "max": 10},
     [E("stacking_damage", {"per": 0.03, "max": 10})]),
    ("mk_culling", "Culling Hand", "+{pct}% damage to zombies under {hp_pct}% health.", {"pct": 30, "hp_pct": 35},
     [E("conditional_damage", {"cond": "target_health_below", "threshold": 0.35, "mult": 0.3})]),
    ("mk_called", "Called Shot", "Every hit on a Marked zombie counts as precision.", {},
     [E("force_precision", {"cond": "target_marked"})]),
    ("mk_verdict", "Ricochet Verdict", "Precision kills fire a ray into the nearest zombie within {range}m for {frac_pct}% of the hit.",
     {"range": 8, "frac_pct": 60}, [E("on_event_ray", {"frac": 0.6, "range": 8.0}, ["enemy_killed"], {"is_headshot": True})]),
    ("mk_mastery", "Gunsmith's Patience", "+{add} precision multiplier.", {"add": [0.15, 0.3]},
     [E("stat_mod", {"stat": "headshot_mult_add", "add": [0.15, 0.3]})]))

general("sp", "sapper", "sp_volt_coil", "sp_kindling",
    ("sp_forked", "Forked Current", "Volt arcs jump {chain} more time(s) (up to {chain_range}m per jump).", {"chain": 1, "chain_range": 3},
     [E("element_arc", {"chain": 1, "chain_range": 3.0}, ["hit"], {"element": "volt"})]),
    ("sp_cinders", "Spreading Cinders", "Burning zombies spread fire {spread_radius}m when they die ({spread_dps} dps).", {"spread_radius": 3, "spread_dps": 10},
     [E("element_dot", {"spread_on_death": True, "spread_radius": 3.0, "spread_dps": 10.0, "dur": 3.0}, ["enemy_killed"])]),
    ("sp_satchel", "Satchel Carrier", "+{charges} grenade charge.", {"charges": 1},
     [E("grenade_mod", {"charges": 1})]),
    ("sp_bomblet", "Bomblet Packing", "Grenades split into {cluster} bomblets for {frac_pct}% damage each.", {"cluster": 2, "frac_pct": 25},
     [E("grenade_mod", {"cluster": 2, "cluster_frac": 0.25, "cluster_radius": 2.5}, ["grenade_detonated"])]),
    ("sp_quickfuse", "Quick Fuse", "Grenade cooldown -{pct}%.", {"pct": 15},
     [E("stat_mod", {"stat": "grenade_cd_mult", "mult": 0.85})]),
    ("sp_thunder", "Rolling Thunder", "Grenade kills set off a {radius}m blast for {frac_pct}% of the kill hit; those kills chain ({depth} links).",
     {"radius": 2.5, "frac_pct": 40, "depth": 3},
     [E("on_event_explode", {"damage_frac": 0.4, "radius": 2.5, "knockback": 3.0, "chain": True, "decay": 0.6, "max_depth": 3, "at": "target"}, ["enemy_killed"], {"source": "grenade"})]),
    ("sp_mastery", "Blast Engineer", "+{add_pct}% explosion damage.", {"add_pct": [8, 16]},
     [E("stat_mod", {"stat": "explosion_damage_mult", "add": [0.08, 0.16]})]))

general("sv", "survivor", "sv_breath", "sv_harvest",
    ("sv_gasp", "Last Gasp", "Below {hp_pct}% health, take {red_pct}% less damage.", {"hp_pct": 30, "red_pct": 20},
     [E("damage_in_mod", {"reduction": 0.2, "cond": "health_below", "threshold": 0.3})]),
    ("sv_marrow", "Marrow Gnaw", "Melee kills reset your melee cooldown.", {},
     [E("cooldown_reset", {"what": "melee"}, ["enemy_killed"], {"source": "melee"})]),
    ("sv_rampart", "Rampart Habit", "Overshield cap +{cap}; every round starts with {os} more overshield.", {"cap": 25, "os": 15},
     [E("stat_mod", {"stat": "overshield_cap", "add": 25}), E("grant_overshield", {"amount": 15}, ["round_started"])]),
    ("sv_leech", "Leech Habit", "Every kill heals {amount}.", {"amount": 2},
     [E("heal", {"amount": 2}, ["enemy_killed"])]),
    ("sv_nerve", "Plated Nerve", "+{pct}% damage while you have overshield.", {"pct": 12},
     [E("conditional_damage", {"cond": "has_overshield", "mult": 0.12})]),
    ("sv_redharvest", "Red Harvest", "Precision kills heal {amount} more.", {"amount": 4},
     [E("heal", {"amount": 4}, ["enemy_killed"], {"is_headshot": True})]),
    ("sv_mastery", "Hard to Bury", "+{add} health regen per second.", {"add": [2, 4]},
     [E("stat_mod", {"stat": "regen_rate_add", "add": [2, 4]})]))

general("fr", "freerunner", "fr_battery", "fr_skyplate",
    ("fr_vault", "Ricochet Vault", "Wall jumps refill {pct}% of your magazine.", {"pct": 25},
     [E("refill_mag", {"mode": "fraction", "fraction": 0.25}, ["wall_jumped"])]),
    ("fr_falcon", "Falcon's Due", "Airborne precision kills refund {fraction_pct}% of grenade cooldown.", {"fraction_pct": 20},
     [E("refund_grenade", {"fraction": 0.2}, ["enemy_killed"], {"airborne": True, "is_headshot": True})]),
    ("fr_skid", "Skid Marks", "Slides leave a fire trail ({dps} dps).", {"dps": 12},
     [E("trail_hazard", {"dps": 12.0, "dur": 2.0, "radius": 1.2, "spacing": 0.25}, ["slide_tick"])]),
    ("fr_parkour", "Parkour Habit", "+{jumps} wall jump.", {"jumps": 1},
     [E("stat_mod", {"stat": "max_wall_jumps_add", "add": 1})]),
    ("fr_hotrails", "Hot Rails", "Hits while sliding deal +{pct}%.", {"pct": 20},
     [E("conditional_damage", {"cond": "sliding", "mult": 0.2})]),
    ("fr_catplate", "Cat's Plating", "Each wall jump grants {amount} overshield (cap {cap}).", {"amount": 6, "cap": 30},
     [E("grant_overshield", {"amount": 6, "cap": 30}, ["wall_jumped"])]),
    ("fr_mastery", "Long Stride", "+{add_pct}% move speed.", {"add_pct": [3, 6]},
     [E("stat_mod", {"stat": "move_speed", "add": [0.03, 0.06]})]))

# ledger fork (rows 3-4)
c = GEN["ledger"]
node("lg_purse", "Fat Purse", "ledger", c - 1, 3, "+{pct}% points from kills.", {"pct": 15},
     [E("stat_mod", {"stat": "points_kill_mult", "add": 0.15})], cost=[3], requires_any=["lg_black", "lg_gilded"], group="lg_choice")
node("lg_notes", "Margin Notes", "ledger", c + 1, 3, "+{banishes} banish and +{rerolls} free reroll per match.", {"banishes": 1, "rerolls": 1},
     [E("offer_mod", {"banishes": 1, "free_rerolls": 1})], cost=[3], requires_any=["lg_black", "lg_gilded"], group="lg_choice")
node("lg_gleaning", "Gleaning Eye", "ledger", c - 1, 4, "+{pct}% gear drop chance.", {"pct": 3},
     [E("stat_mod", {"stat": "drop_chance_add", "add": 0.03})], cost=[3], requires=["lg_purse"])
node("lg_draft", "Second Draft", "ledger", c + 1, 4, "Each normal offer slot has +{pct}% chance to be legendary.", {"pct": 5},
     [E("offer_mod", {"lucky_slot_chance": 0.05})], cost=[3], requires=["lg_notes"])

# ------------------------------------------------------------------ class branches (rows 10-16)
# r10 core | r11-13 one path per Q ability (A left, B right; a path's nodes only run while that ability is equipped)
# | r14 oath fork | r15 capstone (unlocks the class legendaries) | r16 two class keystones (one per class).
CLS = {"soldier": 1, "scout": 5, "sexton": 9, "chandler": 13}
ABIL = {"soldier": ("dash", "rally_banner"), "scout": ("adrenaline", "chalk_mark"),
        "sexton": ("grave_bell", "headstone"), "chandler": ("vigil_candle", "ember_brand")}


def klass(cls, pre, core, path_a, path_b, oath_e, oath_f, cap, key1, key2):
    c = CLS[cls]
    aa, ab = ABIL[cls]
    node(core[0], core[1], cls, c, 10, *core[2:5], cost=[1], cls=cls)
    for i, p in enumerate(path_a):
        if p[0] in by_id:
            move(p[0], c - 1, 11 + i, ability=aa, requires=[core[0]] if i == 0 else by_id[p[0]]["requires"])
        else:
            node(p[0], p[1], cls, c - 1, 11 + i, *p[2:5], cost=[2, 2, 3][i:i + 1], cls=cls, ability=aa,
                 requires=[core[0]] if i == 0 else [path_a[i - 1][0]])
    for i, p in enumerate(path_b):
        node(p[0], p[1], cls, c + 1, 11 + i, *p[2:5], cost=[2, 2, 3][i:i + 1], cls=cls, ability=ab,
             requires=[core[0]] if i == 0 else [path_b[i - 1][0]])
    two = [path_a[1][0], path_b[1][0]]
    node(*oath_e[:2], cls, c - 1, 14, *oath_e[2:5], cost=[3], cls=cls, requires_any=two, group=pre + "_oath")
    node(*oath_f[:2], cls, c + 1, 14, *oath_f[2:5], cost=[3], cls=cls, requires_any=two, group=pre + "_oath")
    node(cap[0], cap[1], cls, c, 15, cap[2], cap[3], cap[4] + [E("unlock_cards", {"branch": cls, "tier": "legendary"})],
         cost=[3], cls=cls, requires_any=[oath_e[0], oath_f[0]])
    for k, x in ((key1, c - 1), (key2, c + 1)):
        node(k[0], k[1], cls, x, 16, k[2], k[3], k[5], cost=[4], cls=cls, typ="keystone", drawback=k[4],
             requires=[cap[0]], group=pre + "_keystone")


klass("soldier", "so",
    ("so_core", "Drilled Footing", "+{hp} max health and {pct}% faster reloads.", {"hp": 15, "pct": 8},
     [E("stat_mod", {"stat": "max_health", "add": 15}), E("stat_mod", {"stat": "reload_time_mult", "mult": 0.92})]),
    [("so_ram",), ("so_twin",), ("so_breacher",)],
    [("so_colors", "Field Colors", "Rally Banner reaches +{r}m and stands +{t}s longer.", {"r": 2, "t": 3},
      [E("stat_mod", {"stat": "ab_banner_radius", "add": 2.0}), E("stat_mod", {"stat": "ab_banner_time", "add": 3.0})]),
     ("so_muster", "Muster Call", "Standing at your banner: +{pct}% fire rate.", {"pct": 20},
      [E("stat_mod", {"stat": "fire_rate_mult", "mult": 1.2, "while": "in_field"})]),
     ("so_bulwark", "Bulwark Line", "Zombies at your banner take +{pct}% damage and are slowed {slow_pct}% more.", {"pct": 20, "slow_pct": 15},
      [E("conditional_damage", {"cond": "target_in_field", "mult": 0.2}), E("stat_mod", {"stat": "ab_banner_slow", "add": 0.15})])],
    ("so_oath_iron", "Iron Oath", "Take {red_pct}% less damage while you have overshield.", {"red_pct": 15},
     [E("damage_in_mod", {"reduction": 0.15, "cond": "has_overshield"})]),
    ("so_oath_breach", "Breach Oath", "Kills within {range}m grant {amount} overshield.", {"range": 6, "amount": 5},
     [E("grant_overshield", {"amount": 5, "range": 6.0}, ["enemy_killed"], {"@target_close": True})]),
    ("so_capstone", "Regimental Honors", "Ability cooldowns -{pct}%. Unlocks Soldier legendary cards.", {"pct": 10},
     [E("stat_mod", {"stat": "ability_cd_mult", "mult": 0.9})]),
    ("so_key_vanguard", "Vanguard", "Overshield cap +{cap}. Kills within {range}m grant {os} overshield.", {"cap": 40, "range": 8, "os": 8, "far": 15, "pen_pct": 25},
     "Hits on zombies farther than {far}m deal -{pen_pct}%.",
     [E("stat_mod", {"stat": "overshield_cap", "add": 40}), E("grant_overshield", {"amount": 8, "range": 8.0}, ["enemy_killed"], {"@target_close": True}),
      E("conditional_damage", {"cond": "target_far", "range": 15.0, "mult": -0.25})]),
    ("so_key_quartermaster", "Quartermaster", "+{n} ability charge and +{n} grenade charge.", {"n": 1, "hp_pct": 15},
     "Max health -{hp_pct}%.",
     [E("ability_mod", {"charges": 1}), E("grenade_mod", {"charges": 1}), E("stat_mod", {"stat": "max_health_mult", "mult": 0.85})]))

klass("scout", "sc",
    ("sc_core", "Long Sightline", "Hits on zombies farther than {range}m deal +{pct}%.", {"range": 15, "pct": 15},
     [E("conditional_damage", {"cond": "target_far", "range": 15.0, "mult": 0.15})]),
    [("sc_fed",), ("sc_ghost",), ("sc_racing_heart",)],
    [("sc_broad", "Broad Strokes", "Chalk Mark tags {n} more zombies and reaches +{r}m.", {"n": 4, "r": 10},
      [E("stat_mod", {"stat": "ab_mark_count", "add": 4.0}), E("stat_mod", {"stat": "ab_mark_range", "add": 10.0})]),
     ("sc_deepscore", "Deep Score", "Chalk Marks add +{pct}% damage taken (on top of the base).", {"pct": 15},
      [E("stat_mod", {"stat": "ab_mark_amp", "add": 0.15})]),
     ("sc_tallyman", "Tallyman", "Killing a Marked zombie puts {amount} rounds back in your magazine.", {"amount": 3},
      [E("refill_mag", {"mode": "amount", "amount": 3}, ["enemy_killed"], {"@target_marked": True})])],
    ("sc_oath_skylark", "Skylark Oath", "Airborne kills refund {fraction_pct}% of grenade cooldown.", {"fraction_pct": 15},
     [E("refund_grenade", {"fraction": 0.15}, ["enemy_killed"], {"airborne": True})]),
    ("sc_oath_thicket", "Thicket Oath", "With {count}+ zombies within {radius}m, take {red_pct}% less damage.", {"count": 4, "radius": 6, "red_pct": 20},
     [E("damage_in_mod", {"reduction": 0.2, "cond": "crowded", "count": 4, "radius": 6.0})]),
    ("sc_capstone", "Trailmaster's Badge", "Ability cooldowns -{pct}%. Unlocks Scout legendary cards.", {"pct": 10},
     [E("stat_mod", {"stat": "ability_cd_mult", "mult": 0.9})]),
    ("sc_key_lookout", "Lone Lookout", "Hits on zombies farther than {range}m deal +{pct}% and Mark them for {dur}s.", {"range": 15, "pct": 35, "dur": 3, "close": 6, "pen_pct": 30},
     "Hits within {close}m deal -{pen_pct}%.",
     [E("conditional_damage", {"cond": "target_far", "range": 15.0, "mult": 0.35}),
      E("apply_status", {"status": "mark", "dur": 3.0, "amp": 0.15, "range": 15.0}, ["hit"], {"@target_far": True}),
      E("conditional_damage", {"cond": "target_close", "range": 6.0, "mult": -0.3})]),
    ("sc_key_quicksilver", "Quicksilver", "Ability cooldown -{pct}% and +{n} ability charge.", {"pct": 30, "n": 1, "hp": 20},
     "Max health -{hp}.",
     [E("stat_mod", {"stat": "ability_cd_mult", "mult": 0.7}), E("ability_mod", {"charges": 1}), E("stat_mod", {"stat": "max_health", "add": -20})]))

klass("sexton", "sx",
    ("sx_core", "Gravedigger's Back", "+{hp} max health and +{pct}% melee damage.", {"hp": 20, "pct": 25},
     [E("stat_mod", {"stat": "max_health", "add": 20}), E("stat_mod", {"stat": "melee_damage_mult", "add": 0.25})]),
    [("sx_peal", "Long Peal", "Grave Bell tolls {n} more time.", {"n": 1},
      [E("stat_mod", {"stat": "ab_bell_tolls", "add": 1.0})]),
     ("sx_clapper", "Iron Clapper", "Bell tolls deal +{dmg} damage and reach +{r}m.", {"dmg": 15, "r": 1.5},
      [E("stat_mod", {"stat": "ab_bell_damage", "add": 15.0}), E("stat_mod", {"stat": "ab_bell_radius", "add": 1.5})]),
     ("sx_lasttoll", "Last Toll", "Ability kills grant {amount} overshield.", {"amount": 6},
      [E("grant_overshield", {"amount": 6}, ["enemy_killed"], {"source": "ability"})])],
    [("sx_granite", "Heavy Granite", "Headstone stands +{t}s longer.", {"t": 4},
      [E("stat_mod", {"stat": "ab_stone_time", "add": 4.0})]),
     ("sx_plot", "Wide Plot", "Headstone reaches +{r}m.", {"r": 2},
      [E("stat_mod", {"stat": "ab_stone_radius", "add": 2.0})]),
     ("sx_epitaph", "Epitaph", "Kills at your Headstone refund {fraction_pct}% of grenade cooldown.", {"fraction_pct": 10},
      [E("refund_grenade", {"fraction": 0.1}, ["enemy_killed"], {"@target_in_field": True})])],
    ("sx_oath_mourner", "Mourner's Oath", "Melee kills heal {amount}.", {"amount": 15},
     [E("heal", {"amount": 15}, ["enemy_killed"], {"source": "melee"})]),
    ("sx_oath_wake", "Wake Oath", "Below {hp_pct}% health, +{pct}% damage.", {"hp_pct": 40, "pct": 25},
     [E("conditional_damage", {"cond": "health_below", "threshold": 0.4, "mult": 0.25})]),
    ("sx_capstone", "Churchyard Keys", "Ability cooldowns -{pct}%. Unlocks Sexton legendary cards.", {"pct": 10},
     [E("stat_mod", {"stat": "ability_cd_mult", "mult": 0.9})]),
    ("sx_key_pallbearer", "Pallbearer", "Take {red_pct}% less damage.", {"red_pct": 25, "slow_pct": 12},
     "Move speed -{slow_pct}%.",
     [E("damage_in_mod", {"reduction": 0.25}), E("stat_mod", {"stat": "move_speed", "add": -0.12})]),
    ("sx_key_vesper", "Vesper Watch", "Ability damage +{pct}%; ability hits heal {heal}.", {"pct": 50, "heal": 2, "pen_pct": 15},
     "Gun damage -{pen_pct}%.",
     [E("conditional_damage", {"cond": "ability_source", "mult": 0.5}), E("heal", {"amount": 2}, ["hit"], {"source": "ability"}),
      E("conditional_damage", {"cond": "", "mult": -0.15, "sources": ["gun"]})]))

klass("chandler", "ch",
    ("ch_core", "Wick Trimmer", "Precision hits set zombies on fire ({dps} dps for {dur}s).", {"dps": 10, "dur": 3},
     [E("apply_status", {"status": "burn", "dps": 10.0, "dur": 3.0}, ["hit"], {"is_headshot": True})]),
    [("ch_taper", "Tall Taper", "Vigil Candle burns +{t}s longer.", {"t": 4},
      [E("stat_mod", {"stat": "ab_candle_time", "add": 4.0})]),
     ("ch_candelabra", "Candelabra", "Keep {n} more Vigil Candle lit at once.", {"n": 1},
      [E("stat_mod", {"stat": "ab_candle_count", "add": 1.0})]),
     ("ch_votive", "Votive Glow", "Standing in your candle's light, take {red_pct}% less damage.", {"red_pct": 15},
      [E("damage_in_mod", {"reduction": 0.15, "cond": "in_field"})])],
    [("ch_widebrand", "Wide Brand", "Ember Brand tags {n} more zombies.", {"n": 3},
      [E("stat_mod", {"stat": "ab_brand_count", "add": 3.0})]),
     ("ch_whitehot", "White-hot Brand", "Brand burn +{dps} dps.", {"dps": 15},
      [E("stat_mod", {"stat": "ab_brand_dps", "add": 15.0})]),
     ("ch_cinderchain", "Cinder Chain", "Branded deaths burst for +{dmg} damage.", {"dmg": 30},
      [E("stat_mod", {"stat": "ab_brand_burst", "add": 30.0})])],
    ("ch_oath_smoke", "Smoke Oath", "Hits on burning zombies slow them {slow_pct}% for {dur}s.", {"slow_pct": 25, "dur": 2},
     [E("apply_status", {"status": "slow", "amp": 0.25, "dur": 2.0}, ["hit"], {"@target_burning": True})]),
    ("ch_oath_flare", "Flare Oath", "Killing a burning zombie refunds {fraction_pct}% of grenade cooldown.", {"fraction_pct": 10},
     [E("refund_grenade", {"fraction": 0.1}, ["enemy_killed"], {"@target_burning": True})]),
    ("ch_capstone", "Lamplighter's Round", "Ability cooldowns -{pct}%. Unlocks Chandler legendary cards.", {"pct": 10},
     [E("stat_mod", {"stat": "ability_cd_mult", "mult": 0.9})]),
    ("ch_key_pyre", "Pyre Keeper", "Burning zombies take +{pct}% damage.", {"pct": 30, "hp_pct": 15},
     "Max health -{hp_pct}%.",
     [E("conditional_damage", {"cond": "target_burning", "mult": 0.3}), E("stat_mod", {"stat": "max_health_mult", "mult": 0.85})]),
    ("ch_key_wick", "Short Wick", "Ability cooldowns -{pct}% and {n} more Vigil Candle at once.", {"pct": 35, "n": 1, "short_pct": 30},
     "Candles and brands burn {short_pct}% shorter.",
     [E("stat_mod", {"stat": "ability_cd_mult", "mult": 0.65}), E("stat_mod", {"stat": "ab_candle_count", "add": 1.0}),
      E("stat_mod", {"stat": "ab_candle_time", "mult": 0.7}), E("stat_mod", {"stat": "ab_brand_time", "mult": 0.7})]))

# so/sc existing nodes: keep their chains; costs untouched.
tree["nodes"] = list(by_id.values())
tree["grid"] = {"cols": 15, "rows": 17, "cell_w": 112, "cell_h": 96, "class_rows": [10, 16]}
for b in tree["branches"]:
    if b["id"] in GEN:
        b["x"] = GEN[b["id"]] - (0 if b["id"] == "ledger" else 1)
    if b["id"] in CLS:
        b["x"] = CLS[b["id"]] - 1
        b["blurb"] = {"soldier": "Dash | Rally Banner", "scout": "Adrenaline | Chalk Mark"}.get(b["id"], b["blurb"])
if "sexton" not in [b["id"] for b in tree["branches"]]:
    tree["branches"] += [
        {"id": "sexton", "name": "Sexton", "accent": "sexton_slate", "color": [0.6, 0.58, 0.68], "x": CLS["sexton"] - 1, "class": "sexton", "blurb": "Grave Bell | Headstone"},
        {"id": "chandler", "name": "Chandler", "accent": "chandler_ember", "color": [0.92, 0.55, 0.22], "x": CLS["chandler"] - 1, "class": "chandler", "blurb": "Vigil Candle | Ember Brand"}]
tree["respec"] = {"_help": "DESIGN §23.6. Undo of a pick made this home visit is free. A full respec: first one per character free, then Scrap = clamp(per_point x points spent, min, max).",
                  "currency": "scrap", "free_full_respecs": 1, "per_point": 2, "min": 10, "max": 200}
tree["_help"] = ("v2 meta tree (DESIGN §16, §23). See /workspace/skillz/SKILLTREE_API.md. Rank-indexed params are arrays (index = rank-1); "
                 "scalars apply to every rank. Optional node field \"ability\": the node only runs while that Q ability is equipped. "
                 "Generated by tools/gen_classes.py.")

# ------------------------------------------------------------------ class legendary cards
cards = json.load(open(CARDS))
cmap = {c["id"]: c for c in cards["cards"]}
cmap["L_breakline"]["ability"] = "dash"
cmap["L_redline"]["ability"] = "adrenaline"


def card(id, name, cls, ability, req, summary, desc, values, effects):
    c = {"id": id, "name": name, "tier": "legendary", "branch": cls, "type": "passive", "icon": id, "ranks": 1, "weight": 10,
         "requires_meta": [req], "class": cls, "tags": [cls], "summary": summary, "description": desc, "drawback": "",
         "values": values, "effects": effects}
    if ability:
        c["ability"] = ability
    if id in cmap:
        cmap[id].update(c)
    else:
        cards["cards"].append(c)
        cmap[id] = c


cards["cards"] = [c for c in cards["cards"] if c["id"] not in ("L_unstruck", "L_chalk_outline", "L_funeral_toll", "L_wickfire")]
cmap = {c["id"]: c for c in cards["cards"]}
card("L_unstruck", "Unstruck Colors", "soldier", "rally_banner", "so_capstone", "A banner that holds the room.",
     "Rally Banner stands +{t}s longer, its overshield cap is +{cap}, and you deal +{pct}% damage while at it.", {"t": 6, "cap": 50, "pct": 25},
     [E("stat_mod", {"stat": "ab_banner_time", "add": 6.0}), E("stat_mod", {"stat": "ab_banner_cap", "add": 50.0}),
      E("conditional_damage", {"cond": "in_field", "mult": 0.25})])
card("L_chalk_outline", "Chalk Outline", "scout", "chalk_mark", "sc_capstone", "Every Marked zombie is a precision target.",
     "Chalk Mark tags {n} more zombies, and every hit on a Marked zombie counts as precision.", {"n": 6},
     [E("stat_mod", {"stat": "ab_mark_count", "add": 6.0}), E("force_precision", {"cond": "target_marked"})])
card("L_funeral_toll", "Funeral Toll", "sexton", "", "sx_capstone", "Ability kills ring out in a blast.",
     "Ability kills blast {radius}m around the corpse for {damage} damage. Ability cooldowns -{pct}%.", {"radius": 4, "damage": 80, "pct": 20},
     [E("on_event_explode", {"damage": 80.0, "radius": 4.0, "knockback": 5.0, "icd": 0.3, "at": "target"}, ["enemy_killed"], {"source": "ability"}),
      E("stat_mod", {"stat": "ability_cd_mult", "mult": 0.8})])
card("L_wickfire", "Wickfire Crown", "chandler", "", "ch_capstone", "Burning deaths burst and spread.",
     "Burning zombies you kill burst for {damage} in {radius}m and spread their fire ({dps} dps).", {"damage": 60, "radius": 3, "dps": 20},
     [E("on_event_explode", {"damage": 60.0, "radius": 3.0, "knockback": 3.0, "at": "target"}, ["enemy_killed"], {"@target_burning": True}),
      E("element_dot", {"spread_on_death": True, "spread_radius": 3.0, "spread_dps": 20.0, "dur": 3.0}, ["enemy_killed"])])

# ------------------------------------------------------------------ class items (DESIGN §23.3)
# rank = rarity + 1 (Common..Mythic): value arrays have 5 entries. "line" is the one plain sentence the item card shows.
R5 = lambda *v: list(v)
ITEM_DEFS = [
    # soldier
    {"id": "ci_shock_plate", "class": "soldier", "name": "Shock Plate",
     "line": "Using your ability shoves zombies within {radius}m for {damage} damage.",
     "values": {"radius": 3, "damage": R5(30, 40, 50, 65, 80)},
     "effects": [E("on_event_explode", {"damage": R5(30.0, 40.0, 50.0, 65.0, 80.0), "radius": 3.0, "knockback": 7.0, "at": "player"}, ["ability_used"])],
     "synergy": {"keystone": "so_key_quartermaster", "line": "Each shove refunds {fraction_pct}% of grenade cooldown.", "values": {"fraction_pct": 15},
                 "effects": [E("refund_grenade", {"fraction": 0.15}, ["ability_used"])]}},
    {"id": "ci_tattered_standard", "class": "soldier", "name": "Tattered Standard",
     "line": "While you have overshield, deal +{pct}% damage.",
     "values": {"pct": R5(8, 11, 14, 17, 20)},
     "effects": [E("conditional_damage", {"cond": "has_overshield", "mult": R5(0.08, 0.11, 0.14, 0.17, 0.2)})],
     "synergy": {"keystone": "sv_key", "line": "Kills grant {amount} more overshield.", "values": {"amount": 4},
                 "effects": [E("grant_overshield", {"amount": 4}, ["enemy_killed"])]}},
    {"id": "ci_drumline", "class": "soldier", "name": "Drumline Sash",
     "line": "Gun hits on zombies within {range}m deal +{pct}%.",
     "values": {"range": 8, "pct": R5(10, 15, 20, 25, 30)},
     "effects": [E("conditional_damage", {"cond": "target_close", "range": 8.0, "mult": R5(0.1, 0.15, 0.2, 0.25, 0.3), "sources": ["gun"]})],
     "synergy": {"keystone": "so_key_vanguard", "line": "Kills within {range}m heal {amount}.", "values": {"range": 8, "amount": 5},
                 "effects": [E("heal", {"amount": 5, "range": 8.0}, ["enemy_killed"], {"@target_close": True})]}},
    {"id": "ci_pike_pennant", "class": "soldier", "name": "Pike Pennant",
     "line": "Zombies at your Rally Banner take +{pct}% damage; it stands +{t}s longer.",
     "values": {"pct": R5(10, 14, 18, 22, 30), "t": R5(1, 2, 3, 4, 5)},
     "effects": [E("conditional_damage", {"cond": "target_in_field", "mult": R5(0.1, 0.14, 0.18, 0.22, 0.3)}),
                 E("stat_mod", {"stat": "ab_banner_time", "add": R5(1.0, 2.0, 3.0, 4.0, 5.0)})],
     "synergy": {"keystone": "fr_key", "line": "+{pct}% move speed while at your banner.", "values": {"pct": 15},
                 "effects": [E("stat_mod", {"stat": "move_speed", "add": 0.15, "while": "in_field"})]}},
    # scout
    {"id": "ci_chalk_pouch", "class": "scout", "name": "Chalk Pouch",
     "line": "Precision hits Mark zombies for {dur}s: +{amp_pct}% damage taken.",
     "values": {"dur": 3, "amp_pct": R5(10, 12, 14, 17, 20)},
     "effects": [E("apply_status", {"status": "mark", "dur": 3.0, "amp": R5(0.1, 0.12, 0.14, 0.17, 0.2)}, ["hit"], {"is_headshot": True})],
     "synergy": {"keystone": "mk_key", "line": "Every hit on a Marked zombie counts as precision.", "values": {},
                 "effects": [E("force_precision", {"cond": "target_marked"})]}},
    {"id": "ci_weathervane", "class": "scout", "name": "Weathervane Scarf",
     "line": "Airborne hits deal +{pct}% damage.",
     "values": {"pct": R5(10, 14, 18, 22, 28)},
     "effects": [E("conditional_damage", {"cond": "airborne", "mult": R5(0.1, 0.14, 0.18, 0.22, 0.28)})],
     "synergy": {"keystone": "fr_key", "line": "Airborne kills put {amount} rounds back in the magazine.", "values": {"amount": 2},
                 "effects": [E("refill_mag", {"mode": "amount", "amount": 2}, ["enemy_killed"], {"airborne": True})]}},
    {"id": "ci_longstrap", "class": "scout", "name": "Longstrap Sling",
     "line": "Hits on zombies farther than {range}m deal +{pct}%.",
     "values": {"range": 15, "pct": R5(10, 14, 18, 22, 28)},
     "effects": [E("conditional_damage", {"cond": "target_far", "range": 15.0, "mult": R5(0.1, 0.14, 0.18, 0.22, 0.28)})],
     "synergy": {"keystone": "sc_key_lookout", "line": "Kills beyond {range}m refund {fraction_pct}% of grenade cooldown.", "values": {"range": 15, "fraction_pct": 15},
                 "effects": [E("refund_grenade", {"fraction": 0.15, "range": 15.0}, ["enemy_killed"], {"@target_far": True})]}},
    {"id": "ci_quick_soles", "class": "scout", "name": "Quickstep Soles",
     "line": "Using your ability refills {pct}% of your magazine.",
     "values": {"pct": R5(20, 30, 40, 50, 60)},
     "effects": [E("refill_mag", {"mode": "fraction", "fraction": R5(0.2, 0.3, 0.4, 0.5, 0.6)}, ["ability_used"])],
     "synergy": {"keystone": "sc_key_quicksilver", "line": "Using your ability also grants {amount} overshield.", "values": {"amount": 15},
                 "effects": [E("grant_overshield", {"amount": 15}, ["ability_used"])]}},
    # sexton
    {"id": "ci_sexton_lantern", "class": "sexton", "name": "Sexton's Lantern",
     "line": "Slowed zombies take +{pct}% damage from you.",
     "values": {"pct": R5(8, 12, 16, 20, 25)},
     "effects": [E("conditional_damage", {"cond": "target_slowed", "mult": R5(0.08, 0.12, 0.16, 0.2, 0.25)})],
     "synergy": {"keystone": "sx_key_pallbearer", "line": "Killing a slowed zombie grants {amount} overshield.", "values": {"amount": 5},
                 "effects": [E("grant_overshield", {"amount": 5}, ["enemy_killed"], {"@target_slowed": True})]}},
    {"id": "ci_bell_rope", "class": "sexton", "name": "Bell Rope",
     "line": "Grave Bell tolls {n} more time(s); each toll heals +{h} per zombie hit.",
     "values": {"n": R5(1, 1, 2, 2, 3), "h": R5(0, 1, 1, 2, 2)},
     "effects": [E("stat_mod", {"stat": "ab_bell_tolls", "add": R5(1.0, 1.0, 2.0, 2.0, 3.0)}),
                 E("stat_mod", {"stat": "ab_bell_heal", "add": R5(0.0, 1.0, 1.0, 2.0, 2.0)})],
     "synergy": {"keystone": "sx_key_vesper", "line": "Tolls hit +{dmg} harder.", "values": {"dmg": 20},
                 "effects": [E("stat_mod", {"stat": "ab_bell_damage", "add": 20.0})]}},
    {"id": "ci_mason_chisel", "class": "sexton", "name": "Mason's Chisel",
     "line": "Headstone reaches +{r}m and zombies near it take +{amp_pct}% more damage.",
     "values": {"r": R5(1, 1.5, 2, 2.5, 3), "amp_pct": R5(5, 7, 10, 12, 15)},
     "effects": [E("stat_mod", {"stat": "ab_stone_radius", "add": R5(1.0, 1.5, 2.0, 2.5, 3.0)}),
                 E("stat_mod", {"stat": "ab_stone_amp", "add": R5(0.05, 0.07, 0.1, 0.12, 0.15)})],
     "synergy": {"keystone": "sv_key", "line": "Standing at your Headstone, kills heal {amount} more.", "values": {"amount": 4},
                 "effects": [E("heal", {"amount": 4}, ["enemy_killed"], {"@in_field": True})]}},
    {"id": "ci_burial_shroud", "class": "sexton", "name": "Burial Shroud",
     "line": "Melee hits slow zombies {slow_pct}% for {dur}s.",
     "values": {"slow_pct": R5(20, 28, 35, 42, 50), "dur": 3},
     "effects": [E("apply_status", {"status": "slow", "dur": 3.0, "amp": R5(0.2, 0.28, 0.35, 0.42, 0.5)}, ["hit"], {"source": "melee"})],
     "synergy": {"keystone": "sp_key", "line": "Grenade hits slow zombies {slow_pct}% too.", "values": {"slow_pct": 40},
                 "effects": [E("apply_status", {"status": "slow", "dur": 3.0, "amp": 0.4}, ["hit"], {"source": "grenade"})]}},
    # chandler
    {"id": "ci_tinderbox", "class": "chandler", "name": "Tinderbox",
     "line": "Gun hits on burning zombies deal +{pct}%.",
     "values": {"pct": R5(10, 14, 18, 22, 28)},
     "effects": [E("conditional_damage", {"cond": "target_burning", "mult": R5(0.1, 0.14, 0.18, 0.22, 0.28), "sources": ["gun"]})],
     "synergy": {"keystone": "ch_key_pyre", "line": "Killing a burning zombie heals {amount}.", "values": {"amount": 4},
                 "effects": [E("heal", {"amount": 4}, ["enemy_killed"], {"@target_burning": True})]}},
    {"id": "ci_wax_seal", "class": "chandler", "name": "Wax Seal",
     "line": "Vigil Candle burns +{dps} dps hotter and reaches +{r}m.",
     "values": {"dps": R5(5, 8, 10, 13, 16), "r": R5(0.5, 1, 1, 1.5, 2)},
     "effects": [E("stat_mod", {"stat": "ab_candle_dps", "add": R5(5.0, 8.0, 10.0, 13.0, 16.0)}),
                 E("stat_mod", {"stat": "ab_candle_radius", "add": R5(0.5, 1.0, 1.0, 1.5, 2.0)})],
     "synergy": {"keystone": "ch_key_wick", "line": "Standing in candle light, reload {pct}% faster.", "values": {"pct": 20},
                 "effects": [E("stat_mod", {"stat": "reload_time_mult", "mult": 0.8, "while": "in_field"})]}},
    {"id": "ci_branding_iron", "class": "chandler", "name": "Branding Iron",
     "line": "Ember Brand tags {n} more zombies; branded deaths burst for +{dmg} damage.",
     "values": {"n": R5(1, 1, 2, 2, 3), "dmg": R5(10, 15, 20, 25, 35)},
     "effects": [E("stat_mod", {"stat": "ab_brand_count", "add": R5(1.0, 1.0, 2.0, 2.0, 3.0)}),
                 E("stat_mod", {"stat": "ab_brand_burst", "add": R5(10.0, 15.0, 20.0, 25.0, 35.0)})],
     "synergy": {"keystone": "sp_key", "line": "Killing a branded zombie refunds {fraction_pct}% of grenade cooldown.", "values": {"fraction_pct": 10},
                 "effects": [E("refund_grenade", {"fraction": 0.1}, ["enemy_killed"], {"@target_branded": True})]}},
    {"id": "ci_ashen_mantle", "class": "chandler", "name": "Ashen Mantle",
     "line": "Burning zombies you kill spread fire {r}m ({dps} dps).",
     "values": {"r": 3, "dps": R5(10, 14, 18, 22, 30)},
     "effects": [E("element_dot", {"spread_on_death": True, "spread_radius": 3.0, "spread_dps": R5(10.0, 14.0, 18.0, 22.0, 30.0), "dur": 3.0}, ["enemy_killed"])],
     "synergy": {"keystone": "mk_key", "line": "Precision hits set zombies on fire ({dps} dps).", "values": {"dps": 20},
                 "effects": [E("apply_status", {"status": "burn", "dps": 20.0, "dur": 3.0}, ["hit"], {"is_headshot": True})]}},
]

# ------------------------------------------------------------------ checks
names = {}
for n in tree["nodes"]:
    assert n["name"] not in names, "duplicate name " + n["name"]
    names[n["name"]] = n["id"]
for c in cards["cards"]:
    assert c["name"] not in names, "card name clashes " + c["name"]
    names[c["name"]] = c["id"]
for it in ITEM_DEFS:
    assert it["name"] not in names, "item name clashes " + it["name"]
    names[it["name"]] = it["id"]
    assert it["synergy"]["keystone"] in by_id and by_id[it["synergy"]["keystone"]]["keystone"], it["id"]
missing = [i for i in ORIGINAL_IDS if i not in by_id]
assert not missing, missing

json.dump(tree, open(TREE, "w"), indent="\t", ensure_ascii=False)
open(TREE, "a").write("\n")
json.dump(cards, open(CARDS, "w"), indent="\t", ensure_ascii=False)
open(CARDS, "a").write("\n")
json.dump({"version": 1, "_help": "Class item effects (DESIGN §23.3). rank = rarity + 1 (Common..Mythic); value arrays are per rarity. "
           "'line' is the one sentence the item card shows. 'synergy' applies on top while the named keystone is owned. "
           "Generated by tools/gen_classes.py.", "items": ITEM_DEFS}, open(ITEMS, "w"), indent="\t", ensure_ascii=False)
open(ITEMS, "a").write("\n")

from collections import Counter
cnt = Counter(n["branch"] for n in tree["nodes"])
print("nodes", len(tree["nodes"]), dict(cnt))
print("cards", Counter(c["tier"] for c in cards["cards"]))
print("class items", len(ITEM_DEFS))
