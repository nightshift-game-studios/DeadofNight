extends SceneTree
## Headless map / integration test:  godot --headless --path . -s res://tests/map_test.gd
## Rustwell Foundry (load, navmesh bake, area-gated spawns, door purchase, stuck zombies, kill_y),
## map selection API, zombie attack height check, ground jump vs wall kick, zombie variants, armor model mapping.
## Exit code = number of failures. Uses its own save file.

var _fails := 0
var _passes := 0
const RUSTWELL := "rustwell_foundry"


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _load_main() -> Node:
	change_scene_to_file("res://scenes/main.tscn")
	await wait(3)
	for i in 300:
		if current_scene != null and current_scene.has_node("Player") and current_scene.is_node_ready():
			break
		await physics_frame
	var main = current_scene
	main._break_timer = 9999.0
	return main


func _wait_bake(region: NavigationRegion3D, max_frames: int = 600) -> bool:
	for i in max_frames:
		var m := region.get_navigation_map()
		if not region.is_baking() and m.is_valid() and NavigationServer3D.map_get_iteration_id(m) > 0 \
				and region.navigation_mesh and region.navigation_mesh.get_polygon_count() > 0:
			await wait(2) # let the map sync the new region
			return true
		await physics_frame
	return false


func _reaches(nav_map: RID, from: Vector3, to: Vector3) -> bool:
	var a := NavigationServer3D.map_get_closest_point(nav_map, from)
	var b := NavigationServer3D.map_get_closest_point(nav_map, to)
	if b.distance_to(to) > 1.5:
		return false
	var path := NavigationServer3D.map_get_path(nav_map, a, b, true)
	return not path.is_empty() and path[path.size() - 1].distance_to(b) < 1.0


func _near_any(pos: Vector3, markers: Array, r: float) -> bool:
	for m in markers:
		if Vector2(pos.x, pos.z).distance_to(Vector2(m.global_position.x, m.global_position.z)) <= r:
			return true
	return false


func _nearest(pos: Vector3, markers: Array) -> Node3D:
	var best: Node3D = null
	for m in markers:
		if best == null or m.global_position.distance_to(pos) < best.global_position.distance_to(pos):
			best = m
	return best


func _run() -> void:
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_map_test.cfg"
	progress.reset_skills()

	# ---------------------------------------------------------------- map registry
	check(MapRegistry.list().size() >= 2, "maps.json lists %d maps" % MapRegistry.list().size())
	check(MapRegistry.is_valid(MapRegistry.ARENA) and MapRegistry.is_valid(RUSTWELL), "arena + rustwell_foundry are valid maps")
	check(not MapRegistry.select("no_such_map"), "unknown map id rejected")
	check(MapRegistry.cmdline_map(PackedStringArray(["--map=rustwell_foundry"])) == RUSTWELL, "--map=<id> parsed")
	check(MapRegistry.cmdline_map(PackedStringArray(["--foo", "--map", "arena"])) == "arena", "--map <id> parsed")
	check(ProjectSettings.get_setting("rendering/occlusion_culling/use_occlusion_culling", false) == true, "occlusion culling enabled")
	if MapRegistry.cmdline_map() == "":
		check(MapRegistry.current_id() == MapRegistry.ARENA, "default map = arena")

	# ---------------------------------------------------------------- Rustwell Foundry
	check(MapRegistry.select(RUSTWELL), "select rustwell_foundry")
	var main = await _load_main()
	var player = main.player
	var map = main.map
	check(map != null and map is MapRoot, "Rustwell loaded as the map")
	if map == null:
		_finish()
		return
	check(main.map_id == RUSTWELL, "main.map_id = %s" % main.map_id)
	check(main.get_node_or_null("WorldEnvironment") == null and map.has_node("WorldEnvironment"), "arena environment replaced by the map's")
	check(main.get_node_or_null("NavigationRegion3D") == null and main.nav_region == map.get_nav_region(), "nav region = the map's")
	var spawn: Node3D = map.get_node("PlayerSpawn")
	var hd := Vector2(player.global_position.x, player.global_position.z).distance_to(Vector2(spawn.global_position.x, spawn.global_position.z))
	check(hd < 0.6, "player starts at PlayerSpawn (%.2f m)" % hd)
	var markers: Array = map.get_node("Chests").get_children()
	var spawned_chests: Array = main.nav_region.get_node("SpawnedChests").get_children()
	check(markers.size() >= 3 and spawned_chests.size() == markers.size(), "chests instanced at %d markers" % markers.size())
	check(spawned_chests.all(func(c): return c.is_in_group("chests") and main.nav_region.is_ancestor_of(c)), "chests sit under the NavigationRegion3D")
	var spots = map.get_node_or_null("PickupSpots")
	if spots:
		check(main.pickups_root.get_child_count() >= spots.get_child_count(), "pickups at %d PickupSpots" % spots.get_child_count())
	var pws = map.get_node_or_null("PowerWeaponSpot")
	if pws:
		check(main.pickups_root.get_children().any(func(p): return p.global_position.distance_to(pws.global_position) < 0.5), "power weapon at the map's PowerWeaponSpot")

	check(await _wait_bake(main.nav_region), "navmesh baked")
	var nm: NavigationMesh = main.nav_region.navigation_mesh
	var polys_closed := nm.get_polygon_count()
	check(polys_closed > 100, "navmesh has %d polygons (doors closed)" % polys_closed)
	var nav_map: RID = main.nav_region.get_navigation_map()

	# area-gated spawns
	var all_spawns: Array = map.get_node("SpawnPoints").get_children()
	var active: Array = main.active_spawn_points()
	check(all_spawns.size() >= 6 and active.size() < all_spawns.size(), "closed doors: %d of %d spawns active" % [active.size(), all_spawns.size()])
	check(active.size() > 0 and active.all(func(m): return StringName(m.get_meta("area", &"start")) == map.start_area), "only start-area spawns are active")
	main.current_round = 12 # mixed variants
	main._to_spawn = 15
	for i in 15:
		main._spawn_zombie()
	await wait(2)
	var zs: Array = main.zombies_root.get_children()
	check(zs.size() == 15, "15 zombies spawned")
	check(zs.all(func(z): return _nearest(z.global_position, all_spawns) in active), "every zombie spawned at an active (start-area) spawn")
	var vseen := {}
	for z in zs:
		vseen[z.variant_id] = true
	check(vseen.size() >= 2, "variants mixed into the wave (%s)" % ", ".join(vseen.keys()))
	for z in zs:
		z.queue_free()
	main._alive = 0
	main._to_spawn = 0
	main.current_round = 0
	await wait(2)

	# buy a door
	var door: MapDoor = null
	for d in map.doors():
		if not d.is_open and d.opens_areas.size() and not map.is_area_open(StringName(d.opens_areas[0])):
			if d.connects.has(String(map.start_area)):
				door = d
				break
	check(door != null, "found a closed door out of the start area")
	if door:
		var area := StringName(door.opens_areas[0])
		var area_spawn: Node3D = null
		for m in all_spawns:
			if StringName(m.get_meta("area", &"")) == area:
				area_spawn = m
		check(area_spawn != null and not _reaches(nav_map, spawn.global_position, area_spawn.global_position), "locked area spawn unreachable before purchase")
		var unlocked := []
		map.area_unlocked.connect(func(a): unlocked.append(a))
		check(door.get_prompt().contains(str(door.cost)), "door prompt shows its price (%s)" % door.get_prompt())
		player.points = door.cost - 1
		door.interact(player)
		check(not door.is_open and player.points == door.cost - 1, "can't buy the door with too few points")
		player.points = door.cost + 40
		door.interact(player)
		check(door.is_open, "door opened after buying it")
		check(player.points == 40, "door cost %d points (left %d)" % [door.cost, player.points])
		check(unlocked.has(area) and map.is_area_open(area), "area_unlocked(%s) emitted" % area)
		var active2: Array = main.active_spawn_points()
		check(active2.size() > active.size() and active2.has(area_spawn), "door unlocked %d more spawn(s)" % (active2.size() - active.size()))
		await wait(2)
		check(await _wait_bake(main.nav_region), "navmesh rebaked after the door opened")
		check(nm.get_polygon_count() != polys_closed, "rebaked navmesh changed (%d -> %d polygons)" % [polys_closed, nm.get_polygon_count()])
		var ok_reach := false
		for i in 120: # the rebaked region syncs into the navigation map a frame or two after bake_finished
			if _reaches(nav_map, spawn.global_position, area_spawn.global_position):
				ok_reach = true
				break
			await physics_frame
		check(ok_reach, "unlocked area spawn now reachable from PlayerSpawn")
		main._to_spawn = 30
		for i in 30:
			main._spawn_zombie()
		await wait(1)
		var zs2: Array = main.zombies_root.get_children().filter(func(z): return not z.is_queued_for_deletion())
		check(zs2.all(func(z): return _nearest(z.global_position, all_spawns) in active2), "spawns now use start + unlocked area")
		check(zs2.any(func(z): return not (_nearest(z.global_position, all_spawns) in active)), "some zombies now spawn in the unlocked area")
		for z in zs2:
			z.queue_free()
		main._alive = 0
		main._to_spawn = 0
		await wait(2)

	# stuck zombie in a still-locked area gets moved
	var locked_spawn: Node3D = null
	for m in all_spawns:
		if not map.is_area_open(StringName(m.get_meta("area", &""))):
			locked_spawn = m
			break
	if locked_spawn:
		var z = main.ZOMBIE_SCENE.instantiate()
		z.setup(100, 0.0, 1)
		main.zombies_root.add_child(z)
		z.set_physics_process(false)
		z.global_position = locked_spawn.global_position
		await wait(1)
		check(main.zombie_is_stranded(z), "zombie inside a locked area is detected as stranded")
		main.respawn_zombie(z)
		check(_near_any(z.global_position, main.active_spawn_points(), 1.0) and not main.zombie_is_stranded(z), "stranded zombie moved to an open spawn")
		z.global_position = locked_spawn.global_position
		main._unreachable.clear()
		for i in int(main.stuck_respawn_time / main.stuck_check_interval) + 1:
			main._check_stuck_zombies(main.stuck_check_interval)
		check(_near_any(z.global_position, main.active_spawn_points(), 1.0), "watchdog respawns zombies stuck in a locked area")
		z.queue_free()
		await wait(1)

	# kill_y
	player.global_position = Vector3(spawn.global_position.x, main.kill_y - 5.0, spawn.global_position.z)
	await wait(2)
	check(player.global_position.y > main.kill_y and player.global_position.distance_to(spawn.global_position) < 1.0, "falling below kill_y respawns the player")

	# all doors
	map.open_all_doors()
	await wait(2)
	check(await _wait_bake(main.nav_region), "rebake after opening every door")
	check(main.active_spawn_points().size() == all_spawns.size(), "all doors open: all %d spawns active" % all_spawns.size())
	var all_ok := false
	for i in 120:
		all_ok = all_spawns.all(func(m): return _reaches(nav_map, spawn.global_position, m.global_position))
		if all_ok:
			break
		await physics_frame
	check(all_ok, "every spawn reachable with all doors open")

	# ---------------------------------------------------------------- back to the arena
	check(MapRegistry.select(MapRegistry.ARENA), "select arena")
	main = await _load_main()
	player = main.player
	check(main.map == null and main.map_id == MapRegistry.ARENA and main.has_node("NavigationRegion3D"), "arena loads as before (no map)")
	check(main.active_spawn_points().size() == main.spawn_points.get_child_count(), "arena: all spawns active")
	check(main.next_map_id() == RUSTWELL, "M key cycles arena -> rustwell_foundry")
	await _wait_bake(main.nav_region)
	await wait(20)

	# zombie attack height check
	var base: Vector3 = player.global_position
	var zt = main.ZOMBIE_SCENE.instantiate()
	zt.setup(1000, 0.0, 7)
	zt.attack_interval = 0.4
	main.zombies_root.add_child(zt)
	zt.global_position = base + Vector3(0.7, 0.0, 0.0)
	check(zt.in_attack_reach(1.0, 0.4) and not zt.in_attack_reach(1.0, 3.0) and not zt.in_attack_reach(1.0, -3.0), "in_attack_reach: same level yes, 3 m above/below no")
	player.max_health = 100000
	player.health = 100000
	player.damage_reduction = 0.0
	var h0: int = player.health
	for i in 90:
		player.global_position = base + Vector3(0.0, 3.0, 0.0)
		player.velocity = Vector3.ZERO
		zt.global_position = base + Vector3(0.7, 0.0, 0.0)
		await physics_frame
	check(player.health == h0, "zombie under a deck can't hit the player 3 m above (hp %d -> %d)" % [h0, player.health])
	for i in 90:
		player.global_position = base
		player.velocity = Vector3.ZERO
		zt.global_position = base + Vector3(0.7, 0.0, 0.0)
		await physics_frame
	check(player.health < h0, "same-level zombie still hits (hp %d -> %d)" % [h0, player.health])
	zt.queue_free()
	player.health = player.max_health
	await wait(2)

	# ground jump vs wall kick
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.4, 6.0, 4.0)
	cs.shape = bs
	wall.add_child(cs)
	main.add_child(wall)
	player.global_position = base
	player.velocity = Vector3.ZERO
	await wait(30)
	var feet: Vector3 = player.global_position
	wall.global_position = feet + Vector3(0.4 + 0.2 + 0.01, 3.0, 0.0)
	await wait(20)
	check(player.is_on_floor(), "player standing next to the wall")
	check(player.jump_kind(false) == "ground", "jump_kind: on the ground (even if is_on_floor flickers) = ground jump")
	var kicks: int = player.max_wall_jumps
	Input.action_press("jump")
	await wait(3)
	Input.action_release("jump")
	await wait(2)
	check(player.velocity.y > 1.0 and player._wall_jumps_left == kicks, "ground jump at a wall doesn't use a wall kick (%d/%d left)" % [player._wall_jumps_left, kicks])
	await wait(60)
	player.global_position = feet + Vector3(0.0, 3.0, 0.0)
	player.velocity = Vector3.ZERO
	await wait(10)
	check(not player.is_on_floor() and player.jump_kind(false) == "wall", "in the air at a wall = wall kick")
	Input.action_press("jump")
	await wait(3)
	Input.action_release("jump")
	await wait(1)
	check(player._wall_jumps_left == kicks - 1, "wall kick in the air still works (%d left)" % player._wall_jumps_left)
	wall.queue_free()
	await wait(30)

	# ---------------------------------------------------------------- zombie variants
	check(ZombieVariants.ids().size() == 6, "6 zombie variants in zombies.json (3 regular + bloated / crawler / riot)")
	var heights := {"city": 1.795, "worker": 1.821, "soldier": 1.821}
	for id in ["city", "worker", "soldier"]:
		var v := ZombieVariants.get_variant(id)
		var sc := ZombieVariants.scene(id)
		check(sc != null, "%s model loads (%s)" % [id, v.get("model", "")])
		if sc == null:
			continue
		var m: Node3D = sc.instantiate()
		root.add_child(m)
		var a := ModelUtil.get_aabb(m)
		check(absf(a.size.y - float(v.model_height)) < 0.02 and absf(float(v.model_height) - heights[id]) < 0.001,
			"%s native height %.3f m = model_height %.3f" % [id, a.size.y, v.model_height])
		m.queue_free()
		var z = main.ZOMBIE_SCENE.instantiate()
		z.setup(100, 2.0, 10)
		z.size_variety = 0.0
		z.set_variant(id, v, sc)
		main.zombies_root.add_child(z)
		await wait(1)
		var mi: Node3D = z.model_root.get_child(0)
		var h2 := ModelUtil.get_aabb(z.model_root).size.y
		check(absf(mi.scale.x - 1.0) < 0.02 and absf(h2 - heights[id]) < 0.02, "%s in game: %.3f m tall, scale %.3f (not shrunk)" % [id, h2, mi.scale.x])
		check(z.head_hitbox != null and z._anims.size() >= 6, "%s: head hitbox on the Head bone + %d clips" % [id, z._anims.size()])
		if id == "soldier":
			check(z.max_health > 100 and z.max_health <= 150, "soldier modestly tougher (%d hp vs 100)" % z.max_health)
		z.queue_free()
	var r1 := {}
	var r12 := {}
	for i in 1000:
		var t := (i + 0.5) / 1000.0
		r1[ZombieVariants.pick(1, t)] = r1.get(ZombieVariants.pick(1, t), 0) + 1
		r12[ZombieVariants.pick(12, t)] = r12.get(ZombieVariants.pick(12, t), 0) + 1
	check(r1.get("city", 0) >= 700 and r1.get("soldier", 0) == 0, "round 1 mostly city (%s)" % str(r1))
	check(r12.get("soldier", 0) >= 200 and r12.get("worker", 0) >= 200, "round 12 has more workers + soldiers (%s)" % str(r12))

	# ---------------------------------------------------------------- armor model mapping
	var slots: Array = root.get_node("GearDB").armor.get("slots", ["helmet", "gauntlets", "chest", "legs", "class_item"])
	for s in slots:
		var dp := ArmorModels.display_path(s)
		var sp := ArmorModels.skinned_path(s)
		var dsc := load(dp) as PackedScene if dp != "" and ResourceLoader.exists(dp) else null
		var ssc := load(sp) as PackedScene if sp != "" and ResourceLoader.exists(sp) else null
		check(dsc != null and ssc != null, "armor slot %s -> %s / %s load" % [s, sp.get_file(), dp.get_file()])
		if ssc:
			var n: Node = ssc.instantiate()
			var sks := n.find_children("*", "Skeleton3D", true, false)
			check(sks.size() > 0 and sks[0].get_bone_count() == 65 and sks[0].find_bone("Head") >= 0, "%s skinned on the 65-bone UAL2 skeleton" % s)
			n.free()
		if dsc:
			var n2: Node = dsc.instantiate()
			check(n2.find_children("*", "MeshInstance3D", true, false).size() > 0, "%s display model has meshes" % s)
			n2.free()
	check(ArmorModels.piece_for_slot("class_item", "soldier") == "sash" and ArmorModels.piece_for_slot("class_item", "scout") == "cloak", "class item look per class")
	check(ArmorModels.all_paths().size() == 12 and ArmorModels.all_paths().all(func(p): return ResourceLoader.exists(p)), "all 12 armor model paths exist")
	_finish()


func _finish() -> void:
	MapRegistry.select("")
	var progress = root.get_node("Progress")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(progress.save_path))
	print("MAP TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
