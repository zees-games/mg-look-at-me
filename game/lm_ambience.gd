extends RefCounted

## What the house's ambience is: the cvar defaults shared by the simulation (binds `lm_ambient*`) and the client's director (plays them).

const PREFIX := "lm"
## The witches' hum and steps are the warning: the layer sits under them, with rare one-shots.
const LEVEL := 0.3
const RATE := 0.5
const DEFAULT_MOOD := &"interior_horror"

## By house id; any house not listed takes the default.
const HOUSE_MOODS := {&"asylum": &"indoor_hall", &"forgotten": &"industrial"}


static func make_rules() -> DotAmbienceRules:
	var r := DotAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r


## The cvars a workbench set offers: name -> profile type.
static func cvar_types() -> Dictionary:
	var rules := make_rules()
	var out := {}
	for key: String in DotAmbienceRules.VARS:
		var row: Array = DotAmbienceRules.VARS[key]
		out[rules.cvar_of(row)] = "string" if row[2] == null else "float"
	return out
