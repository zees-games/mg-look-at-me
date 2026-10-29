extends RefCounted

## Where this game's own files are, wherever this copy of it lives.
## A delivered pack mounts under `res://dot_cloud/<id>/<version>/`, so absolute `res://` references to its own files
## must be rebased; anything holding one is a `static var`, not a `const` (docs/design.md, "Pack paths").

## This game's content root: `res://` built in, the mount prefix delivered.
static func root() -> String:
	# new().get_script(), not a self-preload: a script holding itself is never freed at exit.
	var here: Resource = new().get_script()
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one `res://` path onto [method root]. Anything else comes back untouched, and format
## specifiers survive: only the prefix is replaced.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered, so the mounted case can be tested
## from a build: built in, every property that matters only in a pack is a tautology.
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

	# Idempotent: the publisher rewrites `res://` inside scenes and resources but not inside scripts, so a
	# path may already carry the mount prefix, and rebasing it twice doubles it (docs/design.md, "Pack paths").
	# Built in, [param here] is `res://` and this returns its argument unchanged.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
