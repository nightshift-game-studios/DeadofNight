extends SkillEffect
## Marker: this node unlocks a Field Card group. Gating itself is data-driven on the card side
## (run_picks.json "requires_meta"); this effect only answers which cards it opens.
## params: branch, tier.


func cards() -> Array:
	var rs = runner.get_node_or_null("/root/RunState") if runner else null
	var out := []
	if rs == null:
		return out
	for id in rs.card_ids():
		var c: Dictionary = rs.card_def(id)
		if c.get("branch", "") == params.get("branch", "") and c.get("tier", "") == params.get("tier", "") \
				and source_id in c.get("requires_meta", []):
			out.append(id)
	return out
