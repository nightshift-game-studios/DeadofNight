extends RefCounted
## Merchant API: thin factory + the one place for every merchant name the UI uses (Gooey).
##
##   var api = preload("res://scripts/ui/merchant_api.gd").create()
##
## create() returns Skillz's real Merchant once it exists (the /root/Merchant autoload, or a new instance of
## REAL_SCRIPT), else this script's own STUB. Contract: /workspace/skillz/MERCHANT_API.md (the names below match it).
## merchant_menu.gd only calls through M.call_api(api, "<key>", [...]) and M.sig(...), so renaming a real method
## or signal is a one-line change in METHODS / SIGNALS. The call list is in MERCHANT_API_STUB.md.
##
## The stub: 5 rolled weapon offers (preview WeaponItems), hourly refresh aligned to the top of the hour,
## a reroll cost that rises per use and resets on refresh, buys that spend Gravemarks (Progress) and drop the gun
## in the stash (Progress.bound_inventory(), or `inventory`), refusing at the stash cap.

const REAL_SCRIPT := "res://scripts/merchant/merchant.gd"
const REAL_AUTOLOAD := "/root/Merchant"

## UI key -> method name on the API object.
const METHODS := {
	"get_stock": "get_stock",
	"buy": "buy",
	"buy_check": "buy_check",
	"reroll": "reroll",
	"reroll_cost": "reroll_cost",
	"reroll_check": "reroll_check",
	"time_to_refresh": "time_to_refresh",
	"refresh_if_due": "refresh_if_due",
	"last_refusal_reason": "last_refusal_reason",
}
## UI key -> signal name on the API object.
const SIGNALS := {
	"stock_changed": "stock_changed", # (reason: "refresh" | "reroll" | "buy" | "load")
	"purchased": "purchased", # (offer_id: String, item: WeaponItem, price: int)
	"refreshed": "refreshed", # ()
	"reroll_cost_changed": "reroll_cost_changed", # (new_cost: int)
}
## Offer dictionary keys the UI reads.
const K_OFFER_ID := "offer_id"
const K_SLOT := "slot"
const K_ITEM := "item"
const K_ARCHETYPE := "archetype"
const K_RARITY := "rarity"
const K_ITEM_POWER := "item_power"
const K_PERKS := "perks"
const K_PRICE := "price"
const K_SOLD := "sold"
const K_OWNED := "owned"
const K_CAN_AFFORD := "can_afford"
const K_REASON := "reason"
## Refusal texts (stub; the real Merchant sends its own, the UI shows whatever comes back).
const R_SOLD := "Sold out"
const R_FUNDS := "Not enough Gravemarks (need %d)"
const R_STASH := "Stash full (%d/%d)"
const R_EXPIRED := "Stock expired"
const R_SLOT_FULL := "No backpack room for that weapon type"
const R_UNAVAILABLE := "The Gravecrew merchant is away" ## Skillz's text: no data / Progress / GearDB

## Test hook: true -> create() / is_real_available() ignore the real Merchant and hand out this stub.
static var force_stub: bool = false


# ================================================================== factory + call helpers

static func create() -> Object:
	if force_stub:
		return load("res://scripts/ui/merchant_api.gd").new()
	var ml := Engine.get_main_loop() as SceneTree
	if ml and ml.root.has_node(NodePath(REAL_AUTOLOAD.substr(6))):
		return ml.root.get_node(NodePath(REAL_AUTOLOAD.substr(6)))
	if ResourceLoader.exists(REAL_SCRIPT):
		var s = load(REAL_SCRIPT)
		if s and s.can_instantiate():
			return s.new()
	return load("res://scripts/ui/merchant_api.gd").new()


## Is Skillz's real script in this project (and not masked by force_stub)?
static func is_real_available() -> bool:
	return not force_stub and ResourceLoader.exists(REAL_SCRIPT)


## Point the API's grant target at `inv` (real Merchant.inventory and the stub share the field name).
static func set_api_inventory(api: Object, inv: Node) -> void:
	if api != null and "inventory" in api:
		api.set("inventory", inv)


static func is_stub(api: Object) -> bool:
	return api != null and api.get_script() == load("res://scripts/ui/merchant_api.gd")


static func call_api(api: Object, key: String, args: Array = []):
	var m: String = METHODS.get(key, key)
	if api == null or not api.has_method(m):
		return null
	return api.callv(m, args)


static func sig(api: Object, key: String, cb: Callable) -> void:
	var s: String = SIGNALS.get(key, key)
	if api and api.has_signal(s) and not api.is_connected(s, cb):
		api.connect(s, cb)


static func unsig(api: Object, key: String, cb: Callable) -> void:
	var s: String = SIGNALS.get(key, key)
	if api and api.has_signal(s) and api.is_connected(s, cb):
		api.disconnect(s, cb)


## {ok, reason} from either a dict result or a bare bool.
static func as_check(r) -> Dictionary:
	if r is Dictionary:
		return {"ok": bool(r.get("ok", false)), "reason": str(r.get("reason", ""))}
	return {"ok": bool(r), "reason": ""}


# ================================================================== STUB implementation

signal stock_changed(reason: String)
signal purchased(offer_id: String, item: Object, price: int)
signal refreshed
signal reroll_cost_changed(new_cost: int)

## Stub tuning (the real Merchant reads data/merchant.json).
var stock_size: int = 5 ## 4..6
var prices := [40, 70, 120, 220, 380] ## Gravemarks by rarity (common..mythic)
var reroll_base: int = 15
var reroll_step: int = 10 ## cost = base + step * rerolls_this_hour
var archetypes := ["sidearm", "hand_cannon", "auto_rifle", "scout_rifle", "smg", "shotgun", "pulse_rifle", "sniper_rifle"]
var inventory: Node ## grant target; null -> Progress.bound_inventory()
var now_offset: float = 0.0 ## tests: shift the clock (seconds)
var available: bool = true ## tests: false -> behave like the real Merchant with no data (empty stock, R_UNAVAILABLE)

var _stock: Array = []
var _gen: int = 0
var _rerolls: int = 0
var _hour: int = -1
var _last_refusal: String = ""
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 1337
	_hour = _hour_index()
	_roll_all()


func _now() -> float:
	return Time.get_unix_time_from_system() + now_offset


func _hour_index() -> int:
	return int(floor(_now() / 3600.0))


func _progress() -> Node:
	var ml := Engine.get_main_loop() as SceneTree
	return ml.root.get_node_or_null("Progress") if ml else null


func _gear_db() -> Node:
	var ml := Engine.get_main_loop() as SceneTree
	return ml.root.get_node_or_null("GearDB") if ml else null


func _inv() -> Node:
	if inventory and is_instance_valid(inventory):
		return inventory
	var p := _progress()
	return p.bound_inventory() if p and p.has_method("bound_inventory") else null


func _balance() -> int:
	var p := _progress()
	return int(p.gravemark_balance()) if p and p.has_method("gravemark_balance") else 0


func _roll_offer(slot: int) -> Dictionary:
	var gdb := _gear_db()
	var r := _rng.randi_range(1, 4) if slot > 0 else _rng.randi_range(2, 4) # slot 0 is always Rare+
	if _rng.randf() < 0.12:
		r = 4
	var arch: String = archetypes[_rng.randi_range(0, archetypes.size() - 1)]
	var w = gdb.roll_weapon(arch, r, 10) if gdb else null
	if w:
		w.seen = false
	return {K_OFFER_ID: "m%d_%d" % [_gen, slot], K_SLOT: slot, K_ITEM: w, "item_id": (w.item_id if w else ""),
		K_ARCHETYPE: arch, K_RARITY: r, K_ITEM_POWER: (w.item_power if w else 0),
		K_PERKS: (Array(w.perks) if w else []), K_PRICE: int(prices[clampi(r, 0, prices.size() - 1)]), K_SOLD: false}


func _roll_all() -> void:
	_gen += 1
	_stock.clear()
	for i in clampi(stock_size, 4, 6):
		_stock.append(_roll_offer(i))


func _find(offer_id: String) -> Dictionary:
	for o in _stock:
		if str(o[K_OFFER_ID]) == offer_id:
			return o
	return {}


func _owns(o: Dictionary) -> bool:
	var inv := _inv()
	var w = o.get(K_ITEM)
	if inv == null or w == null:
		return false
	var all: Array = []
	for s in inv.equipped:
		if inv.equipped[s]:
			all.append(inv.equipped[s])
	for s in inv.backpack:
		all.append_array(inv.backpack[s])
	for g in all:
		if g == w or (str(g.item_id) != "" and str(g.item_id) == str(w.item_id)): # item_id only (MERCHANT_API.md)
			return true
	return false


func _decorate(o: Dictionary) -> Dictionary:
	var d := o.duplicate()
	d[K_OWNED] = _owns(o)
	var c := buy_check(str(o[K_OFFER_ID]))
	d[K_CAN_AFFORD] = _balance() >= int(o[K_PRICE])
	d[K_REASON] = "" if c.ok else c.reason
	return d


func get_stock() -> Array:
	if not available:
		return []
	var out: Array = []
	for o in _stock:
		out.append(_decorate(o))
	return out


func buy_check(offer_id: String) -> Dictionary:
	if not available:
		return {"ok": false, "reason": R_UNAVAILABLE}
	var o := _find(offer_id)
	if o.is_empty():
		return {"ok": false, "reason": R_EXPIRED}
	if bool(o[K_SOLD]):
		return {"ok": false, "reason": R_SOLD}
	var price := int(o[K_PRICE])
	if _balance() < price:
		return {"ok": false, "reason": R_FUNDS % price}
	var inv := _inv()
	var w = o[K_ITEM]
	if inv and w and inv.equipped.get(w.slot) != null:
		if inv.has_method("stash_full") and inv.stash_full():
			return {"ok": false, "reason": R_STASH % [inv.carried_count(), inv.stash_cap]}
		if inv.backpack[w.slot].size() >= inv.backpack_size:
			return {"ok": false, "reason": R_SLOT_FULL}
	return {"ok": true, "reason": ""}


func buy(offer_id: String) -> Dictionary:
	var c := buy_check(offer_id)
	if not c.ok:
		_last_refusal = c.reason
		return {"ok": false, "reason": c.reason, "item": null}
	var o := _find(offer_id)
	var price := int(o[K_PRICE])
	var p := _progress()
	if p == null or not p.spend_gravemark(price):
		_last_refusal = R_FUNDS % price
		return {"ok": false, "reason": _last_refusal, "item": null}
	var w = o[K_ITEM]
	var inv := _inv()
	if inv and w:
		w.seen = false
		if not inv.add_item(w):
			p.add_gravemark(price, "merchant_refund")
			_last_refusal = R_STASH % [inv.carried_count(), inv.stash_cap]
			return {"ok": false, "reason": _last_refusal, "item": null}
		if p.has_method("save_stash"):
			p.save_stash()
	o[K_SOLD] = true
	_last_refusal = ""
	purchased.emit(offer_id, w, price)
	stock_changed.emit("buy")
	return {"ok": true, "reason": "", "item": w}


func reroll_cost() -> int:
	return reroll_base + reroll_step * _rerolls


func reroll_check() -> Dictionary:
	if not available:
		return {"ok": false, "reason": R_UNAVAILABLE}
	var c := reroll_cost()
	if _balance() < c:
		return {"ok": false, "reason": R_FUNDS % c}
	return {"ok": true, "reason": ""}


func reroll() -> Dictionary:
	var c := reroll_check()
	if not c.ok:
		_last_refusal = c.reason
		return c
	var p := _progress()
	if p == null or not p.spend_gravemark(reroll_cost()):
		_last_refusal = R_FUNDS % reroll_cost()
		return {"ok": false, "reason": _last_refusal}
	_rerolls += 1
	_gen += 1
	for i in _stock.size():
		if not bool(_stock[i][K_SOLD]):
			_stock[i] = _roll_offer(i)
	_last_refusal = ""
	reroll_cost_changed.emit(reroll_cost())
	stock_changed.emit("reroll")
	return {"ok": true, "reason": ""}


func time_to_refresh() -> int:
	var t := _now()
	return maxi(int(ceil((floor(t / 3600.0) + 1.0) * 3600.0 - t)), 0)


func refresh_if_due() -> bool:
	var h := _hour_index()
	if h <= _hour: # clock rollback never refreshes early
		return false
	_hour = h
	_rerolls = 0
	_roll_all()
	refreshed.emit()
	stock_changed.emit("refresh")
	reroll_cost_changed.emit(reroll_cost())
	return true


func last_refusal_reason() -> String:
	return _last_refusal
