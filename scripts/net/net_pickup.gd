class_name NetPickup
extends Pickup
## Shared co-op world drop (Netz): looks and prompts like a normal Pickup, but grabbing asks the host; the first
## request wins, the host grants the item to that player only and removes the drop on every machine.

var drop_id := ""
var _asked := false


func interact(player: Node) -> void:
	_request(player)


func _on_body_entered(body: Node) -> void:
	var cons := item as ConsumableItem
	if cons and cons.auto_use and body.has_method("receive_item"):
		_request(body)
		return
	if body.has_method("set_nearby_interactable"):
		body.set_nearby_interactable(self, true)


func _request(player: Node) -> void:
	if _asked or not player.is_in_group("player"):
		return
	var w := get_node_or_null("/root/Net/World")
	if w:
		_asked = true
		w.request_grab(drop_id)


## Host refused (someone else was first, or our inventory was full): allow another try.
func release() -> void:
	_asked = false
