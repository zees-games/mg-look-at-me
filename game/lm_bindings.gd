extends RefCounted

## Every key this game reads, as one dot-menu [DotMenuBindings] table: the action, the setting
## that stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it:[/b] the client matches events against the actions,
## the settings document stores one binding per row, the menu's Controls page draws a key per
## row, and the help screen (H) lists them with the key each is on now. Until 2026-10-11 only
## the use key was an action; the rest were keycodes in `LmClient._unhandled_input`.
##
## [b]Enter opens the command line as well as Slash[/b], as a fixed second key no row holds,
## because it is where a chat line opens in most games. H is help, in every game of the family
## (dot-menu adds the row), so nothing here may default to it.

## The use key's action, which `LmClient.USE_ACTION` names and the prompt draws.
const USE := &"lm_use"
const FLASHLIGHT := &"lm_flashlight"
const VIEW := &"lm_view"
const COMMAND := &"lm_command"
const SCOREBOARD := &"lm_scoreboard"


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement("Movement", "Ctrl", "Crouch (a witch sees you more slowly)")
	keys.add(USE, &"bind_use", "Take, open, use", "E", "Hands")
	keys.add(FLASHLIGHT, &"bind_flashlight", "Flashlight (and a witch sees you sooner)", "F", "Hands")
	keys.add(VIEW, &"bind_view", "First or third person, where the server allows it", "C", "General")
	keys.add(COMMAND, &"bind_command", "A command: /r to the lobby, /l3 to a level you reached (Enter too)", "Slash", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys
