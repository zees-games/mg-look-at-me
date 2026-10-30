extends RefCounted

const LmGame := preload("res://game/lm_game.gd")
const LmProgress := preload("res://game/lm_progress.gd")

## Stats are filed under dot-game's stable key; `game.players` and awards stay on `uid:...`.

class _Platform extends RefCounted:
	func key() -> String:
		return "plat-9001"


class _Identity extends RefCounted:
	var uid := "acct-9001"
	var is_guest := false
	var claims: Dictionary = {}


## Failure descriptions, empty when the split holds.
static func run(game: LmGame, progress: LmProgress) -> Array[String]:
	var bad: Array[String] = []
	var session := DotClientSession.new()
	session.userid = 9001
	session.identity = _Identity.new()
	session.data["platform"] = _Platform.new()
	var key := &"uid:acct-9001"
	var _player := game.join(key, "Keyed")
	progress.note_session(key, session)
	progress.record(key, LmProgress.CATCHES)
	if progress.stats.has_player(key) or not progress.stats.has_player(&"plat-9001"):
		bad.append("the stats session is not under the stable key")
	if progress.session_values(key).get_value(LmProgress.CATCHES) != 1.0:
		bad.append("the reading did not land")
	if progress.relay.record_of.get(&"plat-9001", &"") != key:
		bad.append("the relay does not map the stats key to the world key")
	game.leave(key)
	if progress.stats.has_player(&"plat-9001") or progress.relay.record_of.has(&"plat-9001"):
		bad.append("leave left the stats session behind")
	return bad
