extends RefCounted

## Every key this game reads, as one dot-menu [DotMenuBindings] table: action, storing setting, label, default, card.
## One table because the client, the settings document, the Controls page and the help screen (H) all read it.
## Enter opens the command line as a fixed second key no row holds; H is help in every game (dot-menu adds the row), so nothing here may default to it.

## The use key's action, which `LmClient.USE_ACTION` names and the prompt draws.
const USE := &"lm_use"
const FLASHLIGHT := &"lm_flashlight"
const VIEW := &"lm_view"
const COMMAND := &"lm_command"
const SCOREBOARD := &"lm_scoreboard"
## dot-voice's own action names, so DotVoiceLookMute reads the rows this table binds.
const VOICE_GAG := &"voice_gag"
const VOICE_MUTE := &"voice_mute"


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement("Movement", "Ctrl", "Crouch (a witch sees you more slowly)")
	# The game has no weapon or item switching, so the wheel is free to jump.
	keys.add_wheel_jump("Movement")
	keys.add(USE, &"bind_use", "Take, open, use", "E", "Hands")
	keys.add(FLASHLIGHT, &"bind_flashlight", "Flashlight (and a witch sees you sooner)", "F", "Hands")
	# F5, the family's view key in every game (it was C here).
	keys.add(VIEW, &"bind_view", "First or third person, where the server allows it", "F5", "General")
	keys.add(COMMAND, &"bind_command", "A command: /r to the lobby, /l3 to a level you reached (Enter too)", "Slash", "General")
	# Look at a player and press: G stops hearing them, K mutes them (voice and chat). Two keys,
	# not a double-tap, so the help screen says what each does. K, because H is help.
	keys.add(VOICE_GAG, &"bind_voice_gag", "Look at a player: stop (or resume) hearing them", "G", "Voice")
	keys.add(VOICE_MUTE, &"bind_voice_mute", "Look at a player: mute (or unmute) their voice and chat", "K", "Voice")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	# The view's default moved from C under saved documents: a player who never touched it
	# follows to F5, a key they chose stays.
	return keys.renamed(&"bind_view", ["C"])
