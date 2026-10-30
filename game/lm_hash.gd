extends RefCounted

## A number in [0, 1) from text, the same on every machine: what furniture, rolls and anything every client must agree on is placed from.
## Not hash(): Godot's string hash is djb2, whose low bits barely change for strings that differ only at the end.
## MD5's first 32 bits mix properly and are identical everywhere.
static func unit(text: String) -> float:
	return float(text.md5_text().substr(0, 8).hex_to_int()) / 4294967296.0
