class_name BossCommon
extends RefCounted
## Shared helpers for boss scripts that extend enemy.gd (Skillz).

const CATALOG := preload("res://scripts/enemies/boss_catalog.gd")
const TELEGRAPH := preload("res://scripts/enemies/boss_telegraph.gd")
const ART := preload("res://scripts/enemies/boss_art.gd")


## Apply catalog mults after the wave spawner called setup(). Call before add_child.
## Boss rework: HP comes only from the TTK model (BossCatalog.boss_hp; `players` / `boss_count` = co-op party + bosses this round).
static func apply_identity(enemy: Node, boss_id: String, round_n: int, difficulty_id: String = "", players: int = 1, boss_count: int = -1) -> void:
	var b: Dictionary = CATALOG.get_boss(boss_id)
	if b.is_empty():
		return
	enemy.set_meta("boss_id", boss_id)
	enemy.set_meta("boss_round", round_n)
	enemy.set_meta("is_boss", true)
	enemy.set("variant_id", "boss:" + boss_id)
	enemy.set("max_health", CATALOG.boss_hp(boss_id, round_n, 0, 0, difficulty_id, players, boss_count))
	enemy.set("speed", float(enemy.get("speed")) * float(b.get("speed_mult", 1.0)))
	enemy.set("contact_damage", maxi(int(round(float(enemy.get("contact_damage")) * float(b.get("damage_mult", 1.0)))), 1))
	if b.has("model_height"):
		enemy.set("model_height", float(b.get("model_height")))
	if b.has("size_variety"):
		enemy.set("size_variety", float(b.get("size_variety")))
	# Desi's boss GLB (model_height already matches the rest AABB, so the auto-scale is 1.0).
	ART.set_model(enemy, str(b.get("model", "")))


static func kill_payout(enemy: Node, points_per_kill: int = 50) -> Dictionary:
	var id := str(enemy.get_meta("boss_id", ""))
	if id == "":
		return {"points": points_per_kill, "gravemark": 0}
	return {
		"points": CATALOG.kill_points(id, points_per_kill),
		"gravemark": CATALOG.gravemark_reward(id),
	}


static func flat_dir_to(from: Vector3, to: Vector3) -> Vector3:
	var d := to - from
	d.y = 0.0
	return d.normalized() if d.length() > 0.001 else Vector3.FORWARD
