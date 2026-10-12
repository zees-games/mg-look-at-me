extends Node

## The witch on her own, lit, from four sides, walking and seeing: what a person looks at when
## changing her (game/lm_witch.gd). Under xvfb:
##   xvfb-run -a godot --path . --resolution 1600x400 res://tools/witch_shot.tscn -- --out=res://screenshots/witch_sheet.png

const LmWitch := preload("res://game/lm_witch.gd")


func _ready() -> void:
	var out := "res://screenshots/witch_sheet.png"
	var seeing := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.substr(6)
		if arg == "--seeing":
			seeing = true

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.08, 0.1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.7)
	env.ambient_light_energy = 0.5
	env.glow_enabled = true
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-40), deg_to_rad(30), 0)
	sun.light_energy = 1.2
	add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30, 10)
	floor_mesh.mesh = plane
	add_child(floor_mesh)

	var witches: Array = []
	for i in 4:
		var witch: Node3D = LmWitch.new()
		add_child(witch)
		witch.call(&"build", 4.0 if i == 0 else 0.0, 70.0)
		witches.append(witch)

	var camera := Camera3D.new()
	add_child(camera)
	camera.fov = 40
	camera.position = Vector3(0, 1.5, 8.0)
	camera.current = true

	# Front, three-quarter, side, back; walking toward +Z (her facing PI) for a second.
	var turns := [PI, PI * 0.75, PI * 0.5, 0.0]
	for frame in 40:
		for i in 4:
			var at := Vector3(-4.5 + 3.0 * float(i), 0.0, float(frame) * 0.02)
			witches[i].call(&"place", at, turns[i], 0.0, 1.0 / 30.0)
			witches[i].call(&"set_seeing", seeing, 1.0 / 30.0)
		await get_tree().process_frame

	for _i in 3:
		await RenderingServer.frame_post_draw
	var saved := get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(out))
	print("saved %s (%s)" % [out, error_string(saved)])
	get_tree().quit()
