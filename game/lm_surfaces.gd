extends RefCounted

## The house's surfaces: a wallpaper, floorboards and a ceiling, painted into images once and
## shared by every room, for the rooms to tint and offset.
##
## [b]Why they exist.[/b] The walls were one flat colour each. A flat surface has nothing for the eye
## to judge distance by, so at range a wall read as a smooth glowing slab with the flashlight's
## gradient across it. These have fine detail (stripes, damask, stains, grime) that MIPMAPS
## average away at a distance, so far walls settle to a steady tone instead of shimmering, and
## the detail comes back as you walk up. Every texture is tileable, drawn in world space
## (triplanar, see [method LmLevel._surface]) so a 3 m wall and a 12 m one carry the same grain,
## and nothing is stretched.

const SIZE := 256

static var _cache: Dictionary = {}


## Tileable noise in 0..1: a few sine bands of whole-number frequencies (so the edges meet),
## which a plain hash of the pixel would not give at the scales stains need.
static func _blotch(x: int, y: int, seed_value: int) -> float:
	var u := float(x) / float(SIZE) * TAU
	var v := float(y) / float(SIZE) * TAU
	var a := float(seed_value)
	var n := sin(u * 2.0 + a) * sin(v * 3.0 + a * 1.7) * 0.5
	n += sin(u * 5.0 + v * 3.0 + a * 0.3) * 0.25
	n += sin(u * 3.0 - v * 7.0 + a * 2.1) * 0.15
	n += sin(u * 11.0 + v * 9.0 + a) * 0.1
	return clampf(n * 0.5 + 0.5, 0.0, 1.0)


## A pixel's own random 0..1, the same each run.
static func _grain(x: int, y: int, salt: int) -> float:
	return float(hash(Vector3i(x, y, salt)) & 0xffff) / 65535.0


static func _make(kind: String) -> Texture2D:
	var image := Image.create(SIZE, SIZE, true, Image.FORMAT_RGB8)

	for y in SIZE:
		for x in SIZE:
			var tone := 0.0

			match kind:
				"wall":
					# Narrow stripes with a damask diamond between them, then stains and grime.
					var stripe := 0.5 + 0.5 * sin(float(x) / float(SIZE) * TAU * 8.0)
					var diamond := 0.5 + 0.5 * sin(float(x) / float(SIZE) * TAU * 4.0) * sin(float(y) / float(SIZE) * TAU * 4.0)
					var stain := _blotch(x, y, 3)
					tone = 0.78 + 0.10 * stripe + 0.07 * diamond - 0.14 * stain * stain
					tone += (_grain(x, y, 1) - 0.5) * 0.06
				"floor":
					# Boards a quarter-metre wide, each its own shade, with grain and dirt.
					var board := x / 32
					var shade := 0.82 + 0.18 * _grain(board, 0, 7)
					var seam := 1.0 if (x % 32) < 2 else 0.0
					var butt := 1.0 if ((y + board * 71) % 128) < 2 else 0.0
					var grain := 0.5 + 0.5 * sin(float(y) * 0.35 + _grain(board, 1, 9) * 6.0 + sin(float(x) * 0.4))
					tone = shade * (0.88 + 0.12 * grain) - 0.5 * maxf(seam, butt) - 0.25 * _blotch(x, y, 5)
					tone += (_grain(x, y, 2) - 0.5) * 0.05
				_:
					tone = 0.7 + 0.2 * _blotch(x, y, 11) - 0.2 * _blotch(x, y, 13)
					tone += (_grain(x, y, 3) - 0.5) * 0.08

			tone = clampf(tone, 0.0, 1.0)
			image.set_pixel(x, y, Color(tone, tone * 0.98, tone * 0.95))

	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## The texture for [param kind] ("wall", "floor" or "ceiling"), made the first time it is asked.
static func texture(kind: String) -> Texture2D:
	if not _cache.has(kind):
		_cache[kind] = _make(kind)

	return _cache[kind]


## Drops the cached textures; a process that ends with them held reports them as leaked.
static func clear_cache() -> void:
	_cache.clear()
