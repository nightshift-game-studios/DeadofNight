extends SceneTree
## Solo-equivalence trace (Netz). Runs a seeded solo match on the arena and prints one line per spawned zombie
## (variant, stats, spawn point) plus points / kills / drops after scripted damage. Run it on the baseline
## (753ff7b) and on staging (Net + main hooks) and diff: identical output = solo unchanged.
##   godot --headless --path <project> -s res://tests/net/solo_trace.gd -- --seed=4242 --frames=1500
## Works without the Net autoload (baseline): never references Net.

var seed_v := 4242
var frames := 1500
var lines: Array = []
var no_avoid := false ## --no-avoid: §17 RVO avoidance off (its threaded callbacks are timing dependent)


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="): seed_v = int(a.get_slice("=", 1))
		elif a.begins_with("--frames="): frames = int(a.get_slice("=", 1))
		elif a == "--no-avoid": no_avoid = true
	_run.call_deferred()


func _run() -> void:
	var prog = root.get_node("Progress")
	if no_avoid and ResourceLoader.exists("res://scripts/enemies/ai/zombie_nav.gd"):
		var ZN = load("res://scripts/enemies/ai/zombie_nav.gd")
		var d: Dictionary = ZN.data().duplicate(true)
		d["avoidance"]["enabled"] = false
		ZN.reload_data(d)
	prog.save_path = "user://progress_solo_trace.cfg"
	var MR = load("res://scripts/world/map_registry.gd")
	MR.select("arena")
	change_scene_to_file("res://scenes/main.tscn")
	for i in 240:
		await physics_frame
		if current_scene != null and current_scene.has_node("Player"):
			break
	var main = current_scene
	main.field_cards_enabled = false
	main.player.set("invulnerable_t", 99999.0)
	# §17 nav: the threaded bake finishes at a timing-dependent frame and zombie nav draws randf() once it's up, so start
	# the seeded window only after the bake + one nav map sync (otherwise load-time jitter changes the RNG stream).
	var nr = main.get("nav_region")
	for i in 600:
		if nr == null or not nr.is_baking():
			break
		await physics_frame
	await physics_frame
	await physics_frame
	seed(seed_v) # everything random from here on comes from this seed
	main._break_timer = 0.2
	var zr: Node = main.zombies_root
	var seen := {}
	var t := 0
	for f in frames:
		await physics_frame
		for z in zr.get_children():
			var id := z.get_instance_id()
			if not seen.has(id):
				seen[id] = true
				var mr: Node3D = z.get_node_or_null("ModelRoot")
				var sc := 0.0
				if mr and mr.get_child_count() > 0:
					sc = snappedf((mr.get_child(0) as Node3D).scale.x, 0.0001)
				lines.append("spawn r%d %s hp=%d spd=%.3f dmg=%d scale=%.4f boss=%s" % [main.current_round, str(z.get("variant_id")),
					int(z.get("max_health")), float(z.get("speed")), int(z.get("contact_damage")), sc, str(z.get_meta("is_boss", false))])
		t += 1
		if t % 20 == 0: # scripted damage: hit the oldest live zombie (deterministic order) with a fixed amount
			for z in zr.get_children():
				if z.is_in_group("enemies"):
					z.take_damage(40.0, z.global_position + Vector3(0, 1, 0), false, main.player)
					break
		if t % 100 == 0:
			lines.append("t=%d round=%d alive=%d to_spawn=%d kills=%d points=%d pickups=%d" % [t, main.current_round, main._alive,
				main._to_spawn, main.kills, main.player.points, main.pickups_root.get_child_count()])
	for l in lines:
		print("TRACE ", l)
	print("TRACE_HASH ", str("\n".join(lines).hash()), " lines=", lines.size())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prog.save_path))
	quit(0)
