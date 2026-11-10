extends DotGameNetchaosClient

## Look At Me's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosClient). No fire action: the game has nothing to shoot.


func _configure() -> void:
	client_scene = "res://game/lm.tscn"


func _roster() -> Array:
	var game = _client.get("game") if _client != null else null
	return game.players.values() if game != null else []
