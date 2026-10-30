extends RefCounted

## What the server tells a client and what a client asks, by kind. Kinds are their index on the wire: append, never reorder.
## Movement is in snapshots, predicted. Everything here is small and rare, so it is JSON: the hello with every level document, arrivals and leavings,
## and a player's own progress (held, opened, used, taken) to that player alone; the doors in it are what the owner's prediction walks through.

enum Kind {
	## You, the clock, how many levels follow, the settings a client needs.
	HELLO,
	## One level document, deflated ([method write_level]); never all in the HELLO (32 are 490 KB of JSON, about 90 KB deflated).
	## Paced by the client's LEVELS acks (LmNetBridge.LEVEL_WINDOW): a browser WebSocket peer drops what arrives past its
	## 64 KiB inbound buffer between frames. See docs/design.md, "The house on the wire".
	LEVEL,
	## A player is here, or has a new name or face: key, name, net id, the avatar document.
	JOIN,
	## A player left.
	LEAVE,
	## Your progress: level, best, holds, opened, used, taken, the events that have happened to you. To the owner only.
	PROGRESS,
	## A line for the middle of your screen. To one player.
	SAY,
	## A chat line, as the server's chat router addressed it.
	CHAT,
	## A sound for you, by its LmAudio catalogue id: {"id"}. The click of your own E, which only
	## the server can say landed on something. To one player.
	SOUND,
}

enum Ask {
	## The scene is loaded; send the world.
	READY,
	## {"action": use | flashlight | command | say, ...}.
	ACT,
	## {"serial", "got"}: the client holds the first `got` LEVELs of the HELLO numbered `serial`;
	## the server sends more while what is unacknowledged stays under LEVEL_WINDOW.
	LEVELS,
}


static func kind_name(kind: int) -> String:
	return Kind.keys()[kind] if kind >= 0 and kind < Kind.size() else "?%d" % kind


static func ask_name(kind: int) -> String:
	return Ask.keys()[kind] if kind >= 0 and kind < Ask.size() else "?%d" % kind


const MAX_TEXT := 60000


static func write_json(data: Variant) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_string(JSON.stringify(data), MAX_TEXT)
	return writer.to_bytes()


static func read_json(reader: DotNetReader) -> Dictionary:
	var text := reader.read_string(MAX_TEXT)

	if not reader.ok():
		return {}

	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## A level document as a LEVEL body: its compact JSON's length, then the JSON deflated. A level
## is about 15 KB of JSON and 3 KB deflated: the house's 490 KB goes as 90 KB.
static func write_level(doc: Dictionary) -> PackedByteArray:
	var raw := JSON.stringify(doc).to_utf8_buffer()
	var writer := DotNetWriter.new()
	writer.write_varint(raw.size())
	writer.write_bytes(raw.compress(FileAccess.COMPRESSION_DEFLATE))
	return writer.to_bytes()


## The document out of a LEVEL body, or {} for anything that is not one. The stated length is
## capped at [constant MAX_TEXT] before anything is inflated, so a body cannot ask for more.
static func read_level(reader: DotNetReader) -> Dictionary:
	var size := reader.read_varint()
	var packed := reader.read_bytes(MAX_TEXT)

	if not reader.ok() or size <= 0 or size > MAX_TEXT:
		return {}

	var raw := packed.decompress(size, FileAccess.COMPRESSION_DEFLATE)

	if raw.size() != size:
		return {}

	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}
