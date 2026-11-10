extends DotMenuGameSettings

const LmBindings := preload("lm_bindings.gd")

## A player's own settings and the menu that changes them: view turn rate and width, volumes, the window, the menu's look.
## dot-menu's `DotMenuGameSettings` with this game's spec; scopes are the family's: `sensitivity` ACCOUNT (`tmc_account`), `field_of_view`
## SERVER_CLAMPED (a wide view is an advantage a server may cap), volumes per machine. Use: setup(), bind_look/camera/audio(), open().

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://lookatme_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"look_at_me"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 75

## Stock keys nothing here applies: every sound is on dot-audio's SFX bus (so master and
## effects are the two volumes), the only effects are the catch's flash and jolt (no spawned
## effect for a quality setting to thin out), and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"voice_volume", &"fx_quality", &"chat_window",
]


func _init() -> void:
	super(spec_for())


## The game's settings as data: names, field of view, extra settings, keys and the help screen's goal and rules.
static func spec_for() -> DotMenuGameSpec:
	var s := DotMenuGameSpec.new()
	s.schema_version = SCHEMA_VERSION
	s.brand_name = "Look at Me"
	s.settings_dir = SETTINGS_DIR
	s.app_namespace = APP_NAMESPACE
	s.default_fov = DEFAULT_FOV
	s.fov_min = 60
	s.help_hint = &"off"
	s.ambient_text = "Quiet sounds under the house."
	s.not_applied = NOT_APPLIED
	s.bindings_maker = func() -> DotMenuBindings: return LmBindings.make()
	s.help_about = "A dark house, thirty-two levels deep, with witches walking its rooms. Find what opens the next door (a key, a lever, something to carry) before one of them looks at you."
	s.help_cards = [
		["Being seen", "A witch's look fills a meter. Keep out of her sight and it drains. A lit flashlight makes you easier to see from further off; crouching and standing still make you harder. If the meter fills, she has you: back to the level's start, and on the default rules what you found there is lost."],
		["Levels", "Everybody plays every level for themselves. Type /r to go back to the lobby, or /l3 to go to a level you have already reached."],
	]
	s.help_sections = []
	return s
