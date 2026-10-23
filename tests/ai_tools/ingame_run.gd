extends SceneTree
## In-game smoke + perf (Skillz AI nav, MAIN_HOOKS §17). Debug tool, not a suite.
##   default: load main.tscn on Arena / Rustwell / Drowned Cannery, run 900 physics frames, report zombies + nav components.
##   -- --perf [--n=28] [--modes=new,old,...]: Rustwell, spawn N zombies, physics time with ZombieNav ("new"),
##      the old chase path ("old": z.nav = null) or ZombieNav without RVO ("noavoid").
func _initialize() -> void:
	_run.call_deferred()


func _arg(k: String, d: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a == "--" + k:
			return "1"
		if a.begins_with("--" + k + "="):
			return a.split("=", true, 1)[1]
	return d


func _load(id: String) -> Node:
	load("res://scripts/world/map_registry.gd").select(id)
	change_scene_to_file("res://scenes/main.tscn")
	for i in 10:
		await process_frame
	return current_scene


func _run() -> void:
	if _arg("perf") != "":
		await _perf()
	else:
		for id in ["arena", "rustwell_foundry", "drowned_cannery"]:
			var main := await _load(id)
			var max_z := 0
			for i in 900:
				await physics_frame
				max_z = maxi(max_z, get_nodes_in_group("enemies").size())
			var zs := get_nodes_in_group("enemies")
			var with_nav := 0
			var q := 0
			for z in zs:
				if z.get("nav") != null:
					with_nav += 1
					q += int(z.nav.path_queries)
			print("INGAME %s physics_frames=900 zombies_now=%d max=%d with_nav=%d path_queries=%d round=%s" % [id, zs.size(), max_z, with_nav, q, main.get("current_round")])
	quit()


func _perf() -> void:
	var n := int(_arg("n", "28"))
	var nav_scr: Script = load("res://scripts/enemies/ai/zombie_nav.gd")
	for mode in _arg("modes", "new,old,new,old").split(","):
		if mode == "noavoid":
			var d: Dictionary = nav_scr.data().duplicate(true)
			d.avoidance.enabled = false
			nav_scr.reload_data(d)
		else:
			nav_scr.reload_data()
		var main := await _load("rustwell_foundry")
		main.set_physics_process(false) # no round logic / watchdog: just the zombies
		main.player.set_physics_process(false)
		for i in n:
			main._spawn_zombie()
		var zs := get_nodes_in_group("enemies")
		for z in zs:
			z.set("health", 1e9)
			if mode == "old":
				z.set("nav", null)
		for i in 30:
			await physics_frame
		var q0 := 0
		for z in zs:
			if z.get("nav") != null:
				q0 += int(z.nav.path_queries)
		var frames := 300
		var acc := 0.0
		var ts: Array[float] = []
		for i in frames:
			await physics_frame
			var t := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			acc += t
			ts.append(t)
		var q := -q0
		for z in zs:
			if is_instance_valid(z) and z.get("nav") != null:
				q += int(z.nav.path_queries)
		ts.sort()
		var qs := ("%.2f" % (q / (frames / 60.0) / zs.size())) if mode != "old" else "60 (repath every frame)"
		print("PERF %s zombies=%d physics median %.2f ms p95 %.2f ms avg %.2f ms  path_queries/s/zombie %s" % [mode, zs.size(), ts[frames / 2], ts[int(frames * 0.95)], acc / frames, qs])
	nav_scr.reload_data()
