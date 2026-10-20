extends Node
## Autoload "RunState": this match's Field Cards (run picks) and the offer flow. Never saved.
##
## Flow (driven by main.gd): round n cleared -> after offer_delay main calls open_offer(n) and pauses
## the tree -> a chooser UI (Gooey's run_pick_menu.gd, or the TEMP chooser) listens to offer_ready
## and calls choose(id) / reroll() / skip() / banish(id) -> offer_closed -> main unpauses and starts
## the round break. Everything works headless (no UI needed), see tests/skills_checks.gd.
##
## Offers: normal rounds draw `size` normal cards (Lucky Find: each slot may roll legendary);
## milestone rounds (n % milestone_every == 0) draw milestone_legendary legendaries + normals
## (Gilded Ledger: all legendary). Empty pools yield the Supply Cache card (+cache_points_per_round x n).
## Reroll cost = base x n x growth^k (k = paid rerolls on this offer; milestone base 100), free rerolls
## (Spare Coin) first. Skip = +skip_points_per_round x n. Banish (Black Ledger): N per match, 1 per offer.
##
## Time scale: request_time_scale(id, scale, dur) stacks requests (lowest wins) and restores 1.0 when
## they expire, on clear() and at game over. Only used when time_scale_allowed()
## (ProjectSettings "skills/allow_time_scale", default false).

signal offer_ready(cards: Array, is_milestone: bool) ## cards: Array of offer entry dicts (see offer_entry)
signal offer_closed(result: String, card_id: String) ## result: "chosen" | "skipped"
signal card_picked(card_id: String, new_rank: int)
signal cards_changed
signal rerolled(cost: int, free: bool)
signal reroll_refused(reason: String) ## NET M13: co-op paid reroll refused by the host / timed out (not charged)
signal banished(card_id: String)

const PICKS_PATH := "res://data/run_picks.json"
const CACHE_ID := "cache"
const TIME_SCALE_SETTING := "skills/allow_time_scale"

var data: Dictionary = {}
var _defs: Dictionary = {} ## id -> card dict
var _order: Array = []

var player ## set by main.gd each match (points, SkillRunner, class)
var cards: Dictionary = {} ## card id -> rank
var banished_ids: Dictionary = {}
var free_rerolls: int = 0
var banishes_left: int = 0
var offer: Array = [] ## current offer card ids ("" = none open)
var offer_round: int = 0
var offer_is_milestone: bool = false
var offer_open: bool = false
var rerolls_paid_this_offer: int = 0
var reroll_pending: bool = false ## NET M13: a co-op paid reroll is waiting for the host's answer
var last_refusal_reason: String = "" ## NET M13: "" or why the last co-op reroll wasn't charged ("points", "timeout", "offer_closed")
var _reroll_req: int = 0 ## NET M13: id of the co-op reroll in flight; clear() / open_offer() bump it so a stale answer is ignored
var banished_this_offer: int = 0
var picks_log: Array = [] ## [[round, id, rank]]
var rng := RandomNumberGenerator.new()

var _ts_requests: Dictionary = {} ## id -> {scale, left (real seconds, -1 = until released)}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # API usable while the offer pauses the tree
	rng.randomize()
	if not ProjectSettings.has_setting(TIME_SCALE_SETTING):
		ProjectSettings.set_setting(TIME_SCALE_SETTING, false)
	load_data()


func load_data() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(PICKS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Could not parse %s" % PICKS_PATH)
		return
	data = parsed
	_defs.clear()
	_order.clear()
	for c in data.get("cards", []):
		_defs[c.id] = c
		_order.append(c.id)
	var cc: Dictionary = data.get("cache_card", {"id": CACHE_ID, "name": "Supply Cache", "tier": "normal"})
	_defs[CACHE_ID] = cc


func cfg(key: String, default = null):
	return data.get("offer", {}).get(key, default)


func card_def(id: String) -> Dictionary:
	return _defs.get(id, {})


func card_ids() -> Array:
	return _order.duplicate()


func card_rank(id: String) -> int:
	return int(cards.get(id, 0))


func _class() -> String:
	var prog := get_node_or_null("/root/Progress")
	return str(prog.selected_class) if prog else "soldier"


func card_class_ok(id: String) -> bool:
	var c: String = str(card_def(id).get("class", ""))
	return c == "" or c == _class()


## Meta gate: every requires_meta node owned (rank >= 1).
func card_unlocked(id: String) -> bool:
	var prog := get_node_or_null("/root/Progress")
	for req in card_def(id).get("requires_meta", []):
		if prog == null or prog.rank(req) <= 0:
			return false
	return true


func _mod(stat: String, base: float) -> float:
	if player and is_instance_valid(player) and player.get("skill_runner"):
		return player.skill_runner.modify(stat, base, {})
	return base


func time_scale_allowed() -> bool:
	return bool(ProjectSettings.get_setting(TIME_SCALE_SETTING, false))


# ---------------------------------------------------------------- match lifecycle

## New match (main._ready) / game over: wipe cards, refill free rerolls + banishes, reset time scale.
func clear() -> void:
	cards.clear()
	banished_ids.clear()
	picks_log.clear()
	offer.clear()
	offer_open = false
	rerolls_paid_this_offer = 0
	reroll_pending = false # NET M13
	last_refusal_reason = ""
	_reroll_req += 1
	banished_this_offer = 0
	clear_time_scale()
	refresh_allowances()
	cards_changed.emit()


## Free rerolls and banishes come from the meta tree (Spare Coin, Black Ledger).
func refresh_allowances() -> void:
	free_rerolls = int(_mod("offer_free_rerolls", 0.0))
	banishes_left = int(_mod("offer_banishes", 0.0))


func is_milestone(round_number: int) -> bool:
	var every := int(cfg("milestone_every", 5))
	return round_number > 0 and every > 0 and round_number % every == 0


func offer_size() -> int:
	return int(_mod("offer_size", float(cfg("size", 3))))


# ---------------------------------------------------------------- pools and weights

func eligible(id: String) -> bool:
	var c := card_def(id)
	if c.is_empty() or id == CACHE_ID or banished_ids.has(id):
		return false
	if not card_class_ok(id) or not card_unlocked(id):
		return false
	return card_rank(id) < int(c.get("ranks", 1))


func pool(tier: String) -> Array:
	return _order.filter(func(id): return card_def(id).get("tier", "normal") == tier and eligible(id))


func _synergy(branch: String) -> bool:
	var prog := get_node_or_null("/root/Progress")
	if prog == null:
		return false
	for id in prog.skill_ranks:
		var n: Dictionary = prog.get_skill(id)
		if n.get("branch", "") == branch and str(n.get("choice_group", "")) != "":
			return true
	return false


func weight(id: String) -> float:
	var c := card_def(id)
	var w := float(c.get("weight", 10))
	if card_rank(id) > 0:
		w *= float(cfg("owned_weight_mult", 1.5))
	var b := str(c.get("branch", ""))
	if _synergy(b):
		w *= float(cfg("synergy_weight_mult", 1.5))
	return _mod("offer_weight:" + b, w)


func _draw(tier: String, exclude: Array) -> String:
	var ids: Array = pool(tier).filter(func(i): return not (i in exclude))
	var total := 0.0
	for i in ids:
		total += weight(i)
	if ids.is_empty() or total <= 0.0:
		return CACHE_ID
	var r := rng.randf() * total
	for i in ids:
		r -= weight(i)
		if r <= 0.0:
			return i
	return ids[ids.size() - 1]


## Card ids for round n (no state change). Milestones: N legendary first, then normal.
func roll_offer(round_number: int) -> Array:
	var size := offer_size()
	var ms := is_milestone(round_number)
	var tiers := []
	if ms:
		var n_leg: int = size if _mod("offer_milestone_all_legendary", 0.0) > 0.0 else mini(int(cfg("milestone_legendary", 2)), size)
		for i in size:
			tiers.append("legendary" if i < n_leg else "normal")
	else:
		var lucky := _mod("offer_lucky_slot_chance", 0.0)
		for i in size:
			tiers.append("legendary" if lucky > 0.0 and rng.randf() < lucky else "normal")
	var out := []
	for t in tiers:
		var id := _draw(t, out)
		if id == CACHE_ID and t == "legendary":
			id = _draw("normal", out) # legendary pool dry: fall back to a normal card, then cache
		out.append(id)
	return out


## One offer entry for the UI.
func offer_entry(id: String) -> Dictionary:
	var c := card_def(id)
	var now_r := card_rank(id)
	var next_r := mini(now_r + 1, int(c.get("ranks", 1)))
	var desc: String = Progress.format_description(c, next_r) if id != CACHE_ID else "+%d points." % cache_points()
	var syn := []
	var b := str(c.get("branch", ""))
	if _synergy(b):
		syn.append("%s choice/keystone owned" % b.capitalize())
	if now_r > 0:
		syn.append("owned: rank up")
	return {"id": id, "name": c.get("name", id), "tier": c.get("tier", "normal"), "branch": b,
		"type": c.get("type", "passive"), "icon": c.get("icon", id), "ranks": int(c.get("ranks", 1)),
		"rank_now": now_r, "rank_next": next_r, "summary": str(c.get("summary", "")), "description": desc,
		"drawback": Progress.format_drawback(c, next_r) if str(c.get("drawback", "")) != "" else "",
		"class": c.get("class", ""), "synergy": syn, "is_cache": id == CACHE_ID}


func offer_entries() -> Array:
	return offer.map(func(i): return offer_entry(i))


# ---------------------------------------------------------------- offer API

## Rolls and opens the offer for round n; emits offer_ready(entries, is_milestone).
func open_offer(round_number: int) -> Array:
	offer_round = round_number
	offer_is_milestone = is_milestone(round_number)
	rerolls_paid_this_offer = 0
	reroll_pending = false # NET M13
	last_refusal_reason = ""
	_reroll_req += 1
	banished_this_offer = 0
	offer = roll_offer(round_number)
	offer_open = true
	var entries := offer_entries()
	offer_ready.emit(entries, offer_is_milestone)
	return entries


## DESIGN §6.2 name.
func make_offer(round_number: int) -> Array:
	return open_offer(round_number)


static func reroll_cost_for(round_number: int, paid_rerolls: int, milestone: bool, base := 50, base_ms := 100, growth := 2.0) -> int:
	return int(round((base_ms if milestone else base) * maxi(round_number, 1) * pow(growth, paid_rerolls)))


## Points the next reroll costs (0 while free rerolls are left).
func reroll_cost() -> int:
	if free_rerolls > 0:
		return 0
	return reroll_cost_for(offer_round, rerolls_paid_this_offer, offer_is_milestone,
		int(cfg("reroll_base", 50)), int(cfg("reroll_base_milestone", 100)), float(cfg("reroll_growth", 2.0)))


func can_reroll() -> bool:
	return offer_open and not reroll_pending and (free_rerolls > 0 or (player != null and player.points >= reroll_cost()))


## Spends a free reroll or points (player.spend_points) and redraws the whole offer.
func reroll() -> bool:
	if not offer_open or reroll_pending:
		return false
	var free := free_rerolls > 0
	var cost := reroll_cost()
	if not free and NetGate.is_networked(): # NET M13: co-op paid reroll is charged by the host (solo: unchanged below)
		return _net_reroll(cost)
	if free:
		free_rerolls -= 1
	elif player == null or not player.spend_points(cost):
		return false
	else:
		rerolls_paid_this_offer += 1
	offer = roll_offer(offer_round)
	rerolled.emit(cost, free)
	offer_ready.emit(offer_entries(), offer_is_milestone)
	return true


## NET M13: the host charges `cost` (spend_with_callback); the offer redraws on its "yes". Refused / no answer within
## net.json spend.timeout_s -> not charged, last_refusal_reason + reroll_refused. A "yes" for an offer that closed
## meanwhile is refunded. Returns true only if it already rerolled (host player); a client gets false + reroll_pending.
func _net_reroll(cost: int) -> bool:
	_reroll_req += 1
	var req := _reroll_req
	reroll_pending = true
	last_refusal_reason = ""
	NetGate.spend_with_callback(cost, "reroll", func(ok: bool, why: String) -> bool:
		if req != _reroll_req:
			return false # answer for an offer that was closed / reset meanwhile: a "yes" is refunded, state untouched
		reroll_pending = false
		if ok and not offer_open:
			ok = false
			why = "offer_closed"
		if not ok:
			last_refusal_reason = why
			reroll_refused.emit(why)
			return false
		rerolls_paid_this_offer += 1
		offer = roll_offer(offer_round)
		rerolled.emit(cost, false)
		offer_ready.emit(offer_entries(), offer_is_milestone)
		return true)
	return not reroll_pending and last_refusal_reason == ""


func skip_reward() -> int:
	return int(cfg("skip_points_per_round", 50)) * maxi(offer_round, 1)


func cache_points() -> int:
	return int(cfg("cache_points_per_round", 50)) * maxi(offer_round, 1)


## Takes no card, pays skip_reward() points, closes the offer.
func skip() -> int:
	if not offer_open:
		return 0
	var pts := skip_reward()
	if player:
		player.add_points(pts)
	_close("skipped", "")
	return pts


func can_banish(id: String) -> bool:
	return offer_open and id in offer and id != CACHE_ID and banishes_left > 0 \
		and banished_this_offer < int(cfg("max_banish_per_offer", 1))


## Removes `id` from this match's pools and redraws that slot (same tier).
func banish(id: String) -> bool:
	if not can_banish(id):
		return false
	banishes_left -= 1
	banished_this_offer += 1
	banished_ids[id] = true
	var slot := offer.find(id)
	var tier: String = card_def(id).get("tier", "normal")
	var others := offer.duplicate()
	others.remove_at(slot)
	var nid := _draw(tier, others)
	if nid == CACHE_ID and tier == "legendary":
		nid = _draw("normal", others)
	offer[slot] = nid
	banished.emit(id)
	offer_ready.emit(offer_entries(), offer_is_milestone)
	return true


## Takes card `id` from the open offer: rank +1, effects live immediately (SkillRunner.add_card +
## player.recalc_stats, never apply_stats), then GameEvents "card_picked". Closes the offer.
func choose(id: String) -> bool:
	if not offer_open or not (id in offer):
		return false
	if id == CACHE_ID:
		if player:
			player.add_points(cache_points())
		picks_log.append([offer_round, id, 0])
		_close("chosen", id)
		return true
	add_card(id)
	_close("chosen", id)
	return true


## Pick alias (DESIGN §7.1 name).
func pick(id: String) -> bool:
	return choose(id)


## Grants a card outside an offer (tests, debug, future events).
func add_card(id: String) -> int:
	var c := card_def(id)
	if c.is_empty():
		return 0
	cards[id] = mini(card_rank(id) + 1, int(c.get("ranks", 1)))
	picks_log.append([offer_round, id, cards[id]])
	if player and is_instance_valid(player) and player.get("skill_runner"):
		player.skill_runner.add_card(id)
		player.recalc_stats()
	card_picked.emit(id, cards[id])
	cards_changed.emit()
	var bus := get_node_or_null("/root/GameEvents")
	if bus:
		bus.emit_event(&"card_picked", {"player": player, "card_id": id, "rank": cards[id]})
	return cards[id]


func _close(result: String, id: String) -> void:
	offer_open = false
	offer_closed.emit(result, id)


## For the HUD strip / character screen: [{id, name, tier, branch, icon, rank, ranks, description}].
func owned_cards() -> Array:
	var out := []
	for id in cards:
		var c := card_def(id)
		out.append({"id": id, "name": c.get("name", id), "tier": c.get("tier", "normal"), "branch": c.get("branch", ""),
			"icon": c.get("icon", id), "rank": cards[id], "ranks": int(c.get("ranks", 1)),
			"description": Progress.format_description(c, cards[id])})
	return out


# ---------------------------------------------------------------- time scale (flagged)

func request_time_scale(id: String, scale: float, duration: float = -1.0) -> void:
	if not time_scale_allowed():
		return
	_ts_requests[id] = {"scale": clampf(scale, 0.05, 1.0), "left": duration}
	_apply_time_scale()


func release_time_scale(id: String) -> void:
	_ts_requests.erase(id)
	_apply_time_scale()


func clear_time_scale() -> void:
	_ts_requests.clear()
	Engine.time_scale = 1.0


func _apply_time_scale() -> void:
	var s := 1.0
	for k in _ts_requests:
		s = minf(s, float(_ts_requests[k].scale))
	Engine.time_scale = s


## Advances timed requests by real (unscaled) seconds. Called from _process; tests call it directly.
func tick_time_scale(real_delta: float) -> void:
	if _ts_requests.is_empty():
		return
	for k in _ts_requests.keys():
		var r: Dictionary = _ts_requests[k]
		if float(r.left) >= 0.0:
			r.left = float(r.left) - real_delta
			if float(r.left) <= 0.0:
				_ts_requests.erase(k)
	_apply_time_scale()


func _process(delta: float) -> void:
	if get_tree().paused:
		return
	tick_time_scale(delta / maxf(Engine.time_scale, 0.01))
