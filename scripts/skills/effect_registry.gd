class_name EffectRegistry
## Maps the "script" id used in data/skill_tree.json and data/run_picks.json to an effect script
## in scripts/skills/effects/. To add an effect: write effects/<id>.gd (extends SkillEffect) and add it here.

const SCRIPTS := {
	"stat_mod": preload("res://scripts/skills/effects/stat_mod.gd"),
	"conditional_damage": preload("res://scripts/skills/effects/conditional_damage.gd"),
	"stacking_damage": preload("res://scripts/skills/effects/stacking_damage.gd"),
	"force_precision": preload("res://scripts/skills/effects/force_precision.gd"),
	"refill_mag": preload("res://scripts/skills/effects/refill_mag.gd"),
	"refund_grenade": preload("res://scripts/skills/effects/refund_grenade.gd"),
	"heal": preload("res://scripts/skills/effects/heal.gd"),
	"grant_overshield": preload("res://scripts/skills/effects/grant_overshield.gd"),
	"damage_in_mod": preload("res://scripts/skills/effects/damage_in_mod.gd"),
	"cheat_death": preload("res://scripts/skills/effects/cheat_death.gd"),
	"reflect_damage": preload("res://scripts/skills/effects/reflect_damage.gd"),
	"slowmo_trigger": preload("res://scripts/skills/effects/slowmo_trigger.gd"),
	"on_event_explode": preload("res://scripts/skills/effects/on_event_explode.gd"),
	"on_event_ray": preload("res://scripts/skills/effects/on_event_ray.gd"),
	"element_arc": preload("res://scripts/skills/effects/element_arc.gd"),
	"element_dot": preload("res://scripts/skills/effects/element_dot.gd"),
	"element_debuff": preload("res://scripts/skills/effects/element_debuff.gd"),
	"apply_status": preload("res://scripts/skills/effects/apply_status.gd"),
	"drop_pickup": preload("res://scripts/skills/effects/drop_pickup.gd"),
	"ability_mod": preload("res://scripts/skills/effects/ability_mod.gd"),
	"ability_refund": preload("res://scripts/skills/effects/ability_refund.gd"),
	"grenade_mod": preload("res://scripts/skills/effects/grenade_mod.gd"),
	"slide_mod": preload("res://scripts/skills/effects/slide_mod.gd"),
	"trail_hazard": preload("res://scripts/skills/effects/trail_hazard.gd"),
	"shot_counter": preload("res://scripts/skills/effects/shot_counter.gd"),
	"cooldown_reset": preload("res://scripts/skills/effects/cooldown_reset.gd"),
	"unlock_cards": preload("res://scripts/skills/effects/unlock_cards.gd"),
	"offer_weight": preload("res://scripts/skills/effects/offer_weight.gd"),
	"offer_mod": preload("res://scripts/skills/effects/offer_mod.gd"),
	# playtest #13 Field Card types
	"card_instant": preload("res://scripts/skills/effects/card_instant.gd"),
	"card_echo": preload("res://scripts/skills/effects/card_echo.gd"),
	"round_growth": preload("res://scripts/skills/effects/round_growth.gd"),
	"card_fleeting": preload("res://scripts/skills/effects/card_fleeting.gd"),
	"round_interest": preload("res://scripts/skills/effects/round_interest.gd"),
	"kill_counter": preload("res://scripts/skills/effects/kill_counter.gd"),
	"timed_buff": preload("res://scripts/skills/effects/timed_buff.gd"),
}


static func make(def: Dictionary, rank: int, source_id: String, kind: String) -> SkillEffect:
	var id := str(def.get("script", ""))
	if not SCRIPTS.has(id):
		push_warning("EffectRegistry: unknown effect script '%s' (%s)" % [id, source_id])
		return null
	var e: SkillEffect = SCRIPTS[id].new()
	e.setup(def, rank, source_id, kind)
	return e
