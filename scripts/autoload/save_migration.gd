extends Node
## Autoload "SaveMigration" (first in [autoload], so it runs before Progress/Settings load anything).
## The game was renamed "FPS Starter" -> "DeadofNight" (application/config/name), which moves user://
## from .../app_userdata/FPS Starter/ to .../app_userdata/DeadofNight/. On first launch after the rename,
## if the new dir has no save/settings yet and the old sibling dir exists, copy the old files over
## (progress, stash and settings carry across). One-time: it never overwrites, and once progress.cfg or
## settings.cfg exists in the new dir it does nothing. The old dir is left untouched as a backup.

const OLD_DIR_NAMES := ["FPS Starter"]
const SAVE_FILES := ["progress.cfg", "settings.cfg"]

var migrated_from: String = "" ## old dir copied from this launch ("" = nothing to do)
var files_copied: int = 0


func _init() -> void:
	# _init runs when the autoload is instantiated, before any autoload's _ready.
	var dst := OS.get_user_data_dir()
	for old_name in OLD_DIR_NAMES:
		var src := dst.get_base_dir().path_join(old_name)
		if src == dst:
			continue
		var n := migrate(src, dst)
		if n > 0:
			migrated_from = src
			files_copied = n
			print("SaveMigration: copied %d file(s) from %s" % [n, src])
			break


## Copies everything under `src` into `dst` when `dst` has none of SAVE_FILES and `src` exists.
## Returns the number of files copied (0 = skipped). Never overwrites a file that exists in `dst`.
static func migrate(src: String, dst: String) -> int:
	if src.is_empty() or dst.is_empty() or not DirAccess.dir_exists_absolute(src):
		return 0
	for f in SAVE_FILES:
		if FileAccess.file_exists(dst.path_join(f)):
			return 0
	var has_any := false
	for f in SAVE_FILES:
		if FileAccess.file_exists(src.path_join(f)):
			has_any = true
	if not has_any:
		return 0
	return _copy_tree(src, dst)


static func _copy_tree(src: String, dst: String) -> int:
	DirAccess.make_dir_recursive_absolute(dst)
	var n := 0
	for f in DirAccess.get_files_at(src):
		var to := dst.path_join(f)
		if FileAccess.file_exists(to):
			continue
		if DirAccess.copy_absolute(src.path_join(f), to) == OK:
			n += 1
	for d in DirAccess.get_directories_at(src):
		n += _copy_tree(src.path_join(d), dst.path_join(d))
	return n
