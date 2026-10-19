extends Node3D
## Game flow: bakes the navmesh, runs round-based zombie waves, awards points,
## rolls loot (data/loot_tables.json), re-arms chests, handles game over / saving.
## Field Cards: after every cleared round (n >= 1) the offer opens after offer_delay seconds; the tree
## pauses until RunState.offer_closed, then the round_break countdown runs. Chooser UI: Gooey's
## scripts/ui/run_pick_menu.gd.
## Maps: MapRegistry (data/maps.json) picks the level. "arena" = the built-in level in this scene (default/fallback);
## any other map (map contract v0.2, e.g. res://maps/rustwell_foundry/) replaces the arena nodes before the navmesh
## bake: area-gated spawns (map.active_spawn_points()), buyable doors (MapDoor -> player.spend_points), chests and
## pickups instanced at the map's markers, PlayerSpawn, kill_y, and a stuck-zombie watchdog.
## Zombie variants: data/zombies.json (ZombieVariants.pick(round) mixes city / worker / soldier per round).

const ZOMBIE_SCENE := preload("res://scenes/enemy.tscn")
const BossCatalogScr := preload("res://scripts/enemies/boss_catalog.gd")
const PICKUP_SCENE := preload("res://scenes/pickup.tscn")
const CharacterScreen := preload("res://scripts/ui/character_screen.gd")
const SkillTreeMenu := preload("res://scripts/ui/skill_tree_menu.gd")
const MAP_PICKER_PATH := "res://scripts/ui/map_picker.gd" ## Gooey's map picker
var map_picker: Node
const PAUSE_MENU_PATH := "res://scripts/ui/pause_menu.gd"
const SETTINGS_MENU_PATH := "res://scripts/ui/settings_menu.gd"
var pause_menu: Node
var settings_menu: Node
const RUN_PICK_MENU_PATH := "res://scripts/ui/run_pick_menu.gd" ## Gooey's chooser (listens to RunState.offer_ready)
const CHEST_SCENE := preload("res://scenes/chest.tscn")
const PICKUP_ITEMS := {"health_pack": "res://resources/items/health_pack.tres", "heavy_ammo": "res://resources/items/heavy_ammo.tres",
	"primary_ammo": "res://resources/items/ammo_box.tres", "ammo_box": "res://resources/items/ammo_box.tres"}
## Arena nodes a loaded map replaces (the map brings its own).
const ARENA_NODES := ["NavigationRegion3D", "SpawnPoints", "Chests", "Decor", "WorldEnvironment", "Sun", "PowerWeaponSpot",
	"NightLights", "AmbienceEmitters"] ## arena night kit (Mapz) goes too when a map loads

@export_group("Waves")
@export var first_round_zombies: int = 6
@export var zombies_per_round: int = 3 ## extra zombies each round
@export var base_health: int = 90
@export var health_per_round: int = 35
@export var base_speed: float = 2.4
@export var speed_per_round: float = 0.3
@export var max_speed: float = 6.0
@export var max_alive: int = 16 ## cap on zombies alive at once
@export var spawn_interval: float = 1.1 ## seconds between spawns
@export var round_break: float = 6.0 ## seconds between rounds (after the Field Card pick)
@export var base_damage: int = 10 ## zombie swing damage in round 1
@export var damage_per_round: int = 2 ## ... plus this per round
@export var offer_delay: float = 1.0 ## seconds after a round clears before the Field Card offer opens
@export var field_cards_enabled: bool = true
@export var use_zombie_variants: bool = true ## mix data/zombies.json variants into the waves

@export_group("Map")
## Overrides MapRegistry when set (e.g. a test scene). Null = MapRegistry.current_scene() (null there = built-in arena).
@export var map_scene: PackedScene
@export var stuck_check_interval: float = 1.0 ## seconds between stuck-zombie checks (maps only)
@export var stuck_respawn_time: float = 4.0 ## a zombie that can't path to PlayerSpawn this long is moved to an open spawn

@export_group("Points")
@export var points_per_hit: int = 5 ## halved 2026-10-19 (was 10); runtime value comes from data/economy.json
@export var points_per_kill: int = 50 ## halved 2026-10-19 (was 100)

@onready var player = $Player
@onready var hud = $HUD
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var spawn_points: Node3D = $SpawnPoints
@onready var zombies_root: Node3D = $Zombies
@onready var pickups_root: Node3D = $Pickups

var character_screen: MenuBase
var skill_menu: MenuBase
var current_round: int = 0
var kills: int = 0
var _to_spawn: int = 0
var _alive: int = 0
var _spawn_timer: float = 0.0
var _break_timer: float = 0.0
var _game_over: bool = false
var _last_earned: int = 0
var hit_sfx: HitSfx ## hitmarker sounds (optional files in res://assets/audio/sfx/ui/)
var _last_points: int = 0
var run_pick_menu: Node ## chooser UI for Field Card offers
var _offer_pending: bool = false ## round cleared, waiting for / inside the offer
var _offer_delay: float = 0.0
var map: Node3D ## the loaded map root (MapRoot), null on the built-in arena
var map_id: String = MapRegistry.ARENA
var kill_y: float = -25.0
var _stuck_t: float = 0.0
var _unreachable: Dictionary = {} ## zombie instance id -> seconds it has had no path to PlayerSpawn
var _player_spawn: Transform3D


func _ready() -> void:
	# Economy (Skillz): data/economy.json via Progress. Halved for the playtest (10/100 -> 5/50).
	var prog := get_node_or_null("/root/Progress")
	if prog and "points_per_hit" in prog:
		points_per_hit = prog.points_per_hit
		points_per_kill = prog.points_per_kill
	_player_spawn = player.global_transform
	_load_map()
	# Difficulty (Skillz): scale the wave exports by the map's profile (data/difficulty.json) and make it active.
	# Also turns on the reward scaling (XP in Progress.record_match, loot rarity bias in GearDB.roll_rarity).
	Difficulty.apply_to_main(self)
	_setup_ambience()
	# Bake the navmesh from the level's static colliders at startup, so it always
	# matches the level even after you move things around in the editor.
	nav_region.bake_navigation_mesh(true)

	player.health_changed.connect(hud.set_health)
	player.ammo_changed.connect(hud.set_ammo)
	player.points_changed.connect(hud.set_points)
	player.ability_changed.connect(hud.set_ability)
	player.grenade_changed.connect(hud.set_grenade)
	player.melee_changed.connect(hud.set_melee)
	player.weapon_changed.connect(hud.set_weapon)
	player.weapons_updated.connect(func(): hud.update_weapons(player.inventory))
	player.pickup_prompt_changed.connect(hud.show_hint)
	player.loot_received.connect(hud.add_loot)
	player.hit_registered.connect(hud.on_hit_registered)
	hit_sfx = HitSfx.new()
	hit_sfx.name = "HitSfx"
	add_child(hit_sfx)
	player.hit_registered.connect(hit_sfx.on_hit)
	player.died.connect(_on_player_died)
	player.points_changed.connect(_on_points_changed)
	RunState.player = player
	RunState.clear() # new match: no Field Cards, free rerolls / banishes refilled from the meta tree
	if not RunState.offer_closed.is_connected(_on_offer_closed):
		RunState.offer_closed.connect(_on_offer_closed)
	if not RunState.offer_ready.is_connected(_on_offer_ready):
		RunState.offer_ready.connect(_on_offer_ready)
	Progress.respec_allowed = true

	character_screen = CharacterScreen.new()
	character_screen.toggle_action = "inventory"
	character_screen.player = player
	character_screen.closed.connect(_on_menu_closed)
	add_child(character_screen)
	skill_menu = SkillTreeMenu.new()
	skill_menu.toggle_action = "skill_tree"
	skill_menu.closed.connect(_on_menu_closed)
	if ResourceLoader.exists(MAP_PICKER_PATH):
		map_picker = load(MAP_PICKER_PATH).new()
		map_picker.name = "MapPicker"
		map_picker.main = self
		add_child(map_picker)
	if ResourceLoader.exists(SETTINGS_MENU_PATH):
		settings_menu = load(SETTINGS_MENU_PATH).new()
		settings_menu.name = "SettingsMenu"
		settings_menu.main = self
		add_child(settings_menu)
	if ResourceLoader.exists(PAUSE_MENU_PATH):
		pause_menu = load(PAUSE_MENU_PATH).new()
		pause_menu.name = "PauseMenu"
		pause_menu.main = self
		pause_menu.settings_menu = settings_menu
		add_child(pause_menu)
	skill_menu.skill_unlocked.connect(_on_skill_unlocked)
	add_child(skill_menu)
	run_pick_menu = load(RUN_PICK_MENU_PATH).new()
	run_pick_menu.name = "RunPickMenu"
	add_child(run_pick_menu)

	# A guaranteed Rare rocket launcher up on the platform (the Power slot starts empty).
	var spot := (map if map else self).get_node_or_null("PowerWeaponSpot") as Node3D
	if spot:
		spawn_pickup(GearDB.roll_weapon("rocket_launcher", Rarity.RARE, 1), spot.global_position, false)
	_update_hint()
	_break_timer = 8.0 # grace period before round 1 (open the skill tree with K)
	hud.set_enemies(0)
	hud.set_round(0)
	_music("menu") # pre-round: menu loop; "break" between rounds, "combat" during a round


func _sfx() -> Node:
	return get_node_or_null("/root/Sfx")


func _music(state: String) -> void:
	var a := _sfx()
	if a:
		a.set_music(state)


func _snd(key: String) -> void:
	var a := _sfx()
	if a:
		a.play(key)


func _on_points_changed(p: int) -> void:
	if p > _last_points:
		var a := _sfx()
		if a:
			a.points_tick()
	_last_points = p


func _physics_process(delta: float) -> void:
	if _game_over:
		return
	if player.global_position.y < kill_y:
		_respawn_player()
	if map:
		_stuck_t -= delta
		if _stuck_t <= 0.0:
			_check_stuck_zombies(stuck_check_interval)
			_stuck_t = stuck_check_interval
	if _to_spawn == 0 and _alive == 0:
		if _offer_pending:
			if not RunState.offer_open:
				_offer_delay -= delta
				if _offer_delay <= 0.0:
					RunState.open_offer(current_round)
			return
		_break_timer -= delta
		if _break_timer <= 0.0:
			_start_round(current_round + 1)
		return
	if _to_spawn > 0 and _alive < max_alive:
		_spawn_timer -= delta
		if _spawn_timer <= 0.0:
			_spawn_timer = spawn_interval
			_spawn_zombie()


func _start_round(n: int) -> void:
	current_round = n
	Progress.respec_allowed = false
	_update_hint()
	_to_spawn = first_round_zombies + zombies_per_round * (n - 1)
	_spawn_timer = 0.0
	# Bosses (Skillz): cadence from Difficulty; identities from BossCatalog / data/bosses.json.
	if Difficulty.is_boss_round(n):
		for boss_id in BossCatalogScr.pick_roster(n):
			_spawn_boss(str(boss_id))
	player.refill_ammo()
	for c in get_tree().get_nodes_in_group("chests"):
		c.rearm(n) # chests can be opened once per round
	hud.set_round(n)
	hud.set_enemies(_to_spawn + _alive)
	_snd("round_start_stinger")
	_music("combat")
	GameEvents.emit_event(&"round_started", {"player": player, "round": n})


func _zombie_stats(n: int) -> Dictionary:
	return {
		"health": base_health + health_per_round * (n - 1),
		"speed": min(base_speed + speed_per_round * (n - 1), max_speed),
		"damage": base_damage + damage_per_round * (n - 1),
	}


## Spawn markers zombies may use right now: the map's unlocked areas, or every arena spawn.
func active_spawn_points() -> Array:
	if map and map.has_method("active_spawn_points"):
		return map.active_spawn_points()
	return spawn_points.get_children()


func _spawn_zombie() -> void:
	var points := active_spawn_points()
	if points.is_empty():
		return
	var candidates: Array = points.filter(func(p): return p.global_position.distance_to(player.global_position) > 8.0)
	if candidates.is_empty():
		candidates = points
	var spawn: Node3D = candidates.pick_random()
	var stats := _zombie_stats(current_round)
	var z = ZOMBIE_SCENE.instantiate()
	# Every few zombies is a faster "runner".
	var spd: float = stats.speed * (1.35 if randf() < 0.25 else 1.0)
	z.setup(stats.health, spd, stats.damage)
	if use_zombie_variants:
		var vid := Difficulty.pick_variant(current_round) # profile-weighted mix (more Soldiers, sooner, on Hard)
		var sc := ZombieVariants.scene(vid)
		if sc:
			z.set_variant(vid, ZombieVariants.get_variant(vid), sc)
	z.hit.connect(_on_zombie_hit)
	z.died.connect(_on_zombie_died)
	zombies_root.add_child(z)
	z.global_position = spawn.global_position + Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
	_to_spawn -= 1
	_alive += 1


func _spawn_boss(boss_id: String) -> void:
	var points := active_spawn_points()
	if points.is_empty():
		return
	var candidates: Array = points.filter(func(p): return p.global_position.distance_to(player.global_position) > 10.0)
	if candidates.is_empty():
		candidates = points
	var spawn: Node3D = candidates.pick_random()
	var stats := _zombie_stats(current_round)
	var z = ZOMBIE_SCENE.instantiate()
	var script_path := BossCatalogScr.script_path(boss_id)
	if script_path != "" and ResourceLoader.exists(script_path):
		z.set_script(load(script_path))
	# Base wave stats first; configure_boss replaces HP with catalog formula (x Difficulty.boss_cfg.hp_mult).
	z.setup(stats.health, stats.speed, stats.damage)
	if z.has_method("configure_boss"):
		z.configure_boss(boss_id, current_round, Difficulty.active_id())
	z.hit.connect(_on_zombie_hit)
	z.died.connect(_on_zombie_died)
	if z.has_signal("request_echo"):
		z.request_echo.connect(_on_boss_request_echo)
	zombies_root.add_child(z)
	z.global_position = spawn.global_position + Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	_alive += 1


func _on_boss_request_echo(host: Node, count: int) -> void:
	# Choir Host adds: 0.4x normal HP, no Gravemark, standard kill points.
	for i in count:
		var points := active_spawn_points()
		if points.is_empty():
			return
		var spawn: Node3D = points.pick_random()
		var stats := _zombie_stats(current_round)
		var z = ZOMBIE_SCENE.instantiate()
		var ehp := BossCatalogScr.echo_hp(current_round, base_health, health_per_round)
		var echo: Dictionary = BossCatalogScr.echo_cfg()
		z.setup(ehp, stats.speed * float(echo.get("speed_mult", 1.1)),
			maxi(int(round(stats.damage * float(echo.get("damage_mult", 0.7)))), 1))
		z.set_meta("boss_echo", true)
		z.hit.connect(_on_zombie_hit)
		z.died.connect(_on_zombie_died)
		zombies_root.add_child(z)
		var origin: Vector3 = host.global_position if host is Node3D else spawn.global_position
		z.global_position = origin + Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
		_alive += 1


var _hit_paid: Dictionary = {} ## zombie instance id -> physics frame its hit points were last paid


func _on_zombie_hit(zombie: Node, _amount: int) -> void:
	if _game_over:
		return
	# hit points once per shot per target: pellets/explosions landing in the same physics frame pay once
	var id := zombie.get_instance_id()
	var f := Engine.get_physics_frames()
	if _hit_paid.get(id, -1) == f:
		return
	_hit_paid[id] = f
	if _hit_paid.size() > 256:
		_hit_paid.clear()
	player.add_points(points_per_hit, "hit")


func _on_zombie_died(zombie: Node) -> void:
	_alive = max(_alive - 1, 0)
	if _game_over:
		return
	kills += 1
	var pay := points_per_kill
	var gravemark_gain := 0
	if zombie.has_meta("is_boss") and zombie.get_meta("is_boss"):
		var bid := str(zombie.get_meta("boss_id", ""))
		pay = BossCatalogScr.kill_points(bid, points_per_kill)
		gravemark_gain = BossCatalogScr.gravemark_scaled(bid) # int for Progress when currency lands
	elif zombie.has_meta("boss_echo"):
		pay = points_per_kill # echoes: normal kill, no Gravemark
	player.add_points(int(round(pay * player.mod_stat("points_kill_mult", 1.0))), "kill")
	# TODO (attachments pass): Progress.add_gravemark(gravemark_gain) when Gravemark is wired
	for item in GearDB.roll_table("zombie", current_round, player.mod_stat("drop_chance_add", 0.0)):
		spawn_pickup(item, (zombie as Node3D).global_position)
	hud.set_enemies(_to_spawn + _alive)
	if _to_spawn == 0 and _alive == 0:
		_break_timer = round_break
		_snd("round_end_stinger")
		_music("break")
		GameEvents.emit_event(&"round_cleared", {"player": player, "round": current_round})
		if field_cards_enabled and current_round >= 1:
			_offer_pending = true
			_offer_delay = offer_delay


## RunState opened (or redrew) an offer: pause and free the mouse for the chooser.
func _on_offer_ready(_cards: Array, _is_milestone: bool) -> void:
	if _game_over:
		return
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Card chosen or offer skipped: unpause, then the normal round break (looting, chests) runs.
func _on_offer_closed(_result: String, _id: String) -> void:
	_offer_pending = false
	_break_timer = round_break
	get_tree().paused = false
	if not _game_over:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_hint()


## Drops `item` into the world. `chime` plays the loot chime for its rarity.
func spawn_pickup(item: Item, pos: Vector3, chime: bool = true) -> void:
	if item == null:
		return
	var a := _sfx()
	if chime and a:
		var g := item as GearItem
		a.loot_chime(Rarity.IDS[g.rarity] if g else "common")
	var p = PICKUP_SCENE.instantiate()
	p.item = item
	pickups_root.add_child(p)
	p.global_position = pos


## Controls are only hinted at match start (and on the game-over / skill screens).
func _update_hint() -> void:
	if current_round == 0 or _game_over:
		hud.set_hint("WASD MOVE   SHIFT SPRINT   C SLIDE   SPACE WALL-JUMP   G GRENADE   V MELEE   Q ABILITY\n"
			+ "E INTERACT   1-3 WEAPONS   TAB LOADOUT   K SKILLS (%d PTS)   M MAP: %s" % [Progress.skill_points_available(),
			str(MapRegistry.get_info(map_id).get("display_name", map_id)).to_upper()],
			9.0 if not _game_over else 9999.0)
	else:
		hud.set_hint("")


func _on_skill_unlocked(_id: String) -> void:
	if current_round == 0 and not _game_over:
		player.apply_stats()
	_update_hint()


func _on_menu_closed() -> void:
	hud.visible = true
	if _game_over:
		_show_game_over(_last_earned)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_hint()


func _on_player_died() -> void:
	if _game_over:
		return
	_game_over = true
	player.input_enabled = false
	Progress.respec_allowed = true
	GameEvents.emit_event(&"match_ended", {"player": player, "round": current_round, "kills": kills})
	RunState.clear() # Field Cards are per match; also restores Engine.time_scale
	player.skill_runner.rebuild()
	player.recalc_stats()
	_offer_pending = false
	_last_earned = Progress.record_match(kills, current_round)
	_snd("game_over_sting")
	_music("menu")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_game_over(_last_earned)
	_update_hint()


func _show_game_over(earned: int) -> void:
	var text := "GAME OVER\nYou survived %d round%s  |  Kills: %d  |  +%d XP\n" % [
		current_round, "" if current_round == 1 else "s", kills, earned]
	text += "Best round: %d   Total kills: %d   Level %d (%d XP)\n\n" % [
		Progress.best_round, Progress.total_kills, Progress.get_level(), Progress.xp]
	text += "Class for next game: %s   (1 = Soldier, 2 = Scout)\n" % \
		Progress.load_selected_class().display_name
	text += "K = Skill Tree (%d points)   |   M = map: %s   |   Enter = restart" % [Progress.skill_points_available(),
		str(MapRegistry.get_info(map_id).get("display_name", map_id))]
	hud.show_message(text, Color(1.0, 0.4, 0.35))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("inventory") and not _game_over:
		get_viewport().set_input_as_handled()
		hud.visible = false
		character_screen.open()
		return
	if event.is_action_pressed("map_next") and (current_round == 0 or _game_over):
		get_viewport().set_input_as_handled()
		if map_picker:
			map_picker.open()
		else:
			restart_with_map(next_map_id())
		return
	if event.is_action_pressed("skill_tree") and (current_round == 0 or _game_over):
		get_viewport().set_input_as_handled()
		hud.hide_message()
		skill_menu.open()
		return
	if not _game_over:
		return
	if event.is_action_pressed("restart"):
		get_tree().reload_current_scene()
	elif event.is_action_pressed("weapon_1"):
		_pick_class("soldier")
	elif event.is_action_pressed("weapon_2"):
		_pick_class("scout")


func _pick_class(class_id: String) -> void:
	Progress.selected_class = class_id
	Progress.save_data()
	_show_game_over(_last_earned)


# ------------------------------------------------------------------ maps

## Swaps the built-in arena for the selected map (before the first navmesh bake). No-op on the arena.
func _load_map() -> void:
	var sc: PackedScene = map_scene if map_scene else MapRegistry.current_scene()
	if sc == null:
		map_id = MapRegistry.ARENA
		return
	for n in ARENA_NODES:
		var old := get_node_or_null(n)
		if old:
			remove_child(old)
			old.queue_free()
	for p in pickups_root.get_children(): # the arena's hand-placed health packs / ammo
		pickups_root.remove_child(p)
		p.queue_free()
	map = sc.instantiate()
	map.name = "Map"
	add_child(map)
	move_child(map, 0)
	map_id = str(map.get("map_id")) if map.get("map_id") else MapRegistry.current_id()
	nav_region = map.get_node("NavigationRegion3D")
	spawn_points = map.get_node("SpawnPoints")
	kill_y = float(map.get("kill_y")) if map.get("kill_y") != null else float(map.get_meta("kill_y", -25.0))
	var ps := map.get_node_or_null("PlayerSpawn") as Node3D
	if ps:
		_player_spawn = Transform3D(Basis(Vector3.UP, ps.global_rotation.y), ps.global_position)
		player.global_transform = _player_spawn
		player.velocity = Vector3.ZERO
	# Chests go under the NavigationRegion3D before the first bake, so zombies path around them.
	var chests := map.get_node_or_null("Chests")
	if chests:
		var holder := Node3D.new()
		holder.name = "SpawnedChests"
		nav_region.add_child(holder)
		for m in chests.get_children():
			if not m is Node3D:
				continue
			var c := CHEST_SCENE.instantiate()
			c.loot_table = str(m.get_meta("loot_table", "chest"))
			c.set_meta("area", m.get_meta("area", &"start"))
			holder.add_child(c)
			c.global_transform = (m as Node3D).global_transform
	var spots := map.get_node_or_null("PickupSpots")
	if spots:
		for m in spots.get_children():
			if not m is Node3D:
				continue
			var path: String = PICKUP_ITEMS.get(str(m.get_meta("item", "health_pack")), PICKUP_ITEMS.health_pack)
			var p = PICKUP_SCENE.instantiate()
			p.item = load(path)
			pickups_root.add_child(p)
			p.global_position = (m as Node3D).global_position
	if map.has_signal("area_unlocked"):
		map.area_unlocked.connect(_on_area_unlocked)
	for d in (map.doors() if map.has_method("doors") else []):
		if d.has_signal("opened"):
			d.opened.connect(_on_door_opened)


## Doors: MapDoor.interact() already charged player.spend_points(cost); here we only react.
func _on_door_opened(door: Node) -> void:
	_snd("chest_open")
	GameEvents.emit_event(&"door_opened", {"player": player, "door": door, "cost": int(door.get("cost"))})


func _on_area_unlocked(area: StringName) -> void:
	if _game_over:
		return
	hud.set_hint(String(area).replace("_", " ").to_upper() + " OPENED", 2.5)
	GameEvents.emit_event(&"area_unlocked", {"player": player, "area": area})


## Night ambience (Audi-0): per-map layer for map_id + 3D loops on every map node with meta ambience_key.
## Returns the number of emitters attached.
func _setup_ambience() -> int:
	var a := _sfx()
	if a == null:
		return 0
	if a.has_method("set_map_ambience"):
		a.set_map_ambience(map_id)
	var root: Node = map if map else self # arena: AmbienceEmitters sits under Main
	if root == null:
		return 0
	var n := 0
	for node in root.find_children("*", "Node3D", true, false):
		if node.has_meta("ambience_key") and a.attach_loop(str(node.get_meta("ambience_key")), node) != null:
			n += 1
	return n


## Map picker API (Gooey): select a map and restart the match on it. Returns false for unknown ids.
func restart_with_map(id: String) -> bool:
	if not MapRegistry.select(id):
		return false
	var a := _sfx() # switch the map ambience layer now; the reloaded scene re-attaches emitters
	if a and a.has_method("set_map_ambience"):
		a.set_map_ambience(id)
	get_tree().paused = false
	get_tree().reload_current_scene()
	return true


const HOME_SCENE := "res://scenes/ui/home.tscn"

## Pause "Quit to Home" / game-over exit: save stash, unpause, leave the match.
func return_to_home() -> void:
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("save_stash"):
		prog.save_stash()
	get_tree().paused = false
	get_tree().change_scene_to_file(HOME_SCENE)


## The map after the current one in data/maps.json (wraps around). Used by the M key before round 1 / after game over.
func next_map_id() -> String:
	var ids: Array = MapRegistry.list().map(func(m): return str(m.get("id", ""))).filter(func(i): return MapRegistry.is_valid(i))
	if ids.is_empty():
		return MapRegistry.ARENA
	return ids[(ids.find(map_id) + 1) % ids.size()]


func _respawn_player() -> void:
	player.global_transform = _player_spawn
	player.velocity = Vector3.ZERO


## A zombie that has had no navmesh path to PlayerSpawn for stuck_respawn_time seconds (knocked into a
## locked area, off the mesh, fell out of the map) is moved to a random open spawn. PlayerSpawn sits in the
## start area, so it's connected to every unlocked area: "no path" means the zombie is somewhere it shouldn't be.
func _check_stuck_zombies(dt: float) -> void:
	var nav_map := nav_region.get_navigation_map()
	if not nav_map.is_valid() or NavigationServer3D.map_get_iteration_id(nav_map) == 0 or nav_region.is_baking():
		return
	var goal := NavigationServer3D.map_get_closest_point(nav_map, _player_spawn.origin)
	var seen := {}
	for z in zombies_root.get_children():
		if not z is Node3D or not z.is_in_group("enemies"):
			continue
		var id := z.get_instance_id()
		seen[id] = true
		if zombie_is_stranded(z, nav_map, goal):
			_unreachable[id] = float(_unreachable.get(id, 0.0)) + dt
			if _unreachable[id] >= stuck_respawn_time or z.global_position.y < kill_y:
				respawn_zombie(z)
				_unreachable.erase(id)
		else:
			_unreachable.erase(id)
	for id in _unreachable.keys():
		if not seen.has(id):
			_unreachable.erase(id)


func zombie_is_stranded(z: Node3D, nav_map: RID = RID(), goal = null) -> bool:
	if z.global_position.y < kill_y:
		return true
	if not nav_map.is_valid():
		nav_map = nav_region.get_navigation_map()
	if goal == null:
		goal = NavigationServer3D.map_get_closest_point(nav_map, _player_spawn.origin)
	var from := NavigationServer3D.map_get_closest_point(nav_map, z.global_position)
	if from.distance_to(z.global_position) > 2.5: # off the navmesh entirely
		return true
	var path := NavigationServer3D.map_get_path(nav_map, from, goal, true)
	return path.is_empty() or path[path.size() - 1].distance_to(goal) > 1.5


func respawn_zombie(z: Node3D) -> void:
	var pts := active_spawn_points()
	if pts.is_empty():
		return
	var cand: Array = pts.filter(func(p): return p.global_position.distance_to(player.global_position) > 8.0)
	var sp: Node3D = (cand if not cand.is_empty() else pts).pick_random()
	z.global_position = sp.global_position + Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
	z.velocity = Vector3.ZERO
	if "knockback" in z:
		z.knockback = Vector3.ZERO
