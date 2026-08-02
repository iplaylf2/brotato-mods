extends SceneTree


func _init() -> void:
	var archive_path := _get_archive_path()
	if archive_path.empty() or not ProjectSettings.load_resource_pack(archive_path, false):
		printerr("Could not mount the mod validation archive: %s" % archive_path)
		quit(1)
		return

	var script_paths := []
	_collect_scripts("res://mods-unpacked", script_paths)
	var failed := false
	for script_path in script_paths:
		var script: Script = ResourceLoader.load(script_path, "GDScript", true)
		if script == null or not script.can_instance():
			printerr("Godot could not compile: %s" % script_path)
			failed = true
	quit(1 if failed else 0)


func _get_archive_path() -> String:
	for argument in OS.get_cmdline_args():
		if argument.ends_with(".zip"):
			return argument
	return ""


func _collect_scripts(directory_path: String, script_paths: Array) -> void:
	var directory := Directory.new()
	if directory.open(directory_path) != OK:
		return

	directory.list_dir_begin(true, true)
	var entry := directory.get_next()
	while entry != "":
		var path := directory_path.plus_file(entry)
		if directory.current_is_dir():
			_collect_scripts(path, script_paths)
		elif entry.ends_with(".gd"):
			script_paths.push_back(path)
		entry = directory.get_next()
	directory.list_dir_end()
