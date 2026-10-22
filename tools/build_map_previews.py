#!/usr/bin/env python3
"""Map-select preview data (Mapz, playtest #4). Step 2: raw dump -> clean preview JSON.

Step 1 (Godot, read-only): tools/godot/dump_preview_raw.gd writes <id>_raw.json (layer-1 static colliders, doors, markers).
This step keeps only walls and solid structures (no floors, decks, ramps, railings, clip, props, dressing, lintels),
unions them with shapely, simplifies, and writes data/map_previews/<id>.json. Doors are plain segments (no names, no cost).
usage: python build_map_previews.py <raw_dir> <out_dir> [ids...]   (needs shapely)
"""
import json, math, sys, os
from shapely.geometry import MultiPoint, Polygon, MultiPolygon
from shapely.ops import unary_union

SKIP_ROOTS = ("Clip", "Dressing", "Decor", "Props", "Merged", "NightKit", "Lights", "Occluders", "Chests")
SKIP_SUBSTR = ("/Doors/", "/Railings/", "/NavCarves/", "/Props/", "Desi", "Lintel", "RailCol_", "Floor", "Ramp",
               "Roof", "Catwalk", "Bridge", "Gallery", "Deck", "Ledge", "Rubble", "Platform", "Gangway", "Mezzanine",
               "Trestle", "Parapet", "Lip", "PitFloor", "Balcony", "Duct")
MIN_H = 2.0    # vertical extent of a wall / structure (low cover, decks and ramps are left out)
FEATURES = {"PlayerSpawn": "start", "PlayerStart": "start", "PowerWeaponSpot": "power_weapon", "PerkMachineSpot": "perk",
            "MysteryBoxSpot": "mystery_box", "BossArenaHook": "boss_arena", "Chest": "chest"}
R = lambda v: round(v, 2)


def keep(c):
    p = c["path"]
    if p.split("/")[0] in SKIP_ROOTS or any(s in p for s in SKIP_SUBSTR):
        return False
    ys = [q[1] for q in c["pts"]]
    return max(ys) - min(ys) >= MIN_H and c["type"] != "ConcavePolygonShape3D"


def build(raw):
    polys = []
    for c in raw["colliders"]:
        if keep(c):
            hull = MultiPoint([(q[0], q[2]) for q in c["pts"]]).convex_hull
            if hull.area > 0.01:
                polys.append(hull)
    u = unary_union(polys).simplify(0.05, preserve_topology=True) if polys else Polygon()
    geoms = list(u.geoms) if isinstance(u, MultiPolygon) else ([u] if not u.is_empty else [])
    walls = []
    out_polys = []
    for g in geoms:
        if len(g.interiors) == 0:
            out_polys.append(g)
        else:  # a closed ring of walls (perimeter, room): keep its pieces so every polygon stays simple (no holes)
            out_polys += [h.simplify(0.05) for h in polys if h.intersects(g)]
    for g in sorted(out_polys, key=lambda g: -g.area):
        ring = list(g.exterior.coords)[:-1]
        walls.append([[R(x), R(z)] for x, z in ring])
    doors = []
    for d in raw["doors"]:
        pts = [(q[0], q[2]) for c in raw["colliders"] if c["path"].startswith(d["path"] + "/") or c["path"] == d["path"]
               for q in c["pts"]]
        if len(pts) >= 3:
            rect = MultiPoint(pts).minimum_rotated_rectangle
            cs = list(rect.exterior.coords)[:4]
            e1 = (cs[1][0] - cs[0][0], cs[1][1] - cs[0][1]); e2 = (cs[2][0] - cs[1][0], cs[2][1] - cs[1][1])
            ax = e1 if math.hypot(*e1) >= math.hypot(*e2) else e2
            L = math.hypot(*ax); cx, cz = rect.centroid.x, rect.centroid.y
            ux, uz = ax[0] / L, ax[1] / L
        else:
            cx, cz = d["pos"][0], d["pos"][2]; ux, uz = d["axis"][0], d["axis"][2]; L = d["width"] or 4.0
        doors.append({"a": [R(cx - ux * L / 2), R(cz - uz * L / 2)], "b": [R(cx + ux * L / 2), R(cz + uz * L / 2)]})
    feats = []
    for m in raw["markers"]:
        f = {"type": FEATURES[m["kind"]], "pos": [R(m["pos"][0]), R(m["pos"][2])]}
        if "radius" in m:
            f["radius"] = R(m["radius"])
        feats.append(f)
    feats.sort(key=lambda f: list(FEATURES.values()).index(f["type"]))
    if raw.get("bounds"):
        bx, bz, bw, bh = raw["bounds"]
    else:
        minx, minz, maxx, maxz = unary_union(polys).bounds
        bx, bz, bw, bh = minx, minz, maxx - minx, maxz - minz
    return {
        "format": "mapz_preview v1",
        "map": raw["id"],
        "coords": "metres, top-down: [x, z] in Godot world space (+x east/right, +z south/down). Draw with y = z.",
        "bounds": [R(bx), R(bz), R(bw), R(bh)],
        "walls": walls,
        "doors": doors,
        "features": feats,
        "feature_types": ["start", "boss_arena", "perk", "mystery_box", "power_weapon", "chest"],
        "source": "generated from %s by tools/godot/dump_preview_raw.gd + tools/build_map_previews.py" % raw["scene"],
    }


if __name__ == "__main__":
    raw_dir, out_dir = sys.argv[1], sys.argv[2]
    ids = sys.argv[3:] or ["arena", "rustwell_foundry", "lockout_substation", "ironside_depot"]
    os.makedirs(out_dir, exist_ok=True)
    for i in ids:
        out = build(json.load(open(os.path.join(raw_dir, i + "_raw.json"))))
        with open(os.path.join(out_dir, i + ".json"), "w") as f:
            json.dump(out, f, separators=(",", ":"))
        print(i, "walls", len(out["walls"]), "verts", sum(len(w) for w in out["walls"]), "doors", len(out["doors"]),
              "features", len(out["features"]), "bytes", os.path.getsize(os.path.join(out_dir, i + ".json")))
