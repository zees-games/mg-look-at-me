extends DotGameServices

## Chat, voice and moderation over dot-game's base: what this game decides about them.
##
## [b]Everybody can talk to everybody, whatever level they are on[/b]: the lobby is for
## socialising, and the house is too dark to be lonely in. Voice is push-to-talk and carries
## across the house too; a proximity channel would be the obvious horror choice and is the
## owner's to make. It is made now: proximity, a short radius, and a wall turns a voice down.

const LmGame := preload("lm_game.gd")

const CH_ALL := &"all"
const CH_ADMIN := &"admin"
const CH_WHISPER := &"whisper"

## The longest line, here once: the client's box refuses past it rather than the server cutting it.
const MAX_LINE := 160

## Voice carries this far (sv_voice_proximity_range). Short on purpose: in the dark a voice you
## can hear from the next room is a voice a witch can too, and silence is the horror.
const PROXIMITY_RANGE := 14.0

## Full volume inside this many metres (sv_voice_proximity_min).
const PROXIMITY_MIN := 2.0

## A wall between two players leaves this much of the voice (sv_voice_proximity_occlusion_gain).
const OCCLUSION_GAIN := 0.3


func _services_name() -> String:
	return "lookatme"


func _chat_rules() -> Object:
	var rules := DotChatRules.new()
	rules.max_length = MAX_LINE
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 20
	rules.burst = 4.0
	rules.flood_penalty_sec = 10.0
	rules.command_prefixes = PackedStringArray(["!", "/"])
	rules.broadcast_unknown_commands = false
	rules.history_limit = 300
	return rules


func _chat_channels() -> Array:
	var out: Array[DotChatChannel] = []
	var everyone := DotChatChannel.make(CH_ALL, "All", DotChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Longer than a round game's: there are no rounds, and somebody arriving mid-conversation
	# on a server people drive on for an hour wants the last few lines.
	everyone.backlog = 20
	everyone.history_limit = 300
	out.append(everyone)
	var admin := DotChatChannel.make(CH_ADMIN, "Admin", DotChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)
	var whisper := DotChatChannel.make(CH_WHISPER, "Whisper", DotChatChannel.Scope.DIRECT)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)
	return out


func _voice_config() -> Object:
	return voice_format()


## Everybody is heard by whoever is near, never across the house.
func _voice_default_channel() -> int:
	return DotVoiceRouter.Channel.PROXIMITY


## The router is built by the base; this game's proximity rules go on it before the module
## binds the sv_voice_* cvars, which read these values as their defaults.
func setup(p_server: DotServer, p_game: Object, p_link: Object) -> DotResult:
	var made: DotResult = super.setup(p_server, p_game, p_link)

	if made.ok and voice != null:
		configure_voice(voice)

	return made


## Proximity on, a wall in the way on. The occluder asks the house's physics once per listener
## already inside the radius ([method DotVoiceProximity.ray_occluder]), on the world layer only:
## a body is never a wall to a voice.
func configure_voice(router: Object) -> void:
	router.set("proximity_range", PROXIMITY_RANGE)
	router.set("proximity_min_distance", PROXIMITY_MIN)
	router.set("proximity_falloff", DotVoiceProximity.Falloff.INVERSE)
	router.set("proximity_occlusion", true)
	router.set("occlusion_gain", OCCLUSION_GAIN)
	router.set("occlusion_fn", DotVoiceProximity.ray_occluder(_space, LmGame.LAYER_WORLD))


func _space() -> Variant:
	var world := game as LmGame
	return world.get_world_3d().direct_space_state if world != null and world.is_inside_tree() else null


## The voice format both ends must agree on exactly: the client's voice manager reads this too.
static func voice_format() -> DotVoiceConfig:
	var config := DotVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = PROXIMITY_RANGE
	config.max_bytes_per_second = 6144
	return config


## Where a peer's player is.
func _position_of(peer_id: int) -> Vector3:
	var world := game as LmGame
	var key: StringName = bridge_key(peer_id)

	if world == null or key == &"":
		return Vector3.ZERO

	var player: Node3D = world.players.get(key, null)
	return player.global_position if player != null else Vector3.ZERO


func bridge_key(peer_id: int) -> StringName:
	return link.get("bridge").call("key_of_peer", peer_id) if link != null and link.get("bridge") != null else &""
