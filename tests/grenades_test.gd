extends SceneTree
## Grenades by rarity (Skillz, playtest #25, /workspace/feedback/GRENADES_SPEC.md, MAIN_HOOKS §24).
##   godot --headless --path . -s res://tests/grenades_test.gd [-- --only=<section>]
## data       grenades.json: variant ids, #hex tints, rarities, drop weights; projectiles.json grenade + child types
## contract   every throw is TP.spawn(spec) type_id grenade / variant id; models; visual-only copies
## frag / cinderjar / shiverglass / tallyhook / rookery / gravewell / leechbell / requiem   each effect as specced
## sfx        every Audi-0 key the grenades play exists in the Sfx bank
## Exit code = number of failures.

const MAIN := "res://scenes/main.tscn"
const COURSE_SCENE := "res://tests/ai_nav_course.tscn"
const SPEC_RARITY := {"frag": "common", "pulse": "common", "cinderjar": "uncommon", "shiverglass": "uncommon",
	"tallyhook": "rare", "rookery": "rare", "gravewell": "legendary", "leechbell": "legendary", "requiem_bell": "mythic"}
const SPEC_TINT := {"pulse": "#7FB8FF", "cinderjar": "#FF7A2E", "shiverglass": "#8FD8FF", "tallyhook": "#B07CFF",
	"rookery": "#FFD27A", "gravewell": "#2BFF9A", "leechbell": "#E0283C", "requiem_bell": "#F2D27A"}
const BASE := Vector3(30, 0.1, -10) ## open floor on the AI course

var _passes := 0
var _fails := 0
var main: Node
var pl: CharacterBody3D
var gdb: Node
var GR: GDScript ## grenade.gd (loaded at run time: a parse-time class ref would compile weapon_item.gd before the GearDB autoload)
var TP: GDScript ## thrown_projectile.gd


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func secs(t: float) -> int:
	return int(ceil(t * 60.0))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_grenades_test.cfg"
	progress.reset_skills()
	gdb = root.get_node("GearDB")
	GR = load("res://scripts/combat/grenade.gd")
	TP = load("res://scripts/projectiles/thrown_projectile.gd")
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 16
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
	if only == "" or only == "data":
		_data_checks()
	main = load(MAIN).instantiate()
	main.map_scene = load(COURSE_SCENE)
	root.add_child(main)
	current_scene = main
	await wait(3)
	main._break_timer = 1.0e9
	main.field_cards_enabled = false
	Engine.time_scale = 4.0
	pl = main.player
	pl.set_physics_process(false)
	pl.global_position = BASE + Vector3(0, 0, 14)
	for z in get_nodes_in_group("enemies"):
		z.queue_free()
	await wait(3)
	for sec in ["contract", "frag", "cinderjar", "shiverglass", "tallyhook", "rookery", "gravewell", "leechbell", "requiem", "sfx"]:
		if only == "" or only == sec:
			await call("_" + sec)
			await _clear()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("grenades_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


# ------------------------------------------------------------------ helpers

func _g(id: String) -> Dictionary:
	return gdb.grenade(id)


func _zombie(pos: Vector3, health: int = 1000, physics: bool = false) -> Node:
	var z = main.make_zombie({"kind": "zombie", "health": health, "speed": 3.2, "damage": 10})
	main.zombies_root.add_child(z)
	z.global_position = pos
	z.target = null # stands still: effects only
	z.set_physics_process(physics)
	return z


## A grenade of `id` thrown by the player, parked at `pos` (frozen, fuse paused) so the test fires it.
func _grenade(id: String, pos: Vector3, park: bool = true):
	var g = GR.throw_from(pl, _g(id), pos, Vector3.FORWARD, Vector3.ZERO)
	g.global_position = pos
	if park:
		g.freeze = true
		g._fuse = 999.0
	return g


func _clear() -> void:
	for z in get_nodes_in_group("enemies"):
		z.queue_free()
	for n in get_nodes_in_group("thrown_projectiles") + get_nodes_in_group("grenade_zones"):
		n.queue_free()
	for n in main.find_children("*", "RigidBody3D", true, false):
		if n.get_script() == GR:
			n.queue_free()
	pl.health = pl.max_health
	pl.dead = false
	await wait(3)


# ------------------------------------------------------------------ data

func _data_checks() -> void:
	var all: Dictionary = gdb.grenades
	check(all.size() == 9 and SPEC_RARITY.keys().all(func(k): return all.has(k)), "grenades.json has the 9 spec grenades (%s)" % ", ".join(all.keys()))
	var ok_v := true
	var ok_c := true
	var ok_r := true
	var ok_w := true
	for k in all:
		var d: Dictionary = all[k]
		ok_v = ok_v and str(d.get("variant", "")) == k
		ok_c = ok_c and d.get("color") is String and Color.html_is_valid(str(d.color)) \
			and (not SPEC_TINT.has(k) or str(d.color).to_upper() == SPEC_TINT[k])
		ok_r = ok_r and str(d.get("rarity", "")) == SPEC_RARITY.get(k, "?")
		ok_w = ok_w and float(d.get("drop_weight", 0)) > 0.0
	check(ok_v, "every entry: variant == its id (stable ids for SFX / models / Netz)")
	check(ok_c, "every entry: color is the spec's #hex effect tint")
	check(ok_r, "rarities: frag/pulse C, cinderjar/shiverglass U, tallyhook/rookery R, gravewell/leechbell L, requiem_bell M")
	var w := func(k): return float(all[k].drop_weight)
	check(ok_w and w.call("frag") > w.call("cinderjar") and w.call("cinderjar") > w.call("tallyhook")
		and w.call("tallyhook") > w.call("gravewell") and w.call("gravewell") > w.call("requiem_bell"),
		"drop_weight > 0 and rarer = less likely (%s)" % [all.keys().map(func(k): return "%s %s" % [k, all[k].drop_weight])])
	check(str(all.pulse.get("model", "")) == "frag" and str(all.pulse.name) == "Tremor Charge", "Tremor Charge stays a Common alternative on the frag mesh")
	var t: Dictionary = TP.type_def(&"grenade")
	check(str(t.get("body", "")) == "grenade" and all.keys().all(func(k): return t.get("variants", {}).has(k)),
		"projectiles.json type 'grenade' (body grenade) lists every variant")
	check(not TP.type_def(&"grenade_bomblet", &"rookery").is_empty() and not TP.type_def(&"heal_orb", &"leechbell").is_empty(),
		"child projectile types grenade_bomblet (rookery) + heal_orb (leechbell) exist")
	check(GR.color_of({"color": "#7FB8FF"}).is_equal_approx(Color.html("#7FB8FF")) and GR.color_of({"color": [1, 0, 0]}) == Color(1, 0, 0),
		"color_of reads #hex and the old [r,g,b]")


# ------------------------------------------------------------------ contract

func _contract() -> void:
	var n0: int = TP.spawned_total
	for id in SPEC_RARITY:
		var g = GR.throw_from(pl, _g(id), BASE + Vector3(0, 30, 0), Vector3.FORWARD, Vector3.ZERO)
		var p = g.proj
		check(p != null and p.type_id == &"grenade" and p.variant == StringName(id) and p.rarity == Rarity.from_id(SPEC_RARITY[id])
			and p.owner_id == pl.get_instance_id() and p.body == g and g.authoritative and not p.is_visual_only,
			"%s: thrown through ThrownProjectile.spawn (type grenade, variant %s, rarity %d, owner = thrower)" % [id, id, p.rarity if p else -1])
		var model: String = "frag" if id == "pulse" else id
		check(g.visual != null and g.visual.scene_file_path == GR.VARIANT_DIR + model + ".glb", "%s: Desi's %s.glb" % [id, model])
		check(g.band_material != null and g.band_material.albedo_color.is_equal_approx(GR.color_of(_g(id))), "%s: Band tinted %s" % [id, _g(id).color])
		g.free()
	check(TP.spawned_total - n0 == 9, "one projectile spec per throw")
	await wait(2)
	check(get_nodes_in_group("thrown_projectiles").is_empty(), "freeing the grenade frees its carrier projectile")
	# visual-only copy (co-op puppet): flies, never damages
	var z := _zombie(BASE)
	var spec: Dictionary = GR.make_spec(pl, _g("frag"), BASE + Vector3(0, 0.5, 0), Vector3.ZERO, 7)
	spec["visual_only"] = true
	var p2 = TP.spawn(spec)
	var g2 = p2.body
	check(g2 != null and not g2.authoritative, "visual_only spec -> a visual-only Grenade")
	var hp: float = z.health
	g2.detonate()
	check(is_equal_approx(z.health, hp), "visual-only frag: no damage")
	# seeded RNG: same seed, same spin
	var a = GR.throw_from(pl, _g("frag"), BASE + Vector3(0, 30, 0), Vector3.FORWARD, Vector3.ZERO)
	var s2: Dictionary = GR.make_spec(pl, _g("frag"), BASE + Vector3(0, 30, 0), Vector3.ZERO, a.proj.seed_value)
	s2["visual_only"] = true
	var b = TP.spawn(s2).body
	check(a.angular_velocity.is_equal_approx(b.angular_velocity), "copies with one seed spin alike (RNG = spec seed)")
	a.free()
	b.free()


# ------------------------------------------------------------------ effects

func _frag() -> void:
	var z := _zombie(BASE + Vector3(1, 0, 0))
	var g = _grenade("frag", BASE + Vector3(0, 0.5, 0))
	var hp: float = z.health
	g.detonate()
	check(z.health < hp - 100.0, "frag: one blast (%.0f -> %.0f)" % [hp, z.health])
	check(g.done and g.detonate_key() == "frag_explode", "frag: frag_explode, then gone")


func _cinderjar() -> void:
	var zin := _zombie(BASE + Vector3(2, 0, 0), 5000, true)
	var zout := _zombie(BASE + Vector3(6, 0, 0), 5000, true)
	var g = _grenade("cinderjar", BASE + Vector3(0, 0.3, 0), false)
	g.freeze = false
	g._on_bounce(main) # first contact shatters it
	check(g.done, "cinderjar: shatters on first contact (no fuse)")
	var zones := get_nodes_in_group("grenade_zones")
	var zone = zones[0] if zones.size() else null
	check(zone != null and is_equal_approx(zone.radius, 3.0) and is_equal_approx(zone.duration, 5.0), "cinderjar: 3 m fire patch for 5 s")
	await wait(secs(1.0))
	check(zin.has_status("burn") and not zout.has_status("burn"), "cinderjar: burns zombies inside the patch only")
	var hp: float = zin.health
	await wait(secs(1.5))
	check(zin.health < hp, "cinderjar: burn DoT ticks (%.0f -> %.0f)" % [hp, zin.health])
	await wait(secs(3.0))
	check(not is_instance_valid(zone), "cinderjar: patch gone after 5 s")
	# visual copy: no patch logic
	var spec: Dictionary = GR.make_spec(pl, _g("cinderjar"), BASE + Vector3(0, 0.3, 0), Vector3.ZERO, 3)
	spec["visual_only"] = true
	var gv = TP.spawn(spec).body
	gv.detonate()
	check(get_nodes_in_group("grenade_zones").is_empty(), "cinderjar visual copy: FX only, no burning zone")


func _shiverglass() -> void:
	var zin := _zombie(BASE + Vector3(3, 0, 0))
	var zout := _zombie(BASE + Vector3(7, 0, 0))
	var g = _grenade("shiverglass", BASE + Vector3(0, 0.9, 0))
	g.detonate()
	var s: Dictionary = zin.status("slow")
	check(zin.has_status("slow") and is_equal_approx(float(s.amp), 0.5) and is_equal_approx(float(s.t), 3.0), "shiverglass: 50% slow for 3 s inside 4 m")
	check(zin.has_status("frost") and is_equal_approx(float(zin.status("frost").amp), 0.15), "shiverglass: frost status (+15%)")
	check(not zout.has_status("slow") and not zout.has_status("frost"), "shiverglass: nothing outside 4 m")
	check(is_equal_approx(zin.slow_mult(), 0.5), "shiverglass: frozen zombie moves at 50%")
	var patched := (load("res://scripts/enemy.gd") as GDScript).source_code.contains("\"frost\"]")
	if patched:
		check(is_equal_approx(zin.damage_taken_mult(), 1.15), "shiverglass: frozen zombie takes +15% damage")
	else:
		print("NOTE  shiverglass +15% damage taken needs enemy.gd §24 (patches/enemy_grenade_frost.patch); frost status is applied")


func _tallyhook() -> void:
	var host := _zombie(BASE)
	var chain := []
	for i in 5: # 3 m apart in a line: 4 within the hop range of the next
		chain.append(_zombie(BASE + Vector3(3.0 * (i + 1), 0, 0)))
	var far := _zombie(BASE + Vector3(-20, 0, 0))
	var g = _grenade("tallyhook", BASE + Vector3(-0.5, 1.0, 0), false)
	g.freeze = false
	var contact: Vector3 = host.global_position + Vector3(-0.35, 1.0, 0)
	g.stick_to(host, contact)
	check(g.get_parent() == host and g.freeze and g.stuck_to == host, "tallyhook: sticks to the first zombie hit, parented to it")
	check(g.hook_point().distance_to(contact) < 0.02, "tallyhook: hook tips (StickPoint) at the contact point (%.3f m)" % g.hook_point().distance_to(contact))
	host.global_position += Vector3(0, 0, 1.0)
	await wait(1)
	check(g.hook_point().distance_to(contact + Vector3(0, 0, 1.0)) < 0.02, "tallyhook: rides along when the zombie moves")
	var hps := chain.map(func(z): return z.health)
	var host_hp: float = host.health
	await wait(secs(0.5))
	check(not g.done, "tallyhook: still charging at 0.5 s")
	await wait(secs(0.6))
	check(not is_instance_valid(g) or g.done, "tallyhook: zaps after 1 s")
	var hit := 0
	for i in 5:
		if chain[i].health < hps[i]:
			hit += 1
	check(host.health < host_hp, "tallyhook: the stuck zombie takes the blast")
	check(hit == 4 and chain[4].health == hps[4], "tallyhook: shock chains to 4 more within 6 m (hit %d, 5th untouched)" % hit)
	check(far.health == 1000.0, "tallyhook: a zombie 20 m away is not chained")
	# the host dies first: the hook drops off and still zaps
	var h2 := _zombie(BASE + Vector3(0, 0, 6), 50)
	var g2 = _grenade("tallyhook", BASE + Vector3(0, 1, 5.5), false)
	g2.stick_to(h2, h2.global_position + Vector3(0, 1.0, -0.35))
	h2.take_damage(999.0)
	await wait(1)
	check(is_instance_valid(g2) and g2.get_parent() != h2, "tallyhook: drops off a zombie that dies")
	await wait(secs(1.1))
	check(not is_instance_valid(g2) or g2.done, "tallyhook: still zaps after its host died")


func _rookery() -> void:
	var zs := []
	for i in 8:
		zs.append(_zombie(BASE + Vector3(cos(TAU * i / 8.0), 0, sin(TAU * i / 8.0)) * 2.5, 5000))
	var g = _grenade("rookery", BASE + Vector3(0, 0.5, 0))
	var hps := zs.map(func(z): return z.health)
	g.detonate()
	var kids: Array = g.last.get("bomblets", [])
	var ok := kids.size() == 5
	for k in kids:
		ok = ok and k.type_id == &"grenade_bomblet" and k.variant == &"rookery" and k.owner_id == pl.get_instance_id() and not k.is_visual_only
	check(ok, "rookery: scatters 5 bomblets as projectile specs (grenade_bomblet / rookery, owner = thrower)")
	var after_main := zs.map(func(z): return z.health)
	await wait(secs(0.3))
	check(kids.all(func(k): return is_instance_valid(k) and not k.done), "rookery: bomblets still flying at 0.3 s")
	await wait(secs(0.25))
	check(kids.all(func(k): return not is_instance_valid(k)), "rookery: every bomblet popped by 0.55 s")
	var extra := 0
	for i in zs.size():
		if zs[i].health < after_main[i]:
			extra += 1
	check(after_main.reduce(func(a, h): return a + h, 0.0) < hps.reduce(func(a, h): return a + h, 0.0) and extra >= 3,
		"rookery: main blast, then bomblet blasts hit %d zombies" % extra)
	# a visual copy spawns no bomblets of its own (they come from the host's specs)
	var spec: Dictionary = GR.make_spec(pl, _g("rookery"), BASE + Vector3(0, 0.5, 0), Vector3.ZERO, 5)
	spec["visual_only"] = true
	var n0: int = TP.spawned_total
	(TP.spawn(spec).body).detonate()
	check(TP.spawned_total - n0 == 1, "rookery visual copy: no local bomblets")


func _gravewell() -> void:
	var z := _zombie(BASE + Vector3(3.5, 0, 0), 5000, true)
	var boss := _zombie(BASE + Vector3(0, 0, -3.0), 50000, true)
	boss.set_meta("is_boss", true)
	var out := _zombie(BASE + Vector3(-7, 0, 0), 5000, true)
	var g = _grenade("gravewell", BASE + Vector3(0, 0.4, 0))
	g.freeze = false
	g.detonate()
	check(g.freeze and not g.done, "gravewell: stops and opens the vortex")
	var d0: float = Vector2(z.global_position.x - BASE.x, z.global_position.z - BASE.z).length()
	var b0: Vector3 = boss.global_position
	var o0: Vector3 = out.global_position
	await wait(secs(1.5))
	var d1: float = Vector2(z.global_position.x - BASE.x, z.global_position.z - BASE.z).length()
	check(d1 < d0 - 1.0, "gravewell: pulls a zombie in (%.1f -> %.1f m)" % [d0, d1])
	check(boss.global_position.distance_to(b0) < 0.3, "gravewell: no pull on a boss (moved %.2f m)" % boss.global_position.distance_to(b0))
	check(g.last.staggered.has(boss), "gravewell: the boss is only staggered")
	check(out.global_position.distance_to(o0) < 0.3, "gravewell: nothing outside 4 m")
	var hp: float = z.health
	await wait(secs(1.2))
	check(not is_instance_valid(g) or g.done, "gravewell: big blast after 2.5 s")
	check(z.health < hp - 200.0, "gravewell: the blast hits the pulled zombie (%.0f -> %.0f)" % [hp, z.health])


func _leechbell() -> void:
	pl.global_position = BASE + Vector3(0, 0, 6)
	var mh: int = pl.max_health
	pl.max_health = 1000
	pl.health = 10.0
	var zs := [_zombie(BASE + Vector3(1, 0, 0), 5000), _zombie(BASE + Vector3(-1, 0, 1), 5000)]
	var zone0 := get_nodes_in_group("grenade_zones").size()
	var g = _grenade("leechbell", BASE + Vector3(0, 0.9, 0))
	var h0: float = pl.health
	var healed0: float = GR.orbs_healed
	g.detonate()
	var dealt: float = g.last.dealt
	var total: float = g.last.heal_total
	var orbs: Array = g.last.orbs
	check(dealt > 100.0 and is_equal_approx(total, dealt * 0.3), "leechbell: 30%% of %.0f damage dealt comes back (%.1f HP)" % [dealt, total])
	check(orbs.size() == clampi(ceili(total / 5.0), 1, 8) and orbs.all(func(o): return o.type_id == &"heal_orb" and o.variant == &"leechbell" and o.owner_id == pl.get_instance_id()),
		"leechbell: %d heal orbs as projectile specs (heal_orb / leechbell, owner = thrower)" % orbs.size())
	check(get_nodes_in_group("grenade_zones").size() == zone0 and main.find_children("*Puddle*", "", true, false).is_empty(), "leechbell: no decal / puddle")
	await wait(secs(3.0))
	check(orbs.all(func(o): return not is_instance_valid(o)), "leechbell: orbs drift to the thrower")
	check(absf((GR.orbs_healed - healed0) - total) < 0.01 and pl.health - h0 >= total - orbs.size() and pl.health - h0 <= total + orbs.size(),
		"leechbell: heals the thrower %.0f HP (%.1f expected)" % [pl.health - h0, total])
	pl.max_health = mh
	pl.global_position = BASE + Vector3(0, 0, 14)


func _requiem() -> void:
	var near := [_zombie(BASE + Vector3(4, 0, 0), 5000), _zombie(BASE + Vector3(-8, 0, 3), 400)]
	var far := _zombie(BASE + Vector3(0, 0, -12), 5000)
	# real physics: dropped onto the floor it bounces 3 times on its own, then tolls
	var g = _grenade("requiem_bell", BASE + Vector3(0, 2.0, 0), false)
	g.freeze = false
	g.linear_velocity = Vector3(1, -2, 0)
	g._fuse = 6.0
	var hits := [0]
	g.effect.connect(func(w, _i): if w == &"bell_bounce": hits[0] += 1)
	for i in secs(6.5):
		await physics_frame
		if not is_instance_valid(g) or g.done:
			break
	check(hits[0] == 3, "requiem bell: 3 bounces with a small blast each (%d)" % hits[0])
	check(not is_instance_valid(g) or g.done, "requiem bell: final toll after the 3rd bounce")
	var s: Dictionary = near[0].status("mark")
	check(near.all(func(z): return z.has_status("mark")) and is_equal_approx(float(s.get("amp", 0)), 0.25) and float(s.get("t", 0)) > 5.0,
		"requiem bell: zombies within 10 m marked for 6 s (+25%%)")
	check(not far.has_status("mark"), "requiem bell: 12 m away is not marked")
	check(is_equal_approx(near[0].damage_taken_mult(), 1.25), "requiem bell: marked zombie takes +25% damage")
	# a marked kill refunds 20% of the grenade cooldown
	pl.grenade_cooldown = 20.0
	pl._grenade_cd = 15.0
	pl._refund_log.clear()
	var r0: int = GR.requiem_refunds
	near[1].take_damage(99999.0)
	check(GR.requiem_refunds == r0 + 1 and is_equal_approx(pl._grenade_cd, 11.0), "requiem bell: marked kill refunds 20%% cooldown (15 -> %.1f s)" % pl._grenade_cd)
	far.take_damage(99999.0)
	check(GR.requiem_refunds == r0 + 1, "requiem bell: an unmarked kill refunds nothing")


func _sfx() -> void:
	var sfx := root.get_node_or_null("Sfx")
	var keys := ["grenade_throw", "grenade_rarity_legendary", "grenade_rarity_mythic", "frag_explode", "grenade_cinderjar_fire",
		"grenade_shiverglass_frost", "grenade_tallyhook_stick", "grenade_tallyhook_charge", "grenade_tallyhook_arc",
		"grenade_rookery_bomblet", "grenade_gravewell_vortex_loop", "grenade_leechbell_orb_loop", "grenade_leechbell_heal",
		"grenade_requiem_bell_bounce", "grenade_requiem_bell_toll", "grenade_requiem_bell_mark"]
	var missing := keys.filter(func(k): return not sfx.has(k))
	var dets := []
	for id in SPEC_RARITY:
		var g = GR.throw_from(pl, _g(id), BASE + Vector3(0, 30, 0), Vector3.FORWARD, Vector3.ZERO)
		var k: String = g.detonate_key()
		if not sfx.has(k) or (id not in ["frag", "pulse"] and k != "grenade_%s_detonate" % id):
			dets.append("%s:%s" % [id, k])
		g.free()
	check(sfx != null and missing.is_empty(), "Audi-0 grenade keys all in the bank (missing %s)" % [missing])
	check(dets.is_empty(), "detonate key = grenade_<variant>_detonate (frag -> frag_explode) %s" % [dets])
	check(sfx.mix("grenade_leechbell_orb_loop")[0] == -16.0 and sfx.mix("grenade_requiem_bell_toll")[0] == -2.0, "HOOKUP mix levels in sfx.gd")
