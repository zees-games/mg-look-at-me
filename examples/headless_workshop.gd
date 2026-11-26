extends GSGameCheckSuite

const LmGame := preload("res://game/lm_game.gd")
const LmVote := preload("res://game/lm_vote.gd")

## Workshop houses: a subscribed pack's house is listed (M menu, ballot) and played in solo, not offered online;
## a map kind the game does not accept is left out and a pack document that is not a house of that id is refused.
## Fixture: a solo pack on disk under user://, registered in gs-core's content index as the Workshop sync does.

const ROOT := "user://lm_ws_fixture/"
const CHECKS := 21

var _entered := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("look at me workshop")
	await _test()
	_report_sections(_entered, _finished, 1, CHECKS)


func _write_house(dir: String, doc_id: String, with_level: bool) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT + dir)
	var meta := FileAccess.open(ROOT + dir + "/house.json", FileAccess.WRITE)
	meta.store_string(JSON.stringify({"kind": "house", "id": doc_id, "name": "Fixture %s" % doc_id}))
	meta.close()

	if with_level:
		var level := FileAccess.get_file_as_string("res://levels/lm_01.json")
		var file := FileAccess.open(ROOT + dir + "/ws_01.json", FileAccess.WRITE)
		file.store_string(level)
		file.close()


## A house whose level is the Asylum's with its converted world copied beside it, the way a map pack ships one.
func _write_world_house(dir: String) -> void:
	var from := "res://houses/asylum/"
	var pack := "world/gm_blackbrook_asylum/"
	DirAccess.make_dir_recursive_absolute(ROOT + dir + "/" + pack)
	var meta := FileAccess.open(ROOT + dir + "/house.json", FileAccess.WRITE)
	meta.store_string(JSON.stringify({"kind": "house", "id": dir, "name": "Fixture World"}))
	meta.close()

	for file: String in ["gm_blackbrook_asylum.bin", "gm_blackbrook_asylum.json"]:
		var copy := FileAccess.open(ROOT + dir + "/" + pack + file, FileAccess.WRITE)
		copy.store_buffer(FileAccess.get_file_as_bytes(from + pack + file))
		copy.close()

	var level: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(from + "asylum_01.json"))
	level["world"]["path"] = "houses/%s/%sgm_blackbrook_asylum" % [dir, pack]
	var file := FileAccess.open(ROOT + dir + "/ws_01.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(level))
	file.close()


func _add_fixture_pack() -> GSContentIndex:
	var index := GSContentIndex.shared()
	index.set_session(GSContentIndex.SESSION_SOLO)
	var kind := "lookatme"
	var added := index.add_pack({
		"content_id": "tester/ws-houses", "version": "1.0.0", "prefix": ROOT,
		"session": "solo", "source": "subscription",
		"provides": {"title": "Workshop Test", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "ws_cellar", "name": "Fixture Cellar", "scene": "ws_cellar/house.json", "map_kind": kind},
			{"kind": "map", "id": "ws_surf", "name": "Fixture Surf", "scene": "ws_surf/house.json", "map_kind": "surf"},
			{"kind": "map", "id": "ws_world", "name": "Fixture World", "scene": "ws_world/house.json", "map_kind": kind},
			{"kind": "map", "id": "ws_bad", "name": "Fixture Bad", "scene": "ws_bad/house.json", "map_kind": kind},
		]},
	})
	_check(added.ok and (added.value as Array).size() == 4, "the fixture pack is in the index")
	_check(LmGame.accepted_map_kinds() == PackedStringArray([kind]), "provides.json accepts the kind lookatme")
	return index


func _test() -> void:
	_entered += 1
	_write_house("ws_cellar", "ws_cellar", true)
	_write_house("ws_surf", "ws_surf", true)
	_write_house("ws_bad", "somebody_else", true)
	_write_world_house("ws_world")

	var index := _add_fixture_pack()

	var game := LmGame.new()
	game.draws = false
	game.self_tick = false
	game.register_service = false
	game.config.winners_file = "user://test_lm_ws_winners.json"
	add_child(game)
	await get_tree().physics_frame

	var vote := LmVote.new()
	vote.maps_fn = game.listed_houses
	add_child(vote)
	_check(vote.setup().ok, "the vote is built")

	var rows := {}

	for row: Dictionary in game.house_rows():
		rows[str(row["id"])] = str(row["name"])

	_check(rows.get("ws_cellar", "") == "Fixture Cellar [Workshop Test]", "solo: the M menu lists the pack house as Name [Pack]", str(rows.get("ws_cellar")))
	_check(not rows.has("ws_surf"), "solo: a kind the game does not accept is not listed")
	_check(not rows.has("ws_bad"), "solo: a document whose id is not the entry's is refused")
	_check(rows.has("house") and rows.has("asylum"), "solo: the game's own houses are still there")

	var labels := {}
	vote.source.before_ballot()

	for choice in vote.source.choices():
		labels[String(choice.id)] = choice.label()

	_check(labels.has("ws_cellar") and labels["ws_cellar"] == "Fixture Cellar [Workshop Test]", "solo: the ballot offers it with its pack", str(labels.get("ws_cellar")))
	_check(not labels.has("ws_surf") and not labels.has("ws_bad"), "solo: the ballot leaves out the unaccepted kind and the bad document")
	_check(labels.has("house"), "solo: the game's own house is on the ballot")

	var changed := game.change_house(&"ws_cellar")
	_check(changed.ok, "solo: the pack house can be chosen", "" if changed.ok else changed.error.message)
	_check(game.house_id == &"ws_cellar" and game.levels.size() == 1, "solo: the chosen pack house is the one built", "%s, %d levels" % [game.house_id, game.levels.size()])
	_check(not game.change_house(&"ws_bad").ok, "solo: the refused house cannot be chosen")

	var walled := game.change_house(&"ws_world")
	_check(walled.ok, "solo: a pack house with a converted world can be chosen", "" if walled.ok else walled.error.message)
	var level: Node = game.levels.get(1)
	_check(level != null and level.get_node_or_null("World") != null, "solo: its world mesh is read from beside the pack's document")

	var back := game.change_house(&"house")
	_check(back.ok and game.levels.size() == 32, "solo: the game's own house still plays after it")

	index.set_session(GSContentIndex.SESSION_ONLINE)
	var online := {}

	for row: Dictionary in game.house_rows():
		online[str(row["id"])] = true

	_check(not online.has("ws_cellar"), "online: the menu does not list the solo house")
	vote.source.before_ballot()
	_check(not vote.source.choices().any(func(c: GSVoteChoice) -> bool: return c.id == &"ws_cellar"), "online: the ballot does not offer it")
	_check(not game.change_house(&"ws_cellar").ok, "online: the solo house cannot be chosen")
	_check(online.has("house"), "online: the game's own house is still offered")

	index.set_session(GSContentIndex.SESSION_SOLO)
	_check(game.house_rows().any(func(r: Dictionary) -> bool: return r["id"] == "ws_cellar"), "back in solo: the pack house returns")

	remove_child(vote)
	vote.free()
	remove_child(game)
	game.free()
	_finished += 1
