extends DotMenuSettings

const LmBindings := preload("lm_bindings.gd")

## A player's own settings and the menu that changes them: view turn rate and width, volumes, the window, the menu's look.
## dot-menu's `DotMenuSettings` with this game's schema; scopes are the family's: `sensitivity` ACCOUNT (`tmc_account`), `field_of_view`
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
	name = "Settings"
	directory = SETTINGS_DIR
	app_namespace = APP_NAMESPACE
	schema = schema_for()
	config = DotMenuConfig.new()
	config.brand_name = "Look at Me"
	# Help and Leave are dot-menu's stock: H opens help, Leave leaves the server or quits a
	# solo game. Every game in the family has both (the first play test found this one with
	# neither). The keys are a table now ([LmBindings]), so the help screen lists them.
	bindings = LmBindings.make()
	# The HUD's key line says H (`LmClient._refresh_key_line`); a corner plate would say it twice.
	config.help_hint = &"off"
	var _layered := config.load_layered()


## The document: this game's field of view first, so it keeps its own default, then the
## stock settings it applies.
static func schema_for() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION
	s.add(DotSettingsDef.integer(&"field_of_view", DEFAULT_FOV, 60, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.boolean(&"ambient", true, &"audio").with_description("Quiet sounds under the house."))
	s.add(DotSettingsDef.number(&"ambient_volume", 1.0, 0.0, 1.0, &"audio"))
	return DotMenuStock.declare(s, DotMenuStock.DEFAULT_GROUPS, null, NOT_APPLIED)


## The help screen's goal and rules; the keys come from [LmBindings].
func _fill_help(help: DotMenuHelp) -> void:
	help.about = "A dark house, thirty-two levels deep, with witches walking its rooms. Find what opens the next door (a key, a lever, something to carry) before one of them looks at you."
	help.add_text("Being seen", "A witch's look fills a meter. Keep out of her sight and it drains. A lit flashlight makes you easier to see from further off; crouching and standing still make you harder. If the meter fills, she has you: back to the level's start, and on the default rules what you found there is lost.")
	help.add_text("Levels", "Everybody plays every level for themselves. Type /r to go back to the lobby, or /l3 to go to a level you have already reached.")
