extends Node

## What a player has done in the house, as dot-stats numbers, and the achievements over them, reported to TMC's backbone when
## the server has one. The brief's "Out" is getting out of the whole house; the crown is [LmPlayer]'s.
## It listens and nothing calls it: the house's own signals are the whole input. Server only.

const LmGame := preload("lm_game.gd")

const CHANNEL := "lookatme.progress"

const LEVELS_DONE := &"lm.levels_done"
const BEST_LEVEL := &"lm.best_level"
const CATCHES := &"lm.catches"
const WINS := &"lm.wins"
## The published skill figure the site orders by (dot-stats' GSStatsRank).
const RANK_SCORE := &"rank_score"

signal earned(key: StringName, title: String, points: int)

const REPORT_INTERVAL := 60.0

var _report_timer: Timer

var game: LmGame = null
var stats: GSStatsTracker = null
## The skill rank: weighted lifetime figures, filed when a level or the house is done.
var rank: GSStatsRank = null
var achievements: GSAchievementTracker = null
var link: GSAchievementStatsLink = null

## Only the stats report is filed under dot-game's stable key; `game.players` and awards keep `uid:...`.
var stats_feed := GSGameStatsFeed.new()
## world key -> [stats key, userid], noted at admission by [method note_session].
var _stats_keys: Dictionary = {}


static func schema() -> GSStatsSchema:
	var out := GSStatsSchema.new()
	_add(out, LEVELS_DONE, GSStatsDef.Kind.COUNTER, "Levels got through", "levels")
	_add(out, BEST_LEVEL, GSStatsDef.Kind.BEST, "Deepest level", "level")
	_add(out, CATCHES, GSStatsDef.Kind.COUNTER, "Times she saw you", "catches")
	_add(out, WINS, GSStatsDef.Kind.COUNTER, "Times out of the whole house", "wins")
	GSStatsRank.declare(out, RANK_SCORE, "Rank score")
	return out


static func _add(out: GSStatsSchema, id: StringName, kind: GSStatsDef.Kind, display: String, unit: String) -> void:
	var def := GSStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = true
	out.stats.append(def)


static func catalogue() -> GSAchievementCatalogue:
	var made: Array[GSAchievement] = []
	made.append(_rule(&"lm.first_door", "Through the Front Door", LEVELS_DONE, 1.0, 10, "Get through level 1."))
	made.append(_rule(&"lm.halfway", "Halfway Down", BEST_LEVEL, 16.0, 30, "Reach level 16.", &"lm.depth", 1, GSAchievementRule.Merge.HIGHEST))
	made.append(_rule(&"lm.out", "Out", WINS, 1.0, 100, "Get out of the whole house.", &"lm.depth", 2))
	var seen := _rule(&"lm.look_at_me", "Look At Me", CATCHES, 100.0, 10, "Be seen a hundred times.")
	seen.secret = true
	made.append(seen)
	var out := GSAchievementCatalogue.new()
	out.achievements = made
	return out


static func _rule(id: StringName, title: String, stat: StringName, target: float, points: int, description: String,
		series: StringName = &"", tier: int = 0, merge: int = GSAchievementRule.Merge.SUM) -> GSAchievement:
	var out := GSAchievement.make(id, title, [
		GSAchievementRule.make(stat, target, GSAchievementRule.Op.AT_LEAST, merge),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


## [param directory] keeps achievement progress on disk ("" keeps it in memory); [param report]
## sends both to the backbone.
func setup(world: LmGame, directory: String, report: bool) -> GSResult:
	game = world
	stats = GSStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)
	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("look at me stats")

	achievements = GSAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	achievements.register_as = &""

	if directory != "":
		var file_store := GSAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = GSAchievementStoreMemory.new()

	add_child(achievements)
	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("look at me achievements")

	achievements.unlocked.connect(func(player_id: String, achievement: GSAchievement) -> void:
		earned.emit(StringName(player_id), achievement.display_name, achievement.points))

	link = GSAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)
	var linked := link.start()

	if not linked.ok:
		return linked.wrap("the stats-to-achievements link")

	rank = GSStatsRank.new()
	rank.stat_id = RANK_SCORE
	rank.terms = [
		{"stat": String(LEVELS_DONE), "weight": 1.0},
		{"stat": String(WINS), "weight": 5.0},
		{"stat": String(CATCHES), "weight": -0.05},
	]
	rank.record_fn = func(who: Variant, stat: StringName, value: float) -> void: record(StringName(str(who)), stat, value)
	rank.key_fn = func(who: Variant) -> StringName: return _stats_key(StringName(str(who)))

	game.level_done.connect(func(key: StringName, n: int) -> void:
		record(key, LEVELS_DONE)
		record(key, BEST_LEVEL, float(n))
		_publish_rank(key))
	game.caught.connect(func(key: StringName) -> void: record(key, CATCHES))
	game.won.connect(func(key: StringName) -> void:
		record(key, WINS)
		_publish_rank(key))
	game.player_left.connect(leave)
	return GSResult.success(self)


## Turns the backbone report on or off at run time (the family cvar `stats_report`); the cvar is bound after setup(), so setup() alone cannot see it.
func set_reporting(on: bool) -> GSResult:
	if stats == null:
		return GSResult.fail(GSError.CODE_STATE, "There is no stats tracker.")

	if achievements != null:
		achievements.report_to_backbone = on

	if not on:
		stats.report_to_backbone = false
		return GSResult.success(false)

	stats.report_to_backbone = true
	stats.define_on_start = true

	if not stats.reporter.is_available():
		stats.report_to_backbone = false
		GSLog.warn(CHANNEL, "stats reporting needs a backbone client with STATS_WRITE; staying off")
		return GSResult.fail(GSError.CODE_STATE, "No backbone client to report stats through.")

	if _report_timer == null:
		_report_timer = Timer.new()
		_report_timer.name = "StatsReportTimer"
		_report_timer.wait_time = REPORT_INTERVAL
		_report_timer.autostart = true
		_report_timer.timeout.connect(func() -> void: stats.flush())
		add_child(_report_timer)

	return GSResult.success(true)


## Notes the stable stats key of a player's seat; a player never noted files under the world key.
func note_session(key: StringName, session: GSClientSession) -> void:
	stats_feed.open_sessions = false
	_stats_keys[key] = [stats_feed.key_for(session), session.userid]


func _stats_key(key: StringName) -> StringName:
	return _stats_keys[key][0] if _stats_keys.has(key) else key


func record(key: StringName, stat: StringName, value: float = 1.0) -> void:
	var player: Node = game.players.get(key, null) if game != null else null

	if stats == null or player == null:
		return

	if not stats.has_player(_stats_key(key)):
		_load_baseline(key)
		stats.begin(_stats_key(key), str(player.get("display_name")))
		link.key_map[_stats_key(key)] = key
		_begin(key)

	var filed := stats.record(_stats_key(key), stat, value)

	if not filed.ok:
		GSLog.warn(CHANNEL, "a reading was refused", {"player": String(key), "stat": String(stat), "why": filed.error.message})


## Reads the player's stored lifetime totals before this session's figures are flushed into the store (reading later would count them twice). The file store answers without suspending.
func _load_baseline(key: StringName) -> void:
	if rank != null and stats.store != null:
		rank.load_baseline(stats.store, key)


## Files the player's rank_score on their lifetime baseline plus this session.
func _publish_rank(key: StringName) -> void:
	if rank == null or rank.mode != GSStatsRank.MODE_WEIGHTED or stats == null or not stats.has_player(_stats_key(key)):
		return
	var _s := rank.publish_lifetime(key, session_values(key), stats.schema)


func _begin(key: StringName) -> void:
	var began: GSResult = await achievements.begin(String(key))

	if not began.ok:
		GSLog.warn(CHANNEL, "achievement progress could not be loaded", {"player": String(key), "why": began.error.message})


func leave(key: StringName) -> void:
	if stats == null or not stats.has_player(_stats_key(key)):
		return

	var _values := stats.end(_stats_key(key))
	if rank != null:
		rank.forget(key)
	link.key_map.erase(_stats_key(key))

	if _stats_keys.has(key):
		stats_feed.forget(int(_stats_keys[key][1]))
		_stats_keys.erase(key)

	link.forget(String(key))
	var ended: GSResult = await achievements.end(String(key))

	if not ended.ok:
		GSLog.warn(CHANNEL, "achievement progress could not be saved", {"player": String(key), "why": ended.error.message})


func session_values(key: StringName) -> GSStatsValues:
	return stats.session_values(_stats_key(key)) if stats != null else GSStatsValues.new()
