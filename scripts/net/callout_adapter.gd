class_name NetCalloutAdapter
extends RefCounted
## Thin seam to Audi-0's host-side scripts/audio/callout_driver.gd (one KillTracker per peer; detection is theirs).
## Net only reports facts on the host: kill(peer, headshot, boss), damage(peer), remove_peer(peer).
## The driver then calls Net.broadcast_callout(event_id, peer_id). Any object with on_kill / on_damage /
## remove_peer works (tests bind a fake). With no driver bound, calls are dropped (returns []).

var driver: Object = null


func bind(d: Object) -> void:
	driver = d


func is_bound() -> bool:
	return driver != null and is_instance_valid(driver)


func kill(peer_id: int, is_headshot: bool = false, is_boss: bool = false) -> Array:
	if is_bound() and driver.has_method("on_kill"):
		var r = driver.on_kill(peer_id, is_headshot, is_boss)
		return r if r is Array else []
	return []


func damage(peer_id: int) -> void:
	if is_bound() and driver.has_method("on_damage"):
		driver.on_damage(peer_id)


func remove_peer(peer_id: int) -> void:
	if is_bound() and driver.has_method("remove_peer"):
		driver.remove_peer(peer_id)
