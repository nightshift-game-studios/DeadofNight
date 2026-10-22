extends SceneTree
## Night ambience (Audi-0 pack): loop flags, mix/bus, night bed, per-map layer, 3D emitters.
##   godot --headless --path . -s res://tests/ambience_test.gd   (exit code = failures)
## Never writes settings or saves.

var _fails := 0
var _passes := 0

const DIR := "res://assets/audio/ambience/"
const OGGS := ["ambience_night_bed_loop", "ambience_map_arena_loop", "ambience_map_rustwell_loop", "ambience_map_lockout_loop", "ambience_map_ironside_loop"]
const WAVS := ["ambience_emitter_sodium_buzz_loop", "ambience_emitter_sparking_box_loop", "ambience_emitter_drip_pipe_loop"]


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var sfx = root.get_node_or_null("Sfx")
	check(sfx != null, "Sfx autoload present")
	if sfx == null:
		_finish()
		return
	await wait(2)

	# ---------------------------------------------------------------- files + loop flags (from the .import files)
	for k in OGGS:
		var o = ResourceLoader.load(DIR + k + ".ogg", "", ResourceLoader.CACHE_MODE_IGNORE)
		check(o is AudioStreamOggVorbis and o.loop and o.get_length() > 30.0, "%s.ogg loads and loops (import loop=true)" % k)
	for k in WAVS:
		var w = ResourceLoader.load(DIR + k + ".wav", "", ResourceLoader.CACHE_MODE_IGNORE)
		check(w is AudioStreamWAV and w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_begin == 0 and w.get_length() > 1.0,
			"%s.wav loads and loops forward (import loop_mode=2)" % k)

	# ---------------------------------------------------------------- bank + mix
	var expect := {"ambience_night_bed_loop": -2.0, "ambience_map_arena_loop": -4.0, "ambience_map_rustwell_loop": -3.0,
		"ambience_map_lockout_loop": -3.0, "ambience_map_ironside_loop": -3.0, "ambience_emitter_sodium_buzz_loop": -6.0,
		"ambience_emitter_sparking_box_loop": -6.0, "ambience_emitter_drip_pipe_loop": -6.0}
	for k in expect:
		var m: Array = sfx.mix(k)
		check(sfx.has(k) and m[2] == "Ambience" and is_equal_approx(float(m[0]), expect[k]),
			"%s in bank, MIX %.1f dB on Ambience (%s)" % [k, expect[k], str(m)])
	check(sfx.has("ambience_wind_industrial_loop"), "old wind bed still in the bank (fallback)")

	# ---------------------------------------------------------------- bus + Settings slider
	var bi := AudioServer.get_bus_index("Ambience")
	check(bi >= 0 and AudioServer.get_bus_send(bi) == &"Master", "Ambience bus exists and sends to Master")
	var settings = root.get_node_or_null("Settings")
	check(settings != null and "vol_Ambience" in settings and settings.AUDIO_BUSES.has("Ambience"), "Settings exposes vol_Ambience")
	if settings and bi >= 0:
		var old: float = settings.vol_Ambience
		settings.vol_Ambience = 0.5
		settings._apply_audio() # no _commit: never touches settings.cfg
		check(is_equal_approx(AudioServer.get_bus_volume_db(bi), linear_to_db(0.5)), "vol_Ambience drives the Ambience bus volume")
		settings.vol_Ambience = old
		settings._apply_audio()

	# ---------------------------------------------------------------- night bed
	var bed: AudioStreamPlayer = sfx._ambience
	check(bed != null and bed.playing and bed.bus == &"Ambience" and bed.stream != null
		and bed.stream.resource_path.ends_with("ambience_night_bed_loop.ogg") and is_equal_approx(bed.volume_db, -2.0),
		"night bed playing on Ambience at -2 dB (replaces the wind bed)")

	# ---------------------------------------------------------------- per-map layer
	var layer: AudioStreamPlayer = sfx._ambience_map
	var files := {"arena": "ambience_map_arena_loop.ogg", "rustwell_foundry": "ambience_map_rustwell_loop.ogg",
		"lockout_substation": "ambience_map_lockout_loop.ogg", "ironside_depot": "ambience_map_ironside_loop.ogg"}
	var maps_ok := true
	for m in MapRegistry.list():
		maps_ok = maps_ok and sfx.MAP_AMBIENCE.has(str(m.get("id", "")))
	check(maps_ok and MapRegistry.list().size() >= 3, "MAP_AMBIENCE covers every map id in data/maps.json")
	for id in files:
		sfx.set_map_ambience(id)
		check(layer.playing and layer.bus == &"Ambience" and layer.stream.resource_path.ends_with(files[id])
			and sfx.map_ambience_key == sfx.MAP_AMBIENCE[id] and is_equal_approx(layer.volume_db, float(sfx.mix(sfx.MAP_AMBIENCE[id])[0])),
			"map layer switches to %s for %s" % [files[id], id])
	sfx.set_map_ambience("no_such_map")
	check(not layer.playing and sfx.map_ambience_key == "", "unknown map id stops the map layer")
	check(bed.playing, "night bed keeps playing across map switches")

	# ---------------------------------------------------------------- 3D emitters
	var holder := Node3D.new()
	root.add_child(holder)
	var buzz := Marker3D.new()
	buzz.set_meta("ambience_key", "ambience_emitter_sodium_buzz_loop")
	holder.add_child(buzz)
	var drip := Marker3D.new()
	drip.set_meta("ambience_key", "ambience_emitter_drip_pipe_loop")
	holder.add_child(drip)
	var plain := Marker3D.new()
	holder.add_child(plain)
	check(sfx.attach_emitters(holder) == 2, "attach_emitters attaches one loop per node with meta ambience_key")
	var pb := buzz.get_node_or_null("AmbienceEmitter") as AudioStreamPlayer3D
	var pd := drip.get_node_or_null("AmbienceEmitter") as AudioStreamPlayer3D
	check(pb != null and pb.playing and pb.bus == &"Ambience" and is_equal_approx(pb.unit_size, 6.0) and is_equal_approx(pb.max_distance, 18.0)
		and is_equal_approx(pb.volume_db, -6.0), "sodium buzz emitter: Ambience bus, unit 6, max 18 m, -6 dB")
	check(pd != null and pd.playing and pd.bus == &"Ambience" and is_equal_approx(pd.max_distance, 12.0), "drip emitter: Ambience bus, max 12 m")
	check(plain.get_child_count() == 0, "node without meta gets no emitter")
	holder.queue_free()

	# ---------------------------------------------------------------- main.gd hookup
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	var main = current_scene
	check(main != null and main.has_method("_setup_ambience"), "main.tscn loaded")
	if main:
		main._break_timer = 9999.0
		check(sfx.map_ambience_key == sfx.MAP_AMBIENCE.get(main.map_id, "?") and layer.playing,
			"main sets the map layer on load (%s -> %s)" % [main.map_id, sfx.map_ambience_key])
		var spot := Marker3D.new()
		spot.set_meta("ambience_key", "ambience_emitter_sparking_box_loop")
		var map_root: Node = main.map if main.map else main.get_node("NavigationRegion3D")
		map_root.add_child(spot)
		check(main._setup_ambience() >= 1 and spot.get_node_or_null("AmbienceEmitter") != null, "main scans the map for ambience_key nodes")
		spot.queue_free()
	_finish()


func _finish() -> void:
	print("AMBIENCE TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
