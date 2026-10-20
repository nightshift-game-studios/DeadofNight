extends Node
## Autoload "SaveMigration" (first in [autoload], so it runs before Progress/Settings load anything).
## The game was renamed "FPS Starter" -> "DeadofNight" -> "Gravecrew" (application/config/name). Each rename moves user://
## (.../app_userdata/<name>/). On first launch under a new name, if the new dir has none of SAVE_FILES yet, every older
## sibling dir that holds a save is copied forward, newest first (the dir whose save files were modified last wins;
## ties keep OLD_DIR_NAMES order), and an older dir only fills in files the newer one didn't have. Nothing that already
## exists in the new dir is ever overwritten, and once progress.cfg or settings.cfg exists there it does nothing.
## The old dirs are left untouched as backups.

const OLD_DIR_NAMES := ["DeadofNight", "FPS Starter"] ## most recent name first
const SAVE_FILES := ["progress.cfg", "settings.cfg"]

var migrated_from: String = "" ## newest old dir copied from this launch ("" = nothing to do)
var migrated_dirs: Array = [] ## every old dir that contributed at least one file, in copy order
var files_copied: int = 0


func _init() -> void:
	# _init runs when the autoload is instantiated, before any autoload's _ready.
	var dst := OS.get_user_data_dir()
	var srcs: Array = []
	for old_name in OLD_DIR_NAMES:
		srcs.append(dst.get_base_dir().path_join(old_name))
	var r := migrate_all(srcs, dst)
	files_copied = int(r.copied)
	migrated_dirs = r.dirs
	if not migrated_dirs.is_empty():
		migrated_from = str(migrated_dirs[0])
		print("SaveMigration: copied %d file(s) from %s" % [files_copied, ", ".join(migrated_dirs)])


## Copies every old dir in `srcs` that holds a save into `dst`, newest first, when `dst` has none of SAVE_FILES.
## Returns {copied: int, dirs: [src, ...]} (dirs = the ones that contributed a file, in copy order). Never overwrites.
static func migrate_all(srcs: Array, dst: String) -> Dictionary:
	var out := {"copied": 0, "dirs": []}
	if dst.is_empty() or _has_save(dst):
		return out
	var cands: Array = []
	for i in srcs.size():
		var src := str(srcs[i])
		if src != dst and DirAccess.dir_exists_absolute(src) and _has_save(src):
			cands.append({"src": src, "t": newest_save_time(src), "i": i})
	cands.sort_custom(func(a, b): return a.t > b.t if a.t != b.t else a.i < b.i)
	for c in cands:
		var n := _copy_tree(str(c.src), dst)
		if n > 0:
			out.copied += n
			out.dirs.append(str(c.src))
	return out


## Latest modification time (unix s) of the SAVE_FILES in `dir`, 0 if none.
static func newest_save_time(dir: String) -> int:
	var t := 0
	for f in SAVE_FILES:
		var p := dir.path_join(f)
		if FileAccess.file_exists(p):
			t = maxi(t, int(FileAccess.get_modified_time(p)))
	return t


static func _has_save(dir: String) -> bool:
	for f in SAVE_FILES:
		if FileAccess.file_exists(dir.path_join(f)):
			return true
	return false


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
