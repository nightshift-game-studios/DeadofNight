extends SceneTree
## Save-dir migration after the "FPS Starter" -> "DeadofNight" -> "Gravecrew" renames (SaveMigration autoload).
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
	var new := root.path_join("Gravecrew")
	DirAccess.make_dir_recursive_absolute(old.path_join("sub"))
	_write(old.path_join("progress.cfg"), "[meta]\nsave_version=3\n")
	_write(old.path_join("settings.cfg"), "[audio]\nmaster=0.5\n")
	_write(old.path_join("sub/extra.txt"), "x")

	check(ProjectSettings.get_setting("application/config/name") == "Gravecrew", "project name is Gravecrew")
	check(OS.get_user_data_dir().ends_with("Gravecrew"), "user:// dir is .../Gravecrew")
	check(MigrationScript.OLD_DIR_NAMES == ["DeadofNight", "FPS Starter"], "migrates from DeadofNight and FPS Starter (most recent name first)")
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

	# ---- Gravecrew rename: both older dirs, newest first, never overwrite
	var b := root.path_join("both")
	var don := b.path_join("DeadofNight")
	var fps := b.path_join("FPS Starter")
	var gc := b.path_join("Gravecrew")
	DirAccess.make_dir_recursive_absolute(don)
	DirAccess.make_dir_recursive_absolute(fps.path_join("sub"))
	_write(don.path_join("progress.cfg"), "[meta]\nfrom=deadofnight\n")
	_write(don.path_join("stash.cfg"), "don-stash")
	_write(fps.path_join("progress.cfg"), "[meta]\nfrom=fps\n")
	_write(fps.path_join("settings.cfg"), "[audio]\nfrom=fps\n")
	_write(fps.path_join("sub/keys.cfg"), "k")
	var r: Dictionary = MigrationScript.migrate_all([don, fps], gc)
	check(r.copied == 4 and r.dirs == [don, fps], "both old dirs copied, DeadofNight first on a tie (%s)" % [r])
	check(FileAccess.get_file_as_string(gc.path_join("progress.cfg")).contains("deadofnight"), "progress.cfg comes from the newest dir (DeadofNight), not overwritten by FPS Starter")
	check(FileAccess.get_file_as_string(gc.path_join("settings.cfg")).contains("from=fps"), "settings.cfg missing in DeadofNight -> filled in from FPS Starter")
	check(FileAccess.file_exists(gc.path_join("stash.cfg")) and FileAccess.file_exists(gc.path_join("sub/keys.cfg")), "other files and subfolders carried over from both")
	check(FileAccess.file_exists(don.path_join("progress.cfg")) and FileAccess.file_exists(fps.path_join("progress.cfg")), "old dirs left intact")
	_write(don.path_join("progress.cfg"), "[meta]\nfrom=changed\n")
	var r2: Dictionary = MigrationScript.migrate_all([don, fps], gc)
	check(r2.copied == 0 and r2.dirs.is_empty() and not FileAccess.get_file_as_string(gc.path_join("progress.cfg")).contains("changed"),
		"existing Gravecrew save: second run copies nothing, never overwrites")
	# Only the oldest dir has a save -> it still comes forward
	var gc2 := b.path_join("Gravecrew2")
	var r3: Dictionary = MigrationScript.migrate_all([b.path_join("missing"), fps], gc2)
	check(r3.copied == 3 and r3.dirs == [fps] and FileAccess.get_file_as_string(gc2.path_join("progress.cfg")).contains("from=fps"), "FPS Starter only (skipped DeadofNight) -> copied")
	# Newest by modification time wins over list order (Linux/macOS: back-date DeadofNight with touch)
	if OS.get_name() in ["Linux", "macOS"]:
		var gc3 := b.path_join("Gravecrew3")
		OS.execute("touch", ["-d", "2020-01-01 00:00:00", ProjectSettings.globalize_path(don.path_join("progress.cfg"))])
		check(MigrationScript.newest_save_time(fps) > MigrationScript.newest_save_time(don), "back-dated DeadofNight is older than FPS Starter")
		var r4: Dictionary = MigrationScript.migrate_all([don, fps], gc3)
		check(r4.dirs == [fps, don] and FileAccess.get_file_as_string(gc3.path_join("progress.cfg")).contains("from=fps"),
			"newer FPS Starter save copies first when DeadofNight is older (%s)" % [r4.dirs])
	check(MigrationScript.migrate_all([], root.path_join("Fresh3")).copied == 0, "no old dirs -> nothing")

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
