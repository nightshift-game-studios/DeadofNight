extends SceneTree
## Co-op HUD + callout banner test (Gooey):  godot --headless --path . -s res://tests/coop_hud_test.gd
## Netz API (stub mirrors it): Net.match_players life_changed / revive_changed / all_down / life_of, points_changed,
## world.spend_result / door_refused, round_state_changed, callout_received (+ de-dup with Callouts.callout_played).
## hud.gd builds CoopHud (teammate list, revive bar both roles, bleed-out timer; hidden in solo) and CalloutBanner
## (Callouts.callout_played → stamped banner: local vs teammate text + tint, ~2 s timing, priority replace + queue +
## expiry, callouts.json labels + event_id fallback, defensive bind). Driven by the lobby_api.gd stub signals and a
## locally added Callouts node (the autoload isn't registered in project.godot yet). Exit code = number of failures.

var _fails := 0
var _passes := 0
var hud
var coop
var ban
var net
var LAPI


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func row(peer: int) -> Node:
	return coop.mate_row(peer)


func row_text(peer: int, child: String) -> String:
	var r = row(peer)
	var l = r.find_child(child, true, false) if r else null
	return str(l.text) if l else "<none>"


func _run() -> void:
	LAPI = load("res://scripts/ui/lobby_api.gd")
	var real_cp = root.get_node_or_null("Callouts")
	check(real_cp != null and real_cp.has_signal("callout_played"), "Callouts autoload registered (project.godot)")
	var probe = load("res://scripts/hud.gd").new()
	root.add_child(probe)
	await frames(2)
	check(real_cp != null and real_cp.callout_played.is_connected(probe.callout_banner.on_callout), "HUD banner binds the real Callouts autoload in _ready (no main.gd hook)")
	probe.queue_free()
	await frames(1)
	if real_cp:
		real_cp.name = "CalloutsAutoloadParked" # defensive path: HUD below is built with no /root/Callouts
	LAPI = load("res://scripts/ui/lobby_api.gd")
	LAPI.force_stub = true # Netz tree: never instantiate the real net.gd here
	var real_net = root.get_node_or_null("Net")
	if real_net:
		real_net.name = "NetAutoloadParked" # Netz tree: park the real Net so this suite drives the stub (lobby_net_test covers Net)
	check(root.get_node_or_null("Net") == null, "stub path (Net %s)" % ("parked" if real_net else "not installed"))
	hud = load("res://scripts/hud.gd").new()
	root.add_child(hud)
	await frames(3)
	coop = hud.coop_hud
	ban = hud.callout_banner
	check(coop != null and ban != null, "HUD builds CoopHud + CalloutBanner")
	check(hud.has_method("set_party") and hud.has_method("set_revive") and hud.has_method("set_local_downed") and hud.has_method("show_callout"), "HUD co-op forwarders")

	# ---------------------------------------------------------------- solo: everything co-op hidden
	check(not coop.visible, "solo (no Net): co-op HUD hidden")
	hud.set_party([{"peer_id": 1, "name": "Me"}, {"peer_id": 2, "name": "Jason", "hp": 0.5}], 1)
	hud.set_local_downed(true, 30.0)
	hud.set_revive(0.5, "reviver", "Jason")
	check(not coop.visible, "solo: setters don't show the co-op layer")
	hud.set_local_downed(false)
	hud.set_revive(-1.0)
	hud.set_party([], 1)

	# stub appears later: CoopHud binds itself on retry
	net = LAPI.create(root)
	net.auto_sim = false
	coop._process(0.6)
	check(coop.net == net, "CoopHud self-binds the Net/stub on retry")
	check(not coop.visible, "Net offline: still hidden")

	# ---------------------------------------------------------------- teammate list
	var jtint := Color(0.85, 0.3, 0.25)
	net.sim_match_party([{"peer_id": 2, "name": "Jason", "hp": 0.8, "tint": jtint}, {"peer_id": 3, "name": "Ash", "hp": 0.25}, {"peer_id": 4, "name": "Laurie", "state": "spectating"}])
	await frames(1)
	check(coop.visible and coop.networked(), "co-op match: HUD shown")
	check(coop.entries.size() == 3 and row(1) == null, "3 teammates listed, local player skipped")
	check(row_text(2, "MateName") == "JASON" and row_text(3, "MateName") == "ASH", "teammate names")
	check((row(2).find_child("Swatch", true, false) as ColorRect).color.is_equal_approx(jtint), "Jason swatch uses party tint")
	check((row(3).find_child("Swatch", true, false) as ColorRect).color.is_equal_approx(LAPI.slot_tints()[2]), "Ash swatch falls back to slot palette")
	var f2 := row(2).find_child("HpFill", true, false) as ColorRect
	check(absf(f2.size.x - (coop.MATE_BAR - 2.0) * 0.8) < 0.5, "Jason health bar 80%% (%.1f)" % f2.size.x)
	var f3 := row(3).find_child("HpFill", true, false) as ColorRect
	check(absf(f3.size.x - (coop.MATE_BAR - 2.0) * 0.25) < 0.5 and f3.color.is_equal_approx(UIStyle.BLOOD.lightened(0.2)), "Ash low health bar is blood-red")
	check(row_text(4, "MateState") == "SPECTATING" and (row(4).find_child("HpFill", true, false) as ColorRect).size.x == 0.0, "spectating tag, empty bar")
	net.sim_party_hp(2, 0.4)
	await frames(1)
	check(absf((row(2).find_child("HpFill", true, false) as ColorRect).size.x - (coop.MATE_BAR - 2.0) * 0.4) < 0.5, "party_changed hp update")
	# Netz cb5e52a teammate HP: teammate_health_changed(peer, hp, max_hp) ints, no party_changed
	net.sim_teammate_hp(2, 60, 100)
	await frames(1)
	check(absf((row(2).find_child("HpFill", true, false) as ColorRect).size.x - (coop.MATE_BAR - 2.0) * 0.6) < 0.5 and is_equal_approx(coop.hp_of(2), 0.6), "teammate_health_changed 60/100 → bar 60%")
	net.sim_teammate_hp(2, 20, 100)
	await frames(1)
	check((row(2).find_child("HpFill", true, false) as ColorRect).color.is_equal_approx(UIStyle.BLOOD.lightened(0.2)), "teammate HP under 30% → blood-red bar")
	check(is_equal_approx(LAPI.hp_fraction({"hp": 75, "max_hp": 150}), 0.5) and is_equal_approx(LAPI.hp_fraction({"hp": 0.3}), 0.3) and is_equal_approx(LAPI.hp_fraction({"hp": 1, "max_hp": 2, "hp_frac": 0.25}), 0.25), "hp_fraction: Netz hp_frac first, then ints, then stub fraction")
	net.sim_teammate_hp(2, 40, 100)
	await frames(1)
	check(coop.tint_for_name("jason") is Color and coop.tint_for_name("jason").is_equal_approx(jtint), "tint lookup by name")

	# teammate downed + bleed-out (Net.match_players.life_changed; bleed-out = net.json downed.bleed_out_s)
	check(LAPI.players_of(net) != null and LAPI.world_of(net) != null, "stub has match_players + world like Net")
	net.sim_downed(2, 30.0)
	await frames(1)
	check(str(row(2).get_meta("state")) == "downed" and row_text(2, "MateState") == "DOWNED", "life_changed downed → teammate DOWNED tag")
	check(row_text(2, "MateBleed") == "30", "teammate bleed-out seconds from downed.bleed_out_s")
	coop._process(1.2)
	check(row_text(2, "MateBleed") == "29", "teammate bleed-out counts down (%s)" % row_text(2, "MateBleed"))
	# revive bar: local player is the reviver (revive_changed active → bar fills over downed.revive_time_s)
	check(not coop.find_child("ReviveBar", true, false).visible, "no revive bar idle")
	net.cfg["downed.revive_time_s"] = 4.0
	net.sim_revive(2, 1, true)
	var rb = coop.find_child("ReviveBar", true, false)
	check(rb.visible and coop.revive_role == "reviver", "revive_changed(target, me, true) → reviver sees the bar")
	check(str(coop.find_child("ReviveLabel", true, false).text) == "REVIVING JASON", "reviver label")
	check(row_text(2, "MateState") == "REVIVING", "teammate row tag: REVIVING")
	coop._process(1.6)
	check(absf((coop.find_child("ReviveFill", true, false) as ColorRect).size.x - (coop.BAR_W - 4.0) * 0.4) < 0.5, "revive fill 40%% after 1.6 / 4 s")
	check(row_text(2, "MateBleed") == "29", "teammate bleed-out paused while being revived (%s)" % row_text(2, "MateBleed"))
	coop._process(2.0)
	check(absf((coop.find_child("ReviveFill", true, false) as ColorRect).size.x - (coop.BAR_W - 4.0) * 0.9) < 0.5, "revive fill 90%")
	net.sim_revive(2, 1, false)
	check(not rb.visible and coop.revive_active.is_empty(), "revive stopped (out of range / released) hides the bar")
	coop._process(1.0)
	check(row_text(2, "MateBleed") == "28", "bleed-out resumes after the revive stops (%s)" % row_text(2, "MateBleed"))
	net.sim_revive(2, 1, true)
	coop._process(1.0)
	net.sim_revive(2, 1, false)
	net.sim_revived(2)
	await frames(1)
	check(not rb.visible and str(row(2).get_meta("state")) == "alive" and row(2).find_child("MateBleed", true, false) == null, "revived (life alive): bar gone, teammate alive")
	net.sim_revive(2, 3, true)
	check(not rb.visible, "others reviving each other: no bar for me")
	net.sim_revive(2, 3, false)
	# bled out teammate
	net.sim_downed(3, 30.0)
	net.sim_dead(3)
	await frames(1)
	check(row_text(3, "MateState") == "BLED OUT" and row(3).find_child("MateBleed", true, false) == null
		and (row(3).find_child("HpFill", true, false) as ColorRect).size.x == 0.0, "life dead → BLED OUT, empty bar")
	net.sim_revived(3) # next round respawn
	await frames(1)
	check(str(row(3).get_meta("state")) == "alive", "respawn (life alive) clears BLED OUT")
	check(net.match_players.life_of(3) == "alive" and LAPI.life_of(net, 3) == "alive", "life_of through LobbyAPI")

	# Netz 9c4f1ec: late joiner spectates until the break; spectate banner follows NetPlayers.spectate_changed
	var lj: int = net.sim_late_join("Rook", true)
	await frames(1)
	check(row(lj) != null and str(row(lj).get_meta("state")) == "spectating" and row_text(lj, "MateState") == "JOINED LATE", "late joiner row: JOINED LATE tag, spectating state (%s)" % row_text(lj, "MateState"))
	check((row(lj).find_child("HpFill", true, false) as ColorRect).size.x == 0.0, "late joiner spectating: empty bar")
	check(coop.last_toast == "ROOK JOINED  //  SPECTATING UNTIL THE BREAK", "player_joined_late toast (%s)" % coop.last_toast)
	net.sim_late_respawn(lj)
	await frames(1)
	check(str(row(lj).get_meta("state")) == "alive" and row(lj).find_child("MateState", true, false) == null, "late joiner respawned at the break: alive row")
	check(LAPI.status_of({"state": "downed", "life": "downed"})[0] == "DOWNED" and LAPI.status_of({"state": "spectating", "life": "dead"})[0] == "BLED OUT  //  SPECTATING"
		and LAPI.status_of({"state": "lobby"})[0] == "", "status_of: downed / bled out / lobby")
	check(not coop.spectate_banner_visible(), "no spectate banner while playing")
	net.sim_dead(1)
	net.sim_spectate(2)
	await frames(1)
	check(coop.spectate_banner_visible() and coop.spectate_peer == 2 and coop.spectate_banner_text().begins_with("BLED OUT  //  SPECTATING  JASON"), "spectate_changed → banner names the watched teammate (%s)" % coop.spectate_banner_text())
	check(coop.spectate_banner_text().ends_with("SWITCH"), "banner shows the cycle keys")
	net.sim_spectate(3)
	check(coop.spectate_banner_text().contains("SPECTATING  ASH"), "cycling → banner follows (%s)" % coop.spectate_banner_text())
	net.sim_spectate(0)
	net.sim_revived(1)
	check(not coop.spectate_banner_visible(), "spectate off → banner hidden")
	net.sim_local_late(true)
	net.sim_spectate(2)
	check(coop.local_late and coop.spectate_banner_text().begins_with("JOINED LATE  //  SPECTATING  JASON") and coop.last_toast.begins_with("JOINED LATE"), "local late join: banner + toast")
	net.game_event.emit(&"player_respawned", 1, {"late_join": true})
	check(not coop.local_late and not coop.spectate_banner_visible(), "own player_respawned clears the late spectate banner")

	# local player downed: bleed-out timer + revive from the downed side
	var bo = coop.find_child("BleedOut", true, false)
	check(not bo.visible, "no bleed-out while alive")
	net.sim_downed(1, 25.0)
	check(bo.visible and coop.local_downed, "local downed: bleed-out shown")
	check(str(coop.find_child("BleedLabel", true, false).text) == "BLEEDING OUT  0:25", "bleed-out 0:25")
	coop._process(5.0)
	check(str(coop.find_child("BleedLabel", true, false).text) == "BLEEDING OUT  0:20", "bleed-out ticks to 0:20")
	check(absf((coop.find_child("BleedFill", true, false) as ColorRect).size.x - (coop.BAR_W - 4.0) * 0.8) < 0.5, "bleed bar drains (80%)")
	coop._process(11.0)
	check((coop.find_child("BleedLabel", true, false) as Label).get_theme_color("font_color").is_equal_approx(UIStyle.BAD), "under 10 s: bleed text turns red")
	net.sim_revive(1, 3, true)
	check(rb.visible and coop.revive_role == "downed" and str(coop.find_child("ReviveLabel", true, false).text) == "ASH IS REVIVING YOU", "downed sees who revives them")
	var bl0: float = coop.bleed_left
	coop._process(1.0)
	check(absf(coop.bleed_left - bl0) < 0.001, "own bleed-out paused while being revived")
	net.sim_revive(1, 3, false)
	net.sim_revived(1)
	check(not bo.visible and not rb.visible and not coop.local_downed, "local revived: bleed-out + bar hidden")
	net.sim_downed(1, 3.0)
	coop._process(10.0)
	check(coop.bleed_left == 0.0 and str(coop.find_child("BleedLabel", true, false).text) == "BLEEDING OUT  0:00", "timer stops at 0:00")
	net.sim_dead(1)
	check(bo.visible and coop.local_dead and str(coop.find_child("DownedTitle", true, false).text) == "BLED OUT"
		and str(coop.find_child("BleedLabel", true, false).text) == "BACK NEXT ROUND", "local bled out: BLED OUT // BACK NEXT ROUND")
	net.sim_revived(1)
	check(not bo.visible and not coop.local_dead and str(coop.find_child("DownedTitle", true, false).text) == "DOWNED", "respawned: overlay cleared")
	check(coop.format_bleed(65.2) == "BLEEDING OUT  1:06", "format m:ss")
	# all down → game over (main shows its screen): co-op overlays cleared
	net.sim_downed(1, 30.0)
	net.sim_revive(1, 2, true)
	net.sim_all_down()
	check(not bo.visible and not rb.visible and coop.all_down_seen, "all_down: bleed-out + revive bar cleared for the game over screen")
	net.sim_revived(1)
	coop.all_down_seen = false
	# revive prompt near a downed teammate (Net.match_players.avatars + the local player in group "player")
	var me := Node3D.new()
	me.add_to_group("player")
	root.add_child(me)
	var av := Node3D.new()
	root.add_child(av)
	av.global_position = Vector3(1.2, 0, 0)
	net.match_players.avatars[2] = av
	net.sim_downed(2, 30.0)
	coop._process(0.1)
	var pr := coop.find_child("RevivePrompt", true, false) as Label
	check(pr.visible and pr.text.begins_with("HOLD [") and pr.text.ends_with("] TO REVIVE JASON"), "revive prompt near a downed teammate: %s" % pr.text)
	av.global_position = Vector3(6, 0, 0)
	coop._process(0.1)
	check(not pr.visible, "out of downed.revive_range_m: no prompt")
	av.global_position = Vector3(1, 0, 0)
	net.sim_revive(2, 1, true)
	coop._process(0.1)
	check(not pr.visible, "prompt hides while I'm reviving")
	net.sim_revive(2, 1, false)
	net.sim_revived(2)
	net.match_players.avatars.erase(2)
	me.queue_free()
	av.queue_free()
	# teammate points in the party strip (Net.points_changed)
	net.sim_points(2, 1250)
	await frames(1)
	check(row_text(2, "MatePoints") == "1250", "points_changed(peer, total) → teammate points %s" % row_text(2, "MatePoints"))
	net.sim_points(1, 999)
	check(row(1) == null and row_text(2, "MatePoints") == "1250", "own points stay on the main HUD")
	# spend refused (Net.request_spend → world.spend_result)
	net.request_spend(5000, "wallbuy")
	check(coop.last_toast == "NOT ENOUGH POINTS  (5000)" and (coop.find_child("SpendToast", true, false) as Label).visible, "spend_result(false) → '%s'" % coop.last_toast)
	net.request_spend(100, "wallbuy")
	check(net.get_points(1) == 899, "spend ok: stub charges the ledger")
	coop._process(3.0)
	check(not (coop.find_child("SpendToast", true, false) as Label).visible, "toast fades")
	net.world.door_refused.emit("D3", "points")
	check(coop.last_toast == "NOT ENOUGH POINTS", "door_refused(points) toast")
	net.sim_round_state(4, "break", 0)
	check(coop.round_phase == "break", "round_state_changed tracked (%s)" % coop.round_phase)
	# Fallback route: the same flow through Net.game_event
	net.game_event.emit(&"player_downed", 3, {"bleed_out_s": 12.0})
	check(str(row(3).get_meta("state")) == "downed" and row_text(3, "MateBleed") == "12", "fallback game_event player_downed → teammate downed (bleed %s)" % row_text(3, "MateBleed"))
	net.game_event.emit(&"revive_progress", 3, {"reviver_peer": 1, "progress": 0.3})
	check(rb.visible and str(coop.find_child("ReviveLabel", true, false).text) == "REVIVING ASH", "fallback game_event revive_progress → reviver bar")
	net.game_event.emit(&"player_revived", 3, {})
	check(not rb.visible and row(3).find_child("MateBleed", true, false) == null, "fallback game_event player_revived → cleared")
	# a HUD built mid-match catches up on downed teammates from match_players.life
	net.sim_downed(4, 20.0)
	var hud3 = load("res://scripts/hud.gd").new()
	root.add_child(hud3)
	await frames(2)
	hud3.coop_hud._process(0.6)
	check(str(hud3.coop_hud.mate_row(4).get_meta("state")) == "downed", "late-bound HUD reads match_players.life (Laurie downed)")
	hud3.queue_free()
	net.sim_revived(4)
	await frames(1)
	# hud.set_party path (§6.5 shape) also works when networked
	hud.set_party([{"peer_id": 1, "name": "Me"}, {"peer_id": 9, "name": "Tommy", "hp": 1.0, "state": "disconnected"}], 1)
	check(row_text(9, "MateState") == "DISCONNECTED", "hud.set_party forwarder (disconnected tag)")
	net.sim_end_match()
	await frames(1)
	check(not coop.visible, "match over (leave_party): co-op HUD hidden again")
	var ign := true
	for c in hud.find_children("*", "Control", true, false):
		if (c as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			print("INFO  mouse-stopping HUD control: ", hud.get_path_to(c))
			ign = false
	check(ign, "all co-op / banner Controls ignore the mouse (input_test rule)")

	# ---------------------------------------------------------------- callout banner
	check(ban.visible and not ban.is_showing(), "banner idle, layer always present (solo too)")
	check(ban.label_for("massacre") == "MASSACRE" and ban.label_for("annihilation") == "ANNIHILATION", "labels from callouts.json ('!' trimmed)")
	check(ban.label_for("boss_kill") == "BIG ONE DOWN" and ban.label_for("streak_500") == "DEAD OF NIGHT", "sentence lines uppercased, '.' trimmed")
	check(ban.label_for("triple_tap") == "TRIPLE_TAP", "missing label → event_id uppercased")
	check(ban.text_for("massacre", "", true) == "MASSACRE", "local text: just the callout")
	check(ban.text_for("massacre", "Jason", false) == "JASON — MASSACRE", "teammate text: NAME — CALLOUT")
	check(ban.text_for("massacre", "Jason", true) == "MASSACRE", "local ignores the name")
	check(ban.text_for("massacre", "", false) == "MASSACRE", "teammate with no name → plain")
	# timing + stamp
	var stamp := ban.find_child("CalloutStamp", true, false) as Control
	ban.on_callout("massacre", "", true)
	check(ban.is_showing() and stamp.visible and ban.banner_text() == "MASSACRE", "callout → banner")
	ban.advance(0.02)
	check(ban.phase == "in" and stamp.scale.x > 1.3, "stamp-in scale punch (%.2f)" % stamp.scale.x)
	ban.advance(0.2)
	check(ban.phase == "hold" and absf(stamp.scale.x - 1.0) < 0.06 and absf(stamp.rotation_degrees - ban.ROT_DEG) < 0.01, "settles at 1.0 scale, slight rotation (%.1f°)" % stamp.rotation_degrees)
	check(stamp.modulate.a > 0.99, "fully opaque while held")
	var font = (ban.find_child("CalloutText", true, false) as RichTextLabel).get_theme_font("normal_font")
	check(font == UIStyle.FONT_STENCIL, "stencil font")
	ban.advance(1.5) # t = 1.72
	check(ban.phase == "hold", "still held at 1.7 s")
	ban.advance(0.15) # 1.87
	var y0: float = ban._base_y
	check(ban.phase == "out" and stamp.position.y < y0 and stamp.modulate.a < 1.0, "slides out after ~1.75 s")
	ban.advance(0.2) # 2.07
	check(not ban.is_showing() and not stamp.visible, "gone at ~2 s")
	# teammate tint
	coop.set_party([{"peer_id": 1, "name": "Me"}, {"peer_id": 2, "name": "Jason", "tint": jtint}], 1)
	ban.on_callout("massacre", "Jason", false)
	var rt := str((ban.find_child("CalloutText", true, false) as RichTextLabel).text)
	check(ban.banner_text() == "JASON — MASSACRE" and jtint.to_html(false) in rt, "teammate banner in their tint")
	ban.advance(2.1)
	ban.on_callout("massacre", "Freddy", false)
	check(not stamp.has_meta("tint"), "unknown teammate: no tint (bone)")
	ban.advance(2.1)
	# replace / queue / expiry / dedupe
	ban.shown_log.clear()
	ban.on_callout("massacre", "", true)
	ban.advance(0.5)
	ban.on_callout("slaughterhouse", "", true)
	check(ban.banner_text() == "SLAUGHTERHOUSE" and ban.queue.is_empty() and ban.t == 0.0, "higher priority replaces the banner now")
	ban.on_callout("massacre", "Jason", false)
	ban.on_callout("massacre", "", true)
	ban.on_callout("massacre", "Ash", false)
	check(ban.queue.size() == ban.QUEUE_MAX, "lower priority queues, capped at %d" % ban.QUEUE_MAX)
	ban.on_callout("slaughterhouse", "", true)
	check(ban.queue.size() == ban.QUEUE_MAX, "same line again doesn't stack")
	ban.advance(2.05)
	check(ban.banner_text() == "JASON — MASSACRE", "queued callout shows after the current one")
	ban.advance(2.05)
	check(not ban.is_showing(), "queued too long (>%.0f s) → dropped" % ban.MAX_WAIT)
	check(ban.shown_log == ["MASSACRE", "SLAUGHTERHOUSE", "JASON — MASSACRE"], "never more than one banner on screen (%s)" % str(ban.shown_log))
	check(ban.find_children("CalloutStamp", "", true, false).size() == 1, "single stamp node")

	# ---------------------------------------------------------------- Net.callout_received (teammates) + no double show
	ban.advance(3.0)
	ban.queue.clear()
	ban._process(1.1) # binds the stub's callout_received
	check(net.is_connected("callout_received", ban.on_net_callout), "banner binds Net.callout_received")
	net.sim_match_party([{"peer_id": 2, "name": "Jason"}])
	ban.shown_log.clear()
	net.sim_callout("massacre", 2) # no /root/Callouts here: only the Net path fires
	check(ban.banner_text() == "JASON — MASSACRE", "teammate callout via Net.callout_received → banner")
	ban.on_callout("massacre", "Jason", false) # the same line through Callouts.callout_played
	check(ban.shown_log == ["JASON — MASSACRE"] and ban.queue.is_empty() and ban.deduped == 1, "same line from Callouts too → shown once (%s)" % [ban.shown_log])
	ban.advance(2.1)
	ban.on_net_callout("massacre", "Me", true)
	check(not ban.is_showing(), "local callout from Net ignored (Callouts shows local lines)")
	ban.on_callout("slaughterhouse", "Jason", false) # Callouts first, Net second
	ban.on_net_callout("slaughterhouse", "Jason", false)
	check(ban.shown_log.count("JASON — SLAUGHTERHOUSE") == 1 and ban.deduped == 2, "either order: one banner")
	ban.advance(2.1)
	ban.on_net_callout("massacre", "Jason", false)
	ban.advance(ban.DEDUP_S + 0.5)
	ban.on_callout("massacre", "Jason", false)
	check(ban.shown_log.count("JASON — MASSACRE") == 3, "a later repeat (> DEDUP_S) shows again")
	ban.advance(2.1)
	net.sim_end_match()

	# ---------------------------------------------------------------- real Callouts node → banner (defensive bind)
	var cp = load("res://scripts/audio/callout_player.gd").new()
	cp.name = "Callouts"
	root.add_child(cp)
	await frames(1)
	cp.manual_time = 100.0
	ban._process(1.1)
	check(cp.callout_played.is_connected(ban.on_callout), "banner binds /root/Callouts once it exists")
	ban.shown_log.clear()
	var played: bool = cp.announce("annihilation", "", true)
	check(played and ban.banner_text() == "ANNIHILATION", "Callouts.announce → callout_played → banner")
	ban.advance(2.1)
	cp.manual_time = 200.0
	cp.tick()
	cp.announce("massacre", "Jason", false)
	check(ban.banner_text() == "JASON — MASSACRE", "teammate announce → NAME — CALLOUT banner")
	ban.advance(2.1)
	net.sim_match_party([{"peer_id": 2, "name": "Jason"}])
	ban.shown_log.clear()
	cp.manual_time = 300.0
	cp.tick()
	net.sim_callout("annihilation", 2) # Net path: callout_received + real Callouts.announce → callout_played
	check(ban.shown_log == ["JASON — ANNIHILATION"], "Net + real Callouts both fire: banner shows once (%s)" % [ban.shown_log])
	ban.advance(2.1)
	net.sim_end_match()
	var hud2 = load("res://scripts/hud.gd").new()
	root.add_child(hud2)
	await frames(2)
	check(cp.callout_played.is_connected(hud2.callout_banner.on_callout), "HUD created after Callouts binds in _ready")
	hud2.queue_free()
	root.remove_child(cp)
	cp.queue_free()
	await frames(2)
	ban._process(1.1)
	ban.on_callout("massacre")
	check(ban.is_showing(), "Callouts freed: banner still safe")
	if real_cp:
		real_cp.name = "Callouts"
		ban._process(1.1)
		check(real_cp.callout_played.is_connected(ban.on_callout), "banner re-binds when Callouts comes back")

	print("coop_hud_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
