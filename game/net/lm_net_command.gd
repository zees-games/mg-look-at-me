extends GSNetInput

## One tick of a player's input: the movement command, nothing else. Using and the flashlight
## are requests (reliable, rare); only what is predicted travels here.

var move: GSFpsCommand = GSFpsCommand.new()


func _write(writer: GSNetWriter) -> void:
	move.write(writer)


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)


func _sanitise() -> void:
	move.sanitise()


func _equals(other: GSNetInput) -> bool:
	return other != null and other.get("move") != null and move.equals(other.get("move"))
