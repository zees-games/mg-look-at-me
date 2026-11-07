extends DotVoteTimedGame

## The players choose the next house through dot-vote ([DotVoteDirector] over a [DotVoteListSource] of this
## server's houses): dot-vote's [DotVoteTimedGame] with Look At Me's names. No rounds, so dot-vote's clock decides: a house plays
## [member LmConfig.house_minutes], then a ballot opens with every house, the current one and an extension; `!rtv` works any time.
## Server side only. The rest is dot-vote's settings (`user://cfg/lookatme_vote.json`, `game.yml` metadata `house_vote:`).

const CHANNEL := "lookatme.vote"

## The key in the running game's descriptor metadata an operator's overrides are read from —
## [code]metadata: house_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "house_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}

## Minutes a house is played before the ballot (LmConfig.house_minutes). 0: only rock the vote.
var house_minutes: float = 45.0


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES
	noun = "house"
	config_path = "user://cfg/lookatme_vote.json"
	# Every house the game lists, Workshop ones labelled "Name [Pack]", read again before each ballot. Not dot-vote's follow_content: it
	# cannot leave out a pack document the game refused, and a ballot must not offer a house that cannot open.
	follows_content = false
	# Reports no round and no score, yet always took an operator's trigger as given; and registers as the vote service.
	drops_unfed = false
	register_service = true


## A time limit and a ballot with every house, the current one and an extension; at once, since there is no round to wait for and
## everybody is sent to the new lobby anyway.
func _rules() -> DotVoteRules:
	var rules := DotVoteRules.new()

	if house_minutes > 0.0:
		rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
		rules.duration_sec = house_minutes * 60.0
	else:
		rules.trigger = DotVoteRules.Trigger.RTV_ONLY
		rules.duration_sec = 0.0

	# At once: there is no round to wait for, and everybody is sent to the new lobby anyway.
	rules.apply = DotVoteRules.Apply.IMMEDIATE
	rules.rtv_apply = DotVoteRules.Apply.IMMEDIATE
	rules.include_current = true
	rules.include_extend = true
	rules.cooldown = 0
	rules.max_options = 6
	rules.vote_duration_sec = 30.0
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.RANDOM
	return rules


func _describe_extra() -> Dictionary:
	return {"house_minutes": house_minutes}
