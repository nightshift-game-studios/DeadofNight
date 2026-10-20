#!/usr/bin/env python3
"""Generates <repo>/data/attachments.json + data/armory.json (Skillz). Asserts the layout rules.
Canonical copy: fps-starter/tools/gen_armory.py (run: python3 tools/gen_armory.py from anywhere).
Names are the original DeadofNight names from /workspace/skillz/DESI_ATTACHMENTS.md."""
import json, os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")  # repo-relative (canonical copy: <repo>/tools/gen_armory.py)

SLOTS = [
    # hides = Desi's split-gun default meshes (weapons/NODE_INVENTORY.txt) a fitted part hides (WeaponRig).
    {"id": "optic", "name": "Optic", "socket": "Rail", "hides": ["IronSights", "DefaultOptic"]},
    {"id": "muzzle", "name": "Muzzle", "socket": "Muzzle", "hides": ["DefaultMuzzle"]},
    {"id": "barrel", "name": "Barrel", "socket": "Barrel", "hides": ["DefaultBarrel", "DefaultMuzzle"]},
    {"id": "grip", "name": "Grip", "socket": "Underbarrel", "hides": ["DefaultGrip"]},
    {"id": "mag", "name": "Magazine", "socket": "MagWell", "hides": ["DefaultMag"]},
    {"id": "stock", "name": "Stock", "socket": "Stock", "hides": ["DefaultStock"]},
]
ALL6 = ["optic", "muzzle", "barrel", "grip", "mag", "stock"]
CLASSES = {  # DESI_ATTACHMENTS.md §1
    "sidearm": {"slots": ["optic", "muzzle", "mag"], "optic_cap": "micro"},
    "hand_cannon": {"slots": ["optic", "muzzle", "barrel", "mag"], "optic_cap": "micro"},
    "auto_rifle": {"slots": ALL6, "optic_cap": "mid"},
    "scout_rifle": {"slots": ALL6, "optic_cap": "long"},
    "pulse_rifle": {"slots": ALL6, "optic_cap": "mid"},
    "smg": {"slots": ALL6, "optic_cap": "short"},
    "shotgun": {"slots": ALL6, "optic_cap": "short"},
    "sniper_rifle": {"slots": ALL6, "optic_cap": "long"},
    "rocket_launcher": {"slots": ["optic", "grip", "mag"], "optic_cap": "mid"},
}
OPTIC_SIZES = ["micro", "short", "mid", "long"]
RIFLES = ["auto_rifle", "scout_rifle", "pulse_rifle"]
LONG = ["sniper_rifle", "scout_rifle"]

def cd(cond, mult, **kw):
    d = {"script": "conditional_damage", "params": {"cond": cond, "mult": mult}}
    d["params"].update(kw)
    return d

A = []
def att(id, name, slot, tier, cost, summary, desc, mods=None, ads=None, flags=None, effects=None,
        classes=None, size=None, drawback="", unique=False, hides=None, extra=None):
    a = {"id": id, "name": name, "slot": slot, "tier": tier, "cost": cost, "unique": unique,
         "summary": summary, "description": desc, "drawback": drawback, "icon": "att_" + id,
         "model": "res://assets/models/attachments/%s/%s.glb" % (slot, id)}
    if hides is not None:
        a["hides"] = hides
    a.update({
         "mods": mods or {}, "ads": ads or {}, "flags": flags or {}, "effects": effects or []})
    if classes:
        a["classes"] = classes
    if size:
        a["size"] = size
    if extra:
        a.update(extra)
    A.append(a)

# ---------------- optics (Rail)
# Optics pass (2026-10-19, Jason via G4M3N): a sight lineup players choose between. DESIGN.md §19, DESI_OPTICS.md, GOOEY_OPTICS.md.
# Each optic-slot part carries an "optic" block (presentation + lineup facts, Armory.optic_profile) and ADS keys merged
# per class by AdsProfile: fov (absolute ADS FOV; magnified glass: from the true magnification vs the 75 deg hip view),
# fov_mult (x the class iron-sight FOV; iron variants), ads_time_mult, sway_mult, spread_mult, move_mult.
import math
HIP_FOV = 75.0
def mag_fov(m):  # true magnification m -> ADS FOV (deg) against the default 75 deg hip view
    return round(math.degrees(2 * math.atan(math.tan(math.radians(HIP_FOV / 2)) / m)), 1)
OVERLAY_MIN_MAG = 4.0  # 4x and up use Gooey's 2D scope overlay; below that the 3D sight picture through the model
OPTIC_TYPES = ["irons", "dot", "holo", "prism", "scope", "unique"]
RARITY = {"irons": "common", "dot": "uncommon", "holo": "uncommon", "prism": "rare", "scope": "rare", "unique": "legendary"}
def optic(type, label, reticle_id, shape, color, size_moa, glow_mode, glow_energy, night, mag=0.0, overlay=None,
          replaces_irons=True, rarity=None, tradeoff=""):
    return {"optic": {
        "type": type, "label": label, "magnification": mag, "reticle_id": reticle_id,
        "reticle": {"shape": shape, "color": color, "size_moa": size_moa},
        "overlay": (mag >= OVERLAY_MIN_MAG) if overlay is None else overlay,
        "glow": {"mode": glow_mode, "energy": glow_energy, "color": color}, "night": night,
        "replaces_irons": replaces_irons, "rarity": rarity or RARITY[type], "tradeoff": tradeoff}}
NOT_SNIPER = [c for c in CLASSES if c != "sniper_rifle"]

# -- iron-sight variants (micro: every gun). They REPLACE the factory IronSights (slot hides), except Witchlight Dabs,
#    which is paint on the factory irons (hides [] and no model: WeaponRig adds three glow dots to the gun's own sights).
att("witchlight_dabs", "Witchlight Dabs", "optic", 1, 2, "Glow paint on your own irons: readable after dusk.",
    "Factory irons with three faint green dots (rear pair + front post). No zoom change.",
    drawback="ADS time +5%: the dots pull the eye.", ads={"ads_time_mult": 1.05}, size="micro", classes=NOT_SNIPER,
    hides=[], extra=dict(optic("irons", "Irons", "three_dot", "three_dot", "#B8F5A0", 1.5, "dim", 1.2, "fair",
                               replaces_irons=False, tradeoff="cheap night aid, slightly slower"), model="", procedural="glow_dots"))
att("wicket_ring", "Wicket Ring", "optic", 1, 2, "Wide ghost ring: snap onto targets, see around them.",
    "Rear aperture + thin post. ADS time -20%, sway -15%, a slightly wider ADS view (x1.06).",
    drawback="ADS spread +12%: a coarse picture at range.",
    ads={"fov_mult": 1.06, "ads_time_mult": 0.8, "sway_mult": 0.85, "spread_mult": 1.12}, size="micro",
    extra=optic("irons", "Irons", "ghost_ring", "ghost_ring", "#2A2622", 0, "none", 0.0, "poor",
                tradeoff="fastest + steadiest, least precise"))
att("mason_notch", "Mason's Notch", "optic", 1, 3, "Square notch and flat post for careful shots.",
    "Notch-and-post irons. ADS spread -15%, ADS view x0.94 (a touch of zoom).",
    drawback="ADS time +10%. Black steel: hard to read at night.",
    ads={"fov_mult": 0.94, "ads_time_mult": 1.1, "spread_mult": 0.85}, size="micro",
    extra=optic("irons", "Irons", "notch_post", "notch_post", "#2A2622", 0, "none", 0.0, "poor",
                tradeoff="precise irons, slower, dark"))
att("foxfire_post", "Foxfire Post", "optic", 1, 4, "Rotten-wood glow bead you can find in pitch dark.",
    "Wide U-notch + a bright foxfire bead. ADS time -5%. The bead glows in the dark.",
    drawback="Precision multiplier -0.1: the fat bead hides distant heads.",
    ads={"ads_time_mult": 0.95}, mods={"headshot_add": -0.1}, size="micro",
    extra=optic("irons", "Irons", "glow_bead", "glow_bead", "#9CFF7A", 4.0, "tritium", 2.5, "good",
                tradeoff="best in the dark, worse headshots"))

# -- reflex / holo (1x-ish; the class iron FOV still wins on rifles: narrowest of class and optic)
att("pinhole", "Pinhole", "optic", 1, 2, "Pistol dot: light zoom, stay mobile while aiming.",
    "ADS zoom 62 FOV. ADS movement penalty halved. ADS time -10%.", ads={"fov": 62, "move_mult": 1.2, "ads_time_mult": 0.9, "sway_mult": 1.1},
    drawback="Tiny window: sway +10%.", size="micro",
    extra=optic("dot", "1x", "pin_dot", "dot", "#FF4A2E", 2.0, "lit", 1.4, "good", tradeoff="mobile + quick, twitchy"))
att("lamplight_reflex", "Lamplight Reflex", "optic", 1, 4, "Warm reflex dot that tightens aimed fire.",
    "ADS zoom 60 FOV. ADS spread -20%.", drawback="Hooded window: ADS time +5%.",
    ads={"fov": 60, "spread_mult": 0.8, "ads_time_mult": 1.05}, size="short",
    extra=optic("dot", "1x", "amber_dot", "dot", "#FFB347", 3.0, "lit", 1.6, "good", tradeoff="tighter aimed fire"))
att("tallow_holo", "Tallow Holo", "optic", 1, 4, "Wide holo window you can fire from the hip.",
    "ADS zoom 58 FOV. Hip-fire spread -15%.", drawback="ADS time +5%: a heavier box.",
    ads={"fov": 58, "ads_time_mult": 1.05}, mods={"hip_spread_mult": 0.85}, size="short",
    extra=optic("holo", "1x", "tallow_ring", "ring_dot", "#F2E6C8", 65.0, "lit", 1.3, "good", tradeoff="hip fire + wide view"))

# -- mid-range glass (3D sight picture through the model)
att("kilnglass_2x", "Kilnglass 2x", "optic", 1, 4, "Squat furnace-glass prism for the middle distance.",
    "2x: ADS zoom %.1f FOV. ADS spread -10%%." % mag_fov(2.0),
    drawback="ADS time +15%. Sway +15%. ADS movement -10%.",
    ads={"fov": mag_fov(2.0), "ads_time_mult": 1.15, "sway_mult": 1.15, "spread_mult": 0.9, "move_mult": 0.9}, size="mid",
    extra=optic("prism", "2x", "kiln_chevron", "chevron", "#FF6A2A", 4.0, "lit", 1.2, "fair", mag=2.0,
                tradeoff="first zoom, early and cheap"))
att("crows_eye_3x", "Crow's Eye 3x", "optic", 2, 5, "Prism scope that punishes targets past falloff.",
    "3x: ADS zoom %.1f FOV. +15%% damage beyond falloff range while aiming." % mag_fov(3.0),
    drawback="ADS time +25%. Sway +30%. ADS movement -15%.",
    ads={"fov": mag_fov(3.0), "move_mult": 0.85, "ads_time_mult": 1.25, "sway_mult": 1.3},
    effects=[cd(["ads", "beyond_falloff"], 0.15, sources=["gun"])], size="mid",
    extra=optic("prism", "3x", "crow_foot", "crow_foot", "#E3D9BD", 6.0, "dim", 0.6, "fair", mag=3.0,
                tradeoff="reach + falloff damage, heavy"))

# -- high zoom (Gooey's 2D scope overlay)
att("longwatch_6x", "Longwatch 6x", "optic", 3, 7, "Long scope with a full overlay and heavier crits.",
    "6x: ADS zoom %.1f FOV with scope overlay. Precision multiplier +0.4." % mag_fov(6.0),
    drawback="ADS time +45%. Sway +60%. Hip-fire spread +40%. ADS movement -25%.",
    ads={"fov": mag_fov(6.0), "move_mult": 0.75, "ads_time_mult": 1.45, "sway_mult": 1.6},
    mods={"headshot_add": 0.4, "hip_spread_mult": 1.4}, flags={"scope_overlay": True}, classes=LONG, size="long",
    extra=optic("scope", "6x", "longwatch_mil", "mil_dot", "#E3D9BD", 0.0, "none", 0.0, "poor", mag=6.0,
                tradeoff="crit zoom, slow and swaying"))
att("belfry_8x", "Belfry 8x", "optic", 3, 8, "Bell-tower glass: see the far dead before they see you.",
    "8x: ADS zoom %.1f FOV with scope overlay. Precision multiplier +0.5. Lantern-lit centre dot." % mag_fov(8.0),
    drawback="ADS time +60%. Sway +80%. Hip-fire spread +50%. ADS movement -30%.",
    ads={"fov": mag_fov(8.0), "move_mult": 0.7, "ads_time_mult": 1.6, "sway_mult": 1.8},
    mods={"headshot_add": 0.5, "hip_spread_mult": 1.5}, flags={"scope_overlay": True}, classes=["sniper_rifle"], size="long",
    extra=optic("scope", "8x", "belfry_post", "post_crosshair", "#FFD27A", 1.0, "lit", 1.0, "fair", mag=8.0,
                tradeoff="most zoom + crits, slowest, tunnel vision"))

# -- uniques (playstyle optics; kept from the art passes)
att("gravesight", "Gravesight", "optic", 3, 8, "Outlines elites and bosses through walls.",
    "ADS zoom 45 FOV. Bosses and elites are outlined through walls. +15% damage to them.",
    drawback="ADS time +15%. Sway +10%.",
    ads={"fov": 45, "ads_time_mult": 1.15, "sway_mult": 1.1}, flags={"outline_elites": True},
    effects=[cd("target_boss", 0.15)], size="mid", unique=True,
    extra=optic("unique", "1.8x", "grave_cross", "cross", "#7CFFB2", 3.0, "lit", 1.6, "good", tradeoff="boss hunter"))
att("heartbeat_counter", "Heartbeat Counter", "optic", 2, 4, "Rail box that counts the dead around you.",
    "HUD shows zombies within 10 m. +12% damage while 5 or more are that close.",
    drawback="No zoom: ADS keeps the iron-sight FOV.", flags={"heartbeat_counter": True, "heartbeat_radius": 10.0},
    effects=[cd("crowded", 0.12, count=5, radius=10.0)], size="micro", unique=True,
    # Art pass 2: the box sits off to the gun-left of the Rail and keeps the iron sights (Desi VERIFY_BATCH2 / G4M3N).
    hides=[], extra=optic("unique", "Irons", "factory_irons", "factory", "#2A2622", 0, "none", 0.0, "poor",
                          replaces_irons=False, tradeoff="crowd damage, factory irons"))

# The no-attachment choice (shown first in the lineup). Not an attachment: the gun's own IronSights, or the sniper's
# built-in DefaultOptic scope (2D overlay, AdsProfile sniper FOV 35).
FACTORY_OPTIC = {
    "irons": {"id": "", "name": "Factory Irons", "summary": "The gun's own sights.", "cost": 0,
              "optic": {"type": "irons", "label": "Irons", "magnification": 0.0, "reticle_id": "factory_irons",
                        "reticle": {"shape": "factory", "color": "#2A2622", "size_moa": 0.0}, "overlay": False,
                        "glow": {"mode": "none", "energy": 0.0, "color": "#2A2622"}, "night": "poor",
                        "replaces_irons": False, "rarity": "common", "tradeoff": "free baseline"}},
    "scope": {"id": "", "name": "Factory Scope", "summary": "The sniper's own scope.", "cost": 0,
              "optic": {"type": "scope", "label": "2.4x", "magnification": 2.4, "reticle_id": "factory_scope",
                        "reticle": {"shape": "mil_dot", "color": "#E3D9BD", "size_moa": 0.0}, "overlay": True,
                        "glow": {"mode": "none", "energy": 0.0, "color": "#E3D9BD"}, "night": "poor",
                        "replaces_irons": False, "rarity": "common", "tradeoff": "free baseline"}},
}

# ---------------- muzzles (Muzzle)
amb = lambda m: cd("target_unhurt", m, sources=["gun"])
att("pocket_hush", "Pocket Hush", "muzzle", 1, 3, "Short can: hidden tracers, ambush first hits.",
    "No tracers, muzzle flash -80%. +20% damage to unhurt zombies.", drawback="Range -10%.",
    mods={"range_mult": 0.9}, flags={"tracer_hidden": True, "flash_mult": 0.2}, effects=[amb(0.2)],
    classes=["sidearm", "hand_cannon", "smg"])
att("hush_can", "Hush Can", "muzzle", 1, 4, "Rifle suppressor built for opening shots.",
    "No tracers, muzzle flash -80%. +25% damage to unhurt zombies.", drawback="Range -8%.",
    mods={"range_mult": 0.92}, flags={"tracer_hidden": True, "flash_mult": 0.2}, effects=[amb(0.25)],
    classes=RIFLES + ["smg", "sniper_rifle"])
att("mourners_sleeve", "Mourner's Sleeve", "muzzle", 2, 6, "Heavy wrapped can: silent, brutal first shot.",
    "No tracers or flash. +40% damage to unhurt zombies.", drawback="Swap time +15%.",
    mods={"swap_mult": 1.15}, flags={"tracer_hidden": True, "flash_mult": 0.0}, effects=[amb(0.4)], classes=LONG)
att("splitjaw_brake", "Splitjaw Brake", "muzzle", 1, 3, "Muzzle brake: much less kick, a lot more flash.",
    "Recoil -40%.", drawback="Muzzle flash +80%.", mods={"recoil_mult": 0.6}, flags={"flash_mult": 1.8})
att("flare_cage", "Flare Cage", "muzzle", 1, 2, "Flash hider that keeps your view clean.",
    "Muzzle flash -60%. Spread -8%.", mods={"spread_mult": 0.92}, flags={"flash_mult": 0.4},
    classes=["sidearm", "hand_cannon", "smg", "sniper_rifle"] + RIFLES)
att("tightjaw_choke", "Tightjaw Choke", "muzzle", 1, 3, "Tight choke: narrow pattern with longer reach.",
    "Pellet spread -40%. Range +25%.", drawback="2 fewer pellets.",
    mods={"spread_mult": 0.6, "range_mult": 1.25, "pellets_add": -2}, classes=["shotgun"])
att("bell_choke", "Bell Choke", "muzzle", 2, 6, "Flared choke: wide cone that drags the horde down.",
    "+3 pellets, spread +60%. Hits slow zombies 25% for 1.5 s.", drawback="Range -25%.",
    mods={"spread_mult": 1.6, "pellets_add": 3, "range_mult": 0.75},
    effects=[{"script": "apply_status", "on": ["hit"], "if": {"source": "gun"},
              "params": {"status": "slow", "dur": 1.5, "amp": 0.25}}], classes=["shotgun"], unique=True)

# ---------------- barrels (Barrel)
att("long_spine_barrel", "Long Spine Barrel", "barrel", 1, 4, "Extended barrel: reach over handling.",
    "Range +30%.", drawback="Swap time +15%. ADS movement -10%.",
    mods={"range_mult": 1.3, "swap_mult": 1.15}, ads={"move_mult": 0.9})
att("sawn_stub", "Sawn Stub", "barrel", 1, 3, "Cut-down barrel for point-blank work.",
    "Swap time -25%. +20% damage within 6 m.", drawback="Range -30%. Spread +20%.",
    mods={"range_mult": 0.7, "swap_mult": 0.75, "spread_mult": 1.2},
    effects=[cd("close", 0.2, sources=["gun"], range=6.0)],
    # Art pass 2 (G4M3N decision): on the shotgun the bead (IronSights) would float ahead of the cut barrel, so hide it there.
    # Art pass 2c (G4M3N approved): also hide the shotgun's under-barrel mag tube (DefaultMag, x 0.18-0.55, ran ~61 mm past
    # the stub). Kept even after Desi ships a short tube stub inside sawn_stub (that stub then shows instead).
    # hides_by_class[archetype] replaces hides/slot hides for that archetype only (WeaponRig.hides_for).
    # Art pass 3 (Desi 12:54): sawn_stub.glb has a MagTubeStub child (short tube) for the shotgun only.
    # inner_hides[archetype or "*"] = nodes INSIDE this attachment hidden on that host (WeaponRig.inner_hides_for).
    extra={"hides_by_class": {"shotgun": ["DefaultBarrel", "DefaultMuzzle", "IronSights", "DefaultMag"]},
           "inner_hides": {"*": ["MagTubeStub"], "shotgun": []}},
    # Art pass 2b (G4M3N): no Sawn Stub on the revolver (hand_cannon) or the LMG (pulse_rifle): every other barrel class.
    classes=[c for c, v in CLASSES.items() if "barrel" in v["slots"] and c not in ("hand_cannon", "pulse_rifle")])
att("fluted_cooler", "Fluted Cooler", "barrel", 2, 5, "Heat-shrouded barrel that runs faster.",
    "Fire rate +8%.", drawback="Recoil +10%.", mods={"rpm_mult": 1.08, "recoil_mult": 1.1},
    classes=RIFLES + ["smg", "hand_cannon", "shotgun"])
att("gutter_ported_barrel", "Gutter Ported Barrel", "barrel", 1, 4, "Top ports bleed off recoil.",
    "Recoil -25%.", drawback="Range -10%.", mods={"recoil_mult": 0.75, "range_mult": 0.9})

# ---------------- grips (Underbarrel)
att("fence_post", "Fence Post", "grip", 1, 2, "Vertical foregrip: steady but heavy in the hand.",
    "Recoil -20%.", drawback="ADS movement -10%.", mods={"recoil_mult": 0.8}, ads={"move_mult": 0.9})
att("knuckle_stub", "Knuckle Stub", "grip", 1, 2, "Stubby grip for fast hands.",
    "Swap time -15%. Recoil -8%.", mods={"swap_mult": 0.85, "recoil_mult": 0.92})
att("lean_grip", "Lean Grip", "grip", 1, 3, "Angled grip: move almost freely while aiming.",
    "ADS movement penalty cut by a third. ADS spread -10%.", ads={"move_mult": 1.3, "spread_mult": 0.9})
att("halfmoon_stop", "Halfmoon Stop", "grip", 1, 2, "Hand stop for shooting on the slide.",
    "Spread -35% while sliding.",
    effects=[{"script": "stat_mod", "params": {"stat": "spread_mult", "mult": 0.65, "while": "sliding"}}])
att("crutch_bipod", "Crutch Bipod", "grip", 2, 4, "Folding bipod: plant your feet and own the lane.",
    "Standing still: spread -50% and +10% damage.", drawback="ADS movement -20%.", ads={"move_mult": 0.8},
    flags={"bipod": True},
    effects=[{"script": "stat_mod", "params": {"stat": "spread_mult", "mult": 0.5, "while": "still"}},
             cd("still", 0.1, sources=["gun"])], classes=LONG + ["auto_rifle"])
att("second_mouth", "Second Mouth", "grip", 3, 8, "Underbarrel launcher that answers your hits.",
    "A gun hit fires a 3 m blast at the target for 120% of the hit (every 6 s).", drawback="Swap time +20%.",
    mods={"swap_mult": 1.2},
    effects=[{"script": "on_event_explode", "on": ["hit"], "if": {"source": "gun"},
              # from = gun-rig node the blast visibly launches from (Tube/LauncherMuzzle on second_mouth.glb)
              "params": {"damage_frac": 1.2, "radius": 3.0, "icd": 6.0, "knockback": 5.0, "from": "LauncherMuzzle"}}],
    classes=RIFLES + ["smg", "shotgun"], unique=True)
att("lantern_rail", "Lantern Rail", "grip", 2, 6, "Flashlight beam that staggers what it finds.",
    "Gun hits slow zombies 35% for 1 s. Press F for its beam.", flags={"flashlight": True},
    effects=[{"script": "apply_status", "on": ["hit"], "if": {"source": "gun"},
              "params": {"status": "slow", "dur": 1.0, "amp": 0.35}}],
    classes=RIFLES + ["smg", "shotgun", "sniper_rifle"], unique=True,
    # Art pass 2: F-toggle camera beam like the Mine Lamp (Armory.has_flashlight), warmer + a little tighter.
    extra={"light_energy": 7.0, "light_range": 24.0, "light_angle": 24.0, "light_attenuation": 1.1,
           "light_color": [1.0, 0.86, 0.62]})
# Mine Lamp: Mapz F-toggle SpotLight3D on the camera. Underbarrel so optic + lamp can both be fitted
# (Rail is the optic socket and would conflict). Gates player.gd via Armory.has_mine_lamp(arch).
att("mine_lamp", "Mine Lamp", "grip", 2, 5, "Underbarrel lamp: press F for a night beam.",
    "Toggle a camera flashlight with F while this weapon is out.",
    flags={"flashlight": True, "mine_lamp": True},
    classes=RIFLES + ["smg", "shotgun", "sniper_rifle"], unique=True, hides=[],
    # Camera SpotLight3D values (Armory.flashlight_config). 2.4 (Mapz patch) barely read at night; 7.0 per the art pass.
    extra={"light_energy": 7.0, "light_range": 22.0, "light_angle": 28.0, "light_attenuation": 1.1,
           "light_color": [0.92, 0.95, 1.0]})
att("bonesaw_bayonet", "Bonesaw Bayonet", "grip", 2, 5, "Blade under the muzzle for melee builds.",
    "Melee damage +60% with this weapon out.", drawback="Swap time +10%.", mods={"swap_mult": 1.1},
    effects=[cd("", 0.6, sources=["melee"])], classes=RIFLES + ["smg", "shotgun"], unique=True)

# ---------------- mags (MagWell)
att("fat_drum", "Fat Drum", "mag", 2, 4, "Drum mag: shoot longer, reload slower.",
    "Magazine +60%.", drawback="Reload time +35%. Swap time +15%.",
    mods={"mag_mult": 1.6, "reload_mult": 1.35, "swap_mult": 1.15}, classes=RIFLES + ["smg", "sniper_rifle"])
att("quickpull_clip", "Quickpull Clip", "mag", 1, 3, "Pull-tab mag for fast reloads.",
    "Reload time -25%.", drawback="Magazine -15%.", mods={"reload_mult": 0.75, "mag_mult": 0.85},
    classes=["sidearm", "smg", "sniper_rifle", "rocket_launcher"] + RIFLES)
att("twin_taped_mags", "Twin-Taped Mags", "mag", 1, 3, "Two mags taped: flip and go.",
    "Reload time -30%.", drawback="One fewer reserve magazine.", mods={"reload_mult": 0.7, "reserve_mags_add": -1},
    classes=RIFLES + ["smg"])
att("speedloader_ring", "Speedloader Ring", "mag", 1, 3, "Cylinder speedloader.", "Reload time -40%.",
    mods={"reload_mult": 0.6}, classes=["hand_cannon"])
att("shell_saddle", "Shell Saddle", "mag", 1, 3, "Side carrier: more shells on hand.",
    "+2 reserve loads. Reload time -10%.", mods={"reserve_mags_add": 2, "reload_mult": 0.9}, classes=["shotgun"])
att("ember_window_mag", "Ember Window Mag", "mag", 3, 7, "Incendiary rounds: precision hits ignite.",
    "Precision hits set zombies burning (8 dps for 3 s).", drawback="Magazine -15%.", mods={"mag_mult": 0.85},
    effects=[{"script": "apply_status", "on": ["hit"], "if": {"source": "gun", "is_headshot": True},
              "params": {"status": "burn", "dur": 3.0, "dps": 8.0}}],
    classes=RIFLES + ["smg", "sidearm", "sniper_rifle"], unique=True)  # art pass 2: no hand_cannon (no box mag on a revolver)
att("echo_drum", "Echo Drum", "mag", 3, 8, "Spinning drum that returns rounds on precision kills.",
    "Magazine +30%. Precision kills put 3 rounds back in the mag.", drawback="Reload time +25%.",
    mods={"mag_mult": 1.3, "reload_mult": 1.25},
    effects=[{"script": "refill_mag", "on": ["enemy_killed"], "if": {"source": "gun", "is_headshot": True},
              "params": {"mode": "amount", "amount": 3}}], classes=RIFLES + ["smg", "sniper_rifle"], unique=True)

# ---------------- stocks (Stock)
att("wire_stock", "Wire Stock", "stock", 1, 2, "Skeletal stock: light and quick.",
    "Swap time -15%. ADS movement +10%.", drawback="Recoil +10%.",
    mods={"swap_mult": 0.85, "recoil_mult": 1.1}, ads={"move_mult": 1.1})
att("padded_stock", "Padded Stock", "stock", 1, 3, "Heavy padded stock that soaks recoil.",
    "Recoil -25%.", drawback="Swap time +10%.", mods={"recoil_mult": 0.75, "swap_mult": 1.1})
att("ratchet_stock", "Ratchet Stock", "stock", 2, 4, "Adjustable stock tuned for aimed fire.",
    "ADS spread -15%. Recoil -10%.", ads={"spread_mult": 0.85}, mods={"recoil_mult": 0.9})
att("stub_cap", "Stub Cap", "stock", 1, 2, "No stock at all: snap to targets.",
    "Swap time -30%. ADS movement +15%.", drawback="Hip-fire spread +15%.",
    mods={"swap_mult": 0.7, "hip_spread_mult": 1.15}, ads={"move_mult": 1.15})

# Per-gun exclusions (art pass 2b, G4M3N): parts that can't be equipped together on these archetypes (Armory.exclusion_*).
# Old saves holding a blocked combo unequip the LAST listed part on load (Armory.sanitize_armory); it stays owned.
EXCLUSIONS = [
    {"id": "smg_stub_bayonet", "classes": ["smg"], "parts": ["bonesaw_bayonet", "sawn_stub"],
     "reason": "The SMG's Sawn Stub is too short to carry the Bonesaw Bayonet's blade."},
    # Art pass 3 (G4M3N): the Shell Saddle carries a full-length TubeMag (x 0.18-0.55) that runs ~70 mm past the (scaled) Sawn Stub
    # and overlaps the stub's own MagTubeStub. Old saves keep the Sawn Stub and unequip the Shell Saddle (last listed).
    {"id": "shotgun_stub_saddle", "classes": ["shotgun"], "parts": ["sawn_stub", "shell_saddle"],
     "reason": "The Shell Saddle's full-length tube won't fit under a Sawn Stub."},
]

TIER_REQ = {1: 0, 2: 2, 3: 4}  # weapon upgrade tier needed to EQUIP an attachment of this tier
MOD_KEYS = {"damage_mult", "rpm_mult", "mag_mult", "reload_mult", "spread_mult", "hip_spread_mult", "recoil_mult",
            "range_mult", "swap_mult", "pellets_add", "headshot_add", "reserve_mags_add"}
ADS_KEYS = {"fov", "fov_mult", "move_mult", "spread_mult", "ads_time_mult", "sway_mult"}
ids = set()
for a in A:
    assert a["id"] not in ids, a["id"]; ids.add(a["id"])
    assert a["slot"] in ALL6
    assert set(a["mods"]) <= MOD_KEYS, (a["id"], a["mods"])
    assert set(a["ads"]) <= ADS_KEYS, a["id"]
    assert len(a["summary"]) <= 60 and not any(c.isdigit() for c in a["summary"]), a["id"]
    assert a["tier"] in TIER_REQ and 2 <= a["cost"] <= 8
    comp = [c for c, v in CLASSES.items() if a["slot"] in v["slots"] and (not a.get("classes") or c in a["classes"])]
    if a["slot"] == "optic":
        comp = [c for c in comp if OPTIC_SIZES.index(a["size"]) <= OPTIC_SIZES.index(CLASSES[c]["optic_cap"])]
    assert comp, a["id"]
    for c in a.get("classes", []):
        assert c in CLASSES
by_id = {a["id"]: a for a in A}
# ---- optics pass checks (DESIGN.md §19): every optic-slot part has an optic block; the lineup is priced on the curve.
REPO = os.path.join(ROOT, "..")
PRICE_BANDS = {"irons": (2, 4), "dot": (2, 4), "holo": (3, 5), "prism": (4, 6), "scope": (7, 8), "unique": (4, 8)}
LINEUP = [a["id"] for a in A if a["slot"] == "optic"]
for a in A:
    if a["slot"] != "optic":
        continue
    o = a.get("optic")
    assert o and o["type"] in OPTIC_TYPES and o["reticle_id"] and o["glow"]["mode"] in ("none", "dim", "lit", "tritium"), a["id"]
    assert o["night"] in ("poor", "fair", "good") and o["tradeoff"], a["id"]
    lo, hi = PRICE_BANDS[o["type"]]
    assert lo <= a["cost"] <= hi, (a["id"], a["cost"], o["type"])
    m = float(o["magnification"])
    assert o["overlay"] == (m >= OVERLAY_MIN_MAG) or a.get("flags", {}).get("scope_overlay"), a["id"]
    assert bool(a.get("flags", {}).get("scope_overlay")) == o["overlay"], a["id"]  # one source of truth for the overlay
    if m >= 1.5 and o["type"] != "unique":
        assert abs(a["ads"]["fov"] - mag_fov(m)) < 0.06, (a["id"], a["ads"]["fov"])  # true magnification vs the 75 deg hip
    if o["type"] == "scope":
        assert a["tier"] == 3 and a["size"] == "long", a["id"]  # high zoom: Rework IV
    if o["type"] == "irons":
        assert a["size"] == "micro" and "fov" not in a["ads"], a["id"]  # irons: class FOV x fov_mult only
        assert (a.get("hides", None) == []) == (not o["replaces_irons"]), a["id"]  # only a replacing set hides IronSights
    # no strictly-better optic: every non-unique part pays somewhere (a drawback line and a stat above 1 / a negative add)
    if o["type"] != "unique":
        ad = a["ads"]
        worse = (ad.get("ads_time_mult", 1) > 1 or ad.get("sway_mult", 1) > 1 or ad.get("spread_mult", 1) > 1 or
                 ad.get("move_mult", 1) < 1 or a["mods"].get("headshot_add", 0) < 0 or a["mods"].get("hip_spread_mult", 1) > 1)
        assert worse and a["drawback"], a["id"]
# irons are the cheapest, high zoom the priciest: mean price rises irons <= dot/holo <= prism <= scope
mean = lambda t: sum(by_id[i]["cost"] for i in LINEUP if by_id[i]["optic"]["type"] in t) / max(1, len([i for i in LINEUP if by_id[i]["optic"]["type"] in t]))
assert mean(["irons"]) <= mean(["dot", "holo"]) <= mean(["prism"]) <= mean(["scope"]), "optic price curve"
# Skillz placeholder icons (tools/optics/placeholder_icons.py: reticle glyphs) until Desi's renders land; drop the id here then.
PLACEHOLDER_ICONS = {"witchlight_dabs", "wicket_ring", "mason_notch", "foxfire_post", "kilnglass_2x", "belfry_8x"}
# art status: parts whose GLB / icon isn't in the repo yet are flagged (WeaponRig falls back to the default sight picture;
# art_test skips their paths). Re-run this generator when Desi's files land and the flag drops off.
for a in A:
    miss = []
    if a.get("model") and not os.path.exists(os.path.join(REPO, a["model"].replace("res://", ""))):
        miss.append("model")
    if not os.path.exists(os.path.join(REPO, "assets", "icons", a["icon"] + ".png")) or a["id"] in PLACEHOLDER_ICONS:
        miss.append("icon")
    if miss:
        a["art_pending"] = miss
for ex in EXCLUSIONS:
    assert len(ex["parts"]) >= 2 and ex["classes"] and ex["reason"], ex["id"]
    assert len({by_id[x]["slot"] for x in ex["parts"]}) == len(ex["parts"]), ex["id"]  # one per slot
    for c in ex["classes"]:
        assert c in CLASSES
        for x in ex["parts"]:
            assert by_id[x]["slot"] in CLASSES[c]["slots"] and (not by_id[x].get("classes") or c in by_id[x]["classes"]), (ex["id"], c, x)
for c, v in CLASSES.items():  # every class slot has at least one part
    for s in v["slots"]:
        assert any(a["slot"] == s and (not a.get("classes") or c in a["classes"]) and
                   (s != "optic" or OPTIC_SIZES.index(a["size"]) <= OPTIC_SIZES.index(v["optic_cap"])) for a in A), (c, s)

att_doc = {
    "version": 1,
    "_help": ("Weapon attachments (Skillz). Bought once with Gravemark (account-wide unlock), then equipped per weapon "
              "archetype: every weapon of that archetype uses the archetype's loadout. classes[archetype].slots = slots it has "
              "(DESI_ATTACHMENTS.md §1); optic_cap limits optic size (micro<short<mid<long). attachment.classes = optional allow "
              "list (default: every class with that slot). tier 1/2/3: equipping needs the weapon's upgrade tier >= "
              "tier_requires[tier] (0/2/4). mods (WeaponItem, multiply unless *_add): damage_mult rpm_mult mag_mult reload_mult "
              "(time) spread_mult (all fire) hip_spread_mult (not ADS) recoil_mult range_mult (falloff start) swap_mult (time) "
              "pellets_add headshot_add reserve_mags_add. ads (AdsProfile): fov (ADS FOV override; the narrowest wins) fov_mult "
              "(x the class iron-sight FOV) move_mult spread_mult (multiply the ADS penalties) ads_time_mult sway_mult (x the "
              "class ADS time / sway). optic = optics lineup block on optic-slot parts (Armory.optic_profile). art_pending = "
              "[model, icon] not shipped yet (default sight picture / glyph until they land). flags = presentation hooks for player.gd/HUD (tracer_hidden, flash_mult, "
              "scope_overlay, outline_elites, heartbeat_counter, bipod, flashlight, mine_lamp). effects = SkillEffect defs (same format as "
              "skill_tree.json) run by the player's SkillRunner only while a weapon of that archetype is in hand. slots[].hides = default gun meshes (Desi split guns) a fitted part hides; an attachment \"hides\" overrides it ([] = hide nothing); \"hides_by_class\" {archetype: [...]} overrides both for that archetype (Sawn Stub on the shotgun also hides IronSights + the DefaultMag tube); \"inner_hides\" {archetype or \"*\": [node names]} hides nodes inside the part itself on that host (Sawn Stub's MagTubeStub shows on the shotgun only). exclusions = per-archetype parts that can't be equipped together ({id, classes, parts, reason}; Armory.exclusion_reason); a save holding one unequips the last listed part on load (it stays owned). Flashlight parts (mine_lamp, lantern_rail; F toggles the beam) carry light_energy / light_range / light_angle / light_attenuation / light_color for the camera SpotLight3D (Armory.flashlight_config)."),
    "slots": SLOTS, "optic_sizes": OPTIC_SIZES, "tier_requires": {str(k): v for k, v in TIER_REQ.items()},
    "classes": CLASSES, "exclusions": EXCLUSIONS,
    "optics": {"_help": ("Optics lineup (DESIGN.md §19). magnification = true zoom vs the 75 deg hip view (ADS fov = "
                         "2*atan(tan(37.5)/m)); overlay = Gooey's 2D scope overlay (>= overlay_min_mag); else the 3D sight "
                         "picture through the model's SightPoint. factory = the no-attachment choice (irons, or the sniper's "
                         "built-in scope). price_bands = Gravemark range per optic type (gen_armory.py asserts it)."),
               "hip_fov": HIP_FOV, "overlay_min_mag": OVERLAY_MIN_MAG, "types": OPTIC_TYPES, "lineup": LINEUP,
               "price_bands": {k: list(v) for k, v in PRICE_BANDS.items()}, "factory": FACTORY_OPTIC},
    "attachments": A,
}

armory = {
    "version": 1,
    "_help": ("Armory economy (Skillz). currency = Gravemark: persistent (Progress [armory]), separate from points, kept on death. "
              "Every source's amount or chance is multiplied by Difficulty.rare_currency_drop_mult() (easy 1.0, medium 1.35, "
              "hard 1.75); chances above 1 pay the whole part plus a roll for the rest. match_cap = most Gravemarks one match can pay. "
              "upgrades = per-archetype tiers bought in order; cost[tier-1] x archetype_cost_mult; item_power = TOTAL bonus at that "
              "tier added to the weapon's Item Power (damage x(1+IP*0.004)); mods = that tier's extra WeaponItem mods (they stack "
              "with lower tiers). expected = assumptions for Armory.expected_match_income() (tests + the matches-to-max table)."),
    "currency": {
        "id": "gravemark", "name": "Gravemark", "plural": "Gravemarks", "icon": "gravemark",
        "pickup_model": "res://assets/models/pickups/gravemark.glb", "match_cap": 30,
        "sources": {
            "boss": {"_help": "BossCatalog gravemark_reward (2-3) for the first boss killed in a round; later bosses that round pay extra_boss_amount.",
                     "extra_boss_amount": 1},
            "elite": {"_help": "zombie meta 'elite' = true, or a variant listed here (none yet; G4M3N's armored variants).",
                      "chance": 0.2, "amount": 1, "variants": []},
            "special": {"_help": "Tougher regular variants.", "chance": 0.006, "amount": 1, "variants": ["soldier"]},
            "regular": {"chance": 0.0015, "amount": 1},
            "chest": {"chance": 0.04, "amount": 1, "per_round_max": 1, "match_max": 2},
            "milestone": {"every": 10, "amount": 1},
        },
    },
    "upgrades": {
        "name_template": "{type} Rework",
        "tiers": [
            {"tier": 1, "name": "I", "cost": 3, "item_power": 8, "mods": {}, "summary": "+8 Item Power."},
            {"tier": 2, "name": "II", "cost": 6, "item_power": 16, "mods": {"reload_mult": 0.95},
             "summary": "+16 Item Power, reload -5%. Unlocks tier 2 attachments."},
            {"tier": 3, "name": "III", "cost": 11, "item_power": 26, "mods": {"reserve_mags_add": 1},
             "summary": "+26 Item Power, +1 reserve mag."},
            {"tier": 4, "name": "IV", "cost": 20, "item_power": 38, "mods": {"recoil_mult": 0.9},
             "summary": "+38 Item Power, recoil -10%. Unlocks tier 3 attachments."},
            {"tier": 5, "name": "V", "cost": 36, "item_power": 55, "mods": {"mag_mult": 1.1, "swap_mult": 0.9},
             "summary": "Masterwork: +55 Item Power, magazine +10%, swap -10%."},
        ],
        "archetype_cost_mult": {"rocket_launcher": 1.25},
        "min_growth": 1.6,
    },
    "expected": {
        "_help": "Income model: kills = main.gd wave counts x Difficulty count mults; chest_opens_per_round; bosses killed as rostered.",
        "chest_opens_per_round": 2, "first_round_zombies": 6, "zombies_per_round": 3,
        "typical_rounds": {"easy": 15, "medium": 13, "hard": 11},
    },
}
tc = [t["cost"] for t in armory["upgrades"]["tiers"]]
assert all(b >= a * armory["upgrades"]["min_growth"] for a, b in zip(tc, tc[1:])), tc
json.dump(att_doc, open(os.path.join(ROOT, "attachments.json"), "w"), indent="\t", ensure_ascii=False)
json.dump(armory, open(os.path.join(ROOT, "armory.json"), "w"), indent="\t", ensure_ascii=False)
print("attachments:", len(A), "upgrade costs:", tc, "sum", sum(tc))
