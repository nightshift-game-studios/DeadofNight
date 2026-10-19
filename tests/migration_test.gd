extends SceneTree
## Save-dir migration after the "FPS Starter" -> "DeadofNight" rename (SaveMigration autoload).
##   godot --headless --path . -s res://tests/migration_test.gd   (exit code = failures)
## Works in a scratch dir under user://, never touches the real saves.

const MigrationScript := preload("res://scripts/autoload/save_migration.gd")

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	var root := OS.get_user_data_dir().path_join("_migration_test")
	_rm(root)
	var old := root.path_join("FPS Starter")
	var new := root.path_join("DeadofNight")
	DirAccess.make_dir_recursive_absolute(old.path_join("sub"))
	_write(old.path_join("progress.cfg"), "[meta]\nsave_version=3\n")
	_write(old.path_join("settings.cfg"), "[audio]\nmaster=0.5\n")
	_write(old.path_join("sub/extra.txt"), "x")

	check(ProjectSettings.get_setting("application/config/name") == "DeadofNight", "project name is DeadofNight")
	check(OS.get_user_data_dir().ends_with("DeadofNight"), "user:// dir is .../DeadofNight")
	check(Engine.get_main_loop().root.get_node_or_null("SaveMigration") != null, "SaveMigration autoload present")
	var keys := []
	for p in ProjectSettings.get_property_list():
		if str(p.name).begins_with("autoload/"):
			keys.append(str(p.name))
	check(keys.size() > 0 and keys[0] == "autoload/SaveMigration", "SaveMigration is the first autoload")

	check(MigrationScript.migrate(root.path_join("nope"), new) == 0, "missing old dir -> nothing copied")
	var n := MigrationScript.migrate(old, new)
	check(n == 3, "fresh new dir -> 3 files copied (got %d)" % n)
	check(FileAccess.get_file_as_string(new.path_join("progress.cfg")).contains("save_version=3"), "progress.cfg content carried over")
	check(FileAccess.file_exists(new.path_join("settings.cfg")), "settings.cfg carried over")
	check(FileAccess.file_exists(new.path_join("sub/extra.txt")), "subfolders carried over")
	check(FileAccess.file_exists(old.path_join("progress.cfg")), "old dir left intact")

	_write(old.path_join("progress.cfg"), "[meta]\nsave_version=99\n")
	check(MigrationScript.migrate(old, new) == 0, "second run is a no-op once saves exist")
	check(not FileAccess.get_file_as_string(new.path_join("progress.cfg")).contains("99"), "never overwrites new saves")

	var empty_old := root.path_join("EmptyOld")
	DirAccess.make_dir_recursive_absolute(empty_old)
	_write(empty_old.path_join("junk.txt"), "j")
	check(MigrationScript.migrate(empty_old, root.path_join("Fresh2")) == 0, "old dir without saves -> skipped")

	_rm(root)
	print("MIGRATION TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _rm(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_rm(path.path_join(d))
	DirAccess.remove_absolute(path)
