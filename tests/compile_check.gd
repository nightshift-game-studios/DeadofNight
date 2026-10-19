extends SceneTree
## Loads every script under res://scripts and res://tests and reports parse/compile failures.
## godot --headless --path . -s res://tests/compile_check.gd   (exit code = failures)

func _initialize() -> void:
	var bad := 0
	var files := []
	_walk("res://scripts", files)
	_walk("res://tests", files)
	for f in files:
		var s = load(f)
		if s == null or (s is GDScript and not s.can_instantiate() and not f.ends_with("compile_check.gd")):
			print("COMPILE FAIL ", f)
			bad += 1
	print("compile_check: %d scripts, %d failed" % [files.size(), bad])
	quit(bad)


func _walk(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_walk(dir + "/" + d, out)
