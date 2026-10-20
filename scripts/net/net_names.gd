class_name NetNames
extends RefCounted
## The one player-name validator (Net.sanitize_name / Net.is_valid_name / Net.validate_name delegate here).
## Same rules as Gooey's Settings.validate_player_name: trim, collapse runs of spaces, 2..16 characters,
## only letters / numbers / spaces / _ - . (so no $, <, [, \ ...), and at least one letter or number.
## Static + class_name so Settings (an earlier autoload) can call NetNames.validate() too.

const NAME_MIN := 2
const NAME_MAX := 16
const ALLOWED_TEXT := "letters, numbers, spaces and _ - ."
const _ALLOWED := "^[A-Za-z0-9 _.\\-]+$"


## Trim + collapse double spaces (what both validators compare).
static func normalize(raw: String) -> String:
	var n := raw.strip_edges()
	while n.contains("  "):
		n = n.replace("  ", " ")
	return n


## {ok, name (normalized), reason (player-facing, "" when ok)}; same shape and wording as Settings.validate_player_name.
static func validate(raw: String) -> Dictionary:
	var n := normalize(raw)
	if n.length() < NAME_MIN:
		return {"ok": false, "name": n, "reason": "Name needs at least %d characters." % NAME_MIN}
	if n.length() > NAME_MAX:
		return {"ok": false, "name": n, "reason": "Name can be at most %d characters." % NAME_MAX}
	if RegEx.create_from_string(_ALLOWED).search(n) == null:
		return {"ok": false, "name": n, "reason": "Use only %s" % ALLOWED_TEXT}
	if RegEx.create_from_string("[A-Za-z0-9]").search(n) == null:
		return {"ok": false, "name": n, "reason": "Name needs a letter or a number."}
	return {"ok": true, "name": n, "reason": ""}


static func is_valid(raw: String) -> bool:
	return bool(validate(raw).ok)


## Best-effort repair for names from the wire / old profiles: drop disallowed characters, normalize, cut to NAME_MAX.
## "" if nothing valid is left (callers pick a fallback).
static func sanitize(raw: String) -> String:
	var out := ""
	var re := RegEx.create_from_string(_ALLOWED)
	for ch in raw:
		if re.search(ch) != null:
			out += ch
	out = normalize(out).substr(0, NAME_MAX).strip_edges()
	return out if is_valid(out) else ""
