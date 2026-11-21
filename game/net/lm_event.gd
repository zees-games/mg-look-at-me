extends GSNetMessage

const LmEvents := preload("lm_events.gd")

## Anything the authority tells a client that is not a snapshot. Reliable, to clients.

const NAME := &"lookatme.event"
const KIND_BITS := 5
const MAX_BODY := 60000

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## Built with `new(kind, body)`; this file must not preload itself: a GSNetMessage that preloads ITSELF, loaded from a
## module a running [GSServer] loads at runtime (every deployed server), leaks the script graph at exit on Godot 4.7.2.
## The registry decodes with a bare `new()`, which is why both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: GSNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: GSNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> GSResult:
	if kind < 0 or kind >= LmEvents.Kind.size():
		return GSResult.fail(GSError.CODE_INVALID, "Unknown event kind %d." % kind)

	return GSResult.success(true)


## Whether every [enum LmEvents.Kind] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(LmEvents.Kind.values().max()) < (1 << KIND_BITS)


func reader() -> GSNetReader:
	return GSNetReader.new(body)


func _to_string() -> String:
	return "LmEvent(%s, %d bytes)" % [LmEvents.kind_name(kind), body.size()]
