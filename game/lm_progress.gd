extends Node

## What a player has done in the house, as dot-stats numbers, and the achievements over them, reported to TMC's backbone when
## the server has one. The brief's "Out" is getting out of the whole house; the crown is [LmPlayer]'s.
## It listens and nothing calls it: the house's own signals are the whole input. Server only.

const LmGame := preload("lm_game.gd")
const LmStatsRelay := preload("lm_stats_relay.gd")

const CHANNEL := "lookatme.progress"

const LEVELS_DONE := &"lm.levels_done"
const BEST_LEVEL := &"lm.best_level"
const CATCHES := &"lm.catches"
const WINS := &"lm.wins"

signal earned(key: StringName, title: String, points: int)

const REPORT_INTERVAL := 60.0

var _report_timer: Timer

var game: LmGame = null
var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

## Only the stats report is filed under dot-game's stable key; `game.players` and awards keep `uid:...`.
var stats_feed := DotGameStatsFeed.new()
var relay := LmStatsRelay.new()

## world key -> [stats key, userid], noted at admission by [method note_session].
var _stats_keys: Dictionary = {}


static func schema() -> DotStatsSchema:
	var out := DotStatsSchema.new()
	_add(out, LEVELS_DONE, DotStatsDef.Kind.COUNTER, "Levels got through", "levels")
	_add(out, BEST_LEVEL, DotStatsDef.Kind.BEST, "Deepest level", "level")
	_add(out, CATCHES, DotStatsDef.Kind.COUNTER, "Times she saw you", "catches")
	_add(out, WINS, DotStatsDef.Kind.COUNTER, "Times out of the whole house", "wins")
	return out


static func _add(out: DotStatsSchema, id: StringName, kind: DotStatsDef.Kind, display: String, unit: String) -> void:
	var def := DotStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = true
	out.stats.append(def)


static func catalogue() -> DotAchievementCatalogue:
	var made: Array[DotAchievement] = []
	made.append(_rule(&"lm.first_door", "Through the Front Door", LEVELS_DONE, 1.0, 10, "Get through level 1."))
	made.append(_rule(&"lm.halfway", "Halfway Down", BEST_LEVEL, 16.0, 30, "Reach level 16.", &"lm.depth", 1, DotAchievementRule.Merge.HIGHEST))
	made.append(_rule(&"lm.out", "Out", WINS, 1.0, 100, "Get out of the whole house.", &"lm.depth", 2))
	var seen := _rule(&"lm.look_at_me", "Look At Me", CATCHES, 100.0, 10, "Be seen a hundred times.")
	seen.secret = true
	made.append(seen)
	var out := DotAchievementCatalogue.new()
	out.achievements = made
	return out


static func _rule(id: StringName, title: String, stat: StringName, target: float, points: int, description: String,
		series: StringName = &"", tier: int = 0, merge: int = DotAchievementRule.Merge.SUM) -> DotAchievement:
	var out := DotAchievement.make(id, title, [
		DotAchievementRule.make(stat, target, DotAchievementRule.Op.AT_LEAST, merge),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


## [param directory] keeps achievement progress on disk ("" keeps it in memory); [param report]
## sends both to the backbone.
func setup(world: LmGame, directory: String, report: bool) -> DotResult:
	game = world
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)
	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("look at me stats")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	achievements.register_as = &""

	if directory != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)
	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("look at me achievements")

	achievements.unlocked.connect(func(player_id: String, achievement: DotAchievement) -> void:
		earned.emit(StringName(player_id), achievement.display_name, achievement.points))

	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	relay.follow(stats)
	link.stats = relay
	add_child(link)
	var linked := link.start()

	if not linked.ok:
		return linked.wrap("the stats-to-achievements link")

	game.level_done.connect(func(key: StringName, n: int) -> void:
		record(key, LEVELS_DONE)
		record(key, BEST_LEVEL, float(n)))
	game.caught.connect(func(key: StringName) -> void: record(key, CATCHES))
	game.won.connect(func(key: StringName) -> void: record(key, WINS))
	game.player_left.connect(leave)
	return DotResult.success(self)


## Turns the backbone report on or off at run time (the family cvar `stats_report`); the cvar is bound after setup(), so setup() alone cannot see it.
func set_reporting(on: bool) -> DotResult:
	if stats == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no stats tracker.")

	if achievements != null:
		achievements.report_to_backbone = on

	if not on:
		stats.report_to_backbone = false
		return DotResult.success(false)

	stats.report_to_backbone = true
	stats.define_on_start = true

	if not stats.reporter.is_available():
		stats.report_to_backbone = false
		DotLog.warn(CHANNEL, "stats reporting needs a backbone client with STATS_WRITE; staying off")
		return DotResult.fail(DotError.CODE_STATE, "No backbone client to report stats through.")

	if _report_timer == null:
		_report_timer = Timer.new()
		_report_timer.name = "StatsReportTimer"
		_report_timer.wait_time = REPORT_INTERVAL
		_report_timer.autostart = true
		_report_timer.timeout.connect(func() -> void: stats.flush())
		add_child(_report_timer)

	return DotResult.success(true)


## Notes the stable stats key of a player's seat; a player never noted files under the world key.
func note_session(key: StringName, session: DotClientSession) -> void:
	stats_feed.open_sessions = false
	_stats_keys[key] = [stats_feed.key_for(session), session.userid]


func _stats_key(key: StringName) -> StringName:
	return _stats_keys[key][0] if _stats_keys.has(key) else key


func record(key: StringName, stat: StringName, value: float = 1.0) -> void:
	var player: Node = game.players.get(key, null) if game != null else null

	if stats == null or player == null:
		return

	if not stats.has_player(_stats_key(key)):
		stats.begin(_stats_key(key), str(player.get("display_name")))
		relay.record_of[_stats_key(key)] = key
		_begin(key)

	var filed := stats.record(_stats_key(key), stat, value)

	if not filed.ok:
		DotLog.warn(CHANNEL, "a reading was refused", {"player": String(key), "stat": String(stat), "why": filed.error.message})


func _begin(key: StringName) -> void:
	var began: DotResult = await achievements.begin(String(key))

	if not began.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {"player": String(key), "why": began.error.message})


func leave(key: StringName) -> void:
	if stats == null or not stats.has_player(_stats_key(key)):
		return

	var _values := stats.end(_stats_key(key))
	relay.record_of.erase(_stats_key(key))

	if _stats_keys.has(key):
		stats_feed.forget(int(_stats_keys[key][1]))
		_stats_keys.erase(key)

	link.forget(String(key))
	var ended: DotResult = await achievements.end(String(key))

	if not ended.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be saved", {"player": String(key), "why": ended.error.message})


func session_values(key: StringName) -> DotStatsValues:
	return stats.session_values(_stats_key(key)) if stats != null else DotStatsValues.new()
