extends SceneTree
## Light fixture test (Mapz, playtest #16). Headless, read-only: loads each map, never saves it.
##
## Usage (project root):
##   godot --headless --path . -s res://tools/godot/test_light_fixtures.gd -- [res://maps/<id>/<id>.tscn ... res://scenes/main.tscn] [--tol=0.3] [--max-shadowed=4] [--max-overlap=14] [--verbose]
## With no map arguments it tests the arena (res://scenes/main.tscn) and the three maps. Exit code 1 on any failure.
## Last line: "LIGHT_FIXTURES_SUITE maps=N floating=K -> PASS|FAIL".
##
## Rules (docs/map_contract.md "Lights"):
##   FLOATING  every Light3D of the map (not Directional; Player/Chest/Pickup runtime lights are skipped) must be within --tol (0.3 m)
##             of a collidable surface, OR inside the visual AABB (+tol) of a node in group `light_fixture` whose AABB (+0.12 m) touches
##             a collidable surface (wall, ceiling, floor). Invisible Clip bodies and doors do not count as surfaces.
##   SHADOWS   at most --max-shadowed (4) non-directional lights with shadow_enabled per map.
##   OVERLAP   at no walkable floor sample (3 m grid) may more than --max-overlap (14) lights reach (range + line of sight): GTX 1660 budget.
## A non-map root script (scenes/main.tscn's main.gd) is stripped before the scene enters the tree: the arena is tested as geometry + lights only.

const Lib := preload("res://tools/godot/light_lib.gd")

func _initialize() -> void:
	_main.call_deferred()

func _main() -> void:
	var maps: Array[String] = []
	var tol := 0.3
	var max_sh := 4
	var max_ov := 14
	var verbose := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tol="): tol = float(a.get_slice("=", 1))
		elif a.begins_with("--max-shadowed="): max_sh = int(a.get_slice("=", 1))
		elif a.begins_with("--max-overlap="): max_ov = int(a.get_slice("=", 1))
		elif a == "--verbose": verbose = true
		elif a.ends_with(".tscn"): maps.append(a)
	if maps.is_empty():
		maps = ["res://scenes/main.tscn", "res://maps/rustwell_foundry/rustwell_foundry.tscn", "res://maps/drowned_cannery/drowned_cannery.tscn", "res://maps/ironside_depot/ironside_depot.tscn"]
	var bad_total := 0
	for path in maps:
		var ps := load(path) as PackedScene
		if ps == null:
			print("FAIL  cannot load ", path)
			bad_total += 1
			continue
		var m: Node = ps.instantiate()
		if m.get_script() != null and not (m is MapRoot):
			m.set_script(null)
		root.add_child(m)
		for i in 5:
			await physics_frame
		var space: PhysicsDirectSpaceState3D = (m as Node3D).get_world_3d().direct_space_state
		var ignore := Lib.ignore_rids(m)
		var lights: Array = Lib.map_lights(m)
		var floating := 0
		var shadowed := 0
		var by_state := {"surface": 0, "fixture": 0}
		for l: Light3D in lights:
			if l.shadow_enabled:
				shadowed += 1
			var st := Lib.mount_state(m, space, l, ignore, tol)
			if st == "":
				floating += 1
				print("FAIL  FLOATING ", m.get_path_to(l), " at ", l.global_position.snapped(Vector3(.1, .1, .1)))
			else:
				by_state[st] += 1
				if verbose:
					print("ok    ", st, " ", m.get_path_to(l))
		var ok_sh := shadowed <= max_sh
		print(("PASS  " if ok_sh else "FAIL  ") + "SHADOWS %d shadowed lights (max %d)" % [shadowed, max_sh])
		# overlap budget
		var ldata: Array = []
		for l: Light3D in lights:
			var r := Lib.light_range(l)
			if r > 0.0 and l.light_energy > 0.0 and l.visible:
				ldata.append({"pos": l.global_position, "energy": l.light_energy, "range": r})
		var half := Vector2(70, 70)
		var samples := Lib.floor_samples(m, space, ignore, half, 3.0)
		var max_count := 0
		for s in samples:
			var c: int = Lib.lux(space, s, ldata, ignore).count
			max_count = maxi(max_count, c)
		var ok_ov := max_count <= max_ov
		print(("PASS  " if ok_ov else "FAIL  ") + "OVERLAP max %d lights reach one floor point (max %d, %d samples)" % [max_count, max_ov, samples.size()])
		print("MAP   %s lights=%d shadowed=%d on_surface=%d on_fixture=%d floating=%d" % [path.get_file(), lights.size(), shadowed, by_state.surface, by_state.fixture, floating])
		if floating > 0 or not ok_sh or not ok_ov:
			bad_total += 1
		m.queue_free()
		await process_frame
	var total_floating := bad_total
	print("LIGHT_FIXTURES_SUITE maps=%d failing=%d -> %s" % [maps.size(), total_floating, "PASS" if total_floating == 0 else "FAIL"])
	quit(0 if total_floating == 0 else 1)
