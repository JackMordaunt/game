package main

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:sort"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:unicode"
import "core:unicode/utf8"
import rl "vendor:raylib"

/*
	TODO:
		- turret line of sight (cast a ray, see if wall is hit?)
		- breakable turret
		- trip-mine tool
		- killable player
		- kill score
		- faster spawn rate over time
		- destroy bullets after lifetime
		- proection objective
*/

WALL_SIZE :: 16
TURRET_SIZE :: 16
BULLET_SIZE :: 16
PLAYER_SIZE :: 16
PLAYER_SPEED :: 16
ENEMY_SIZE :: 16
ENEMY_SPEED :: 16

Entity :: struct {
	using pos: rl.Vector2,
	width:     f32,
	height:    f32,
	speed:     f32,
	vel:       rl.Vector2,
}

Player :: struct {
	using entity:  Entity,
	max_hp:        int,
	hp:            int,
	currency:      int,
	tool:          Tool,
	tool_cooldown: i32,
	is_hit:        bool,
	hit_duration:  int,
}

Tool :: enum {
	Turret,
	Horizontal_Wall,
	Vertical_Wall,
}

Enemy :: struct {
	using entity:                 Entity,
	age_ticks:                    int,
	max_hp:                       int,
	hp:                           int,
	awareness:                    f32,
	mood:                         Enemy_Mood,
	ticks_since_last_idle_change: i32,
	idle_vel:                     rl.Vector2,
}

Enemy_Mood :: enum {
	Idle,
	Agro,
}

Wall :: struct {
	using entity: Entity,
	max_hp:       i32,
	hp:           i32,
}

Auto_Turret :: struct {
	using entity:  Entity,
	gun:           Gun,
	range:         f32,
	target:        rl.Vector2,
	has_target:    bool,
	fire_cooldown: i32,
}

Gun :: union {
	Machine_Gun,
	Shot_Gun,
	Lazer_Gun,
}

Machine_Gun :: struct {
	fire_rate: i32,
}

Shot_Gun :: struct {
	fire_rate: i32,
}

Lazer_Gun :: struct {
	fire_rate: i32,
}

Bullet :: struct {
	using entity: Entity,
	spawned_at:   int,
	destroyed:    bool,
}

Objective :: struct {
	using entity: Entity,
}

State :: struct {
	dimensions:           rl.Vector2,
	start:                rl.Vector2,
	player:               Player,
	stride:               i32,
	stage:                Stage,
	enemy_spawn_rate:     int,
	enemy_spawn_cooldown: int,
	ticks:                i64,
	enemies:              [dynamic]Enemy,
	turrets:              [dynamic]Auto_Turret,
	walls:                [dynamic]Wall,
	bullets:              [dynamic]Bullet,
	frame_by_frame:       bool,
	build:                bool,
	debug:                bool,
}

Stage :: enum {
	Playing,
	Paused,
	GameOver,
}

main :: proc() {
	width := f32(PLAYER_SIZE * 83)
	height := f32(PLAYER_SIZE * 41)

	player := Player {
		width    = PLAYER_SIZE,
		height   = PLAYER_SIZE,
		speed    = 3,
		max_hp   = 3,
		hp       = 3,
		x        = width / 2,
		y        = height / 2,
		currency = 10,
	}

	state := State {
		dimensions = rl.Vector2{width, height},
		start      = player,
		player     = player,
	}

	rl.SetRandomSeed(100)

	rl.InitWindow(i32(width), i32(height), "pathfinder")
	rl.SetTargetFPS(60)

	for !rl.WindowShouldClose() {
		update(&state)
		draw(&state)
	}
}

update :: proc(s: ^State) {
	if rl.IsKeyPressed(rl.KeyboardKey.NINE) {
		s.frame_by_frame = !s.frame_by_frame
	}

	// In frame-by-frame mode we only process a frame if comma is pressed.
	if s.frame_by_frame {
		if !rl.IsKeyPressed(rl.KeyboardKey.COMMA) {
			return
		}
	}

	if rl.IsKeyPressed(rl.KeyboardKey.ZERO) {
		s.debug = !s.debug
	}

	s.ticks += 1

	switch s.stage {
	case .Playing:
		update_player(s, &s.player)
		update_enemies(s)
		update_turrets(s)
		update_bullets(s)
		update_walls(s)
	case .Paused:
		if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
			s.stage = .Playing
			return
		}
	case .GameOver:
		if rl.GetKeyPressed() != rl.KeyboardKey.KEY_NULL {
			reset_state(s)
		}
	}
}

draw :: proc(s: ^State) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	switch s.stage {
	case .Playing:
		draw_bullets(s)
		draw_turrets(s)
		draw_enemies(s)
		draw_walls(s)
		draw_player(s)
		draw_build(s)
		draw_ui(s)
	case .Paused:
		width := rl.MeasureText("paused", 30)
		rl.DrawText(
			"paused",
			i32(s.dimensions.x) / 2 - (width / 2),
			i32(s.dimensions.y) / 2,
			30,
			rl.WHITE,
		)
	case .GameOver:
		width := rl.MeasureText("game over", 30)
		rl.DrawText(
			"game over",
			i32(s.dimensions.x) / 2 - (width / 2),
			i32(s.dimensions.y) / 2,
			30,
			rl.RED,
		)
	}

	rl.EndDrawing()
}

update_player :: proc(s: ^State, p: ^Player) {
	if p.is_hit {
		p.hit_duration -= 1
		if p.hit_duration == -1 {
			p.is_hit = false
			p.hit_duration = 0
		}
	}

	s.player.vel = rl.Vector2{}

	player_input(s, &s.player)

	s.player.pos += s.player.vel

	for wall in &s.walls {
		if rl.CheckCollisionBoxes(get_box(p), get_box(wall)) {
			p.pos = de_embed(p, wall)
		}
	}

	for turret in &s.turrets {
		if rl.CheckCollisionBoxes(get_box(p), get_box(turret)) {
			p.pos = de_embed(p, turret)
		}
	}

	if p.hp <= 0 {
		s.stage = .GameOver
	}
}

player_input :: proc(s: ^State, p: ^Player) {
	if rl.IsKeyDown(rl.KeyboardKey.W) {
		p.vel.y -= p.speed
	}
	if rl.IsKeyDown(rl.KeyboardKey.A) {
		p.vel.x -= p.speed
	}
	if rl.IsKeyDown(rl.KeyboardKey.S) {
		p.vel.y += p.speed
	}
	if rl.IsKeyDown(rl.KeyboardKey.D) {
		p.vel.x += p.speed
	}

	if rl.IsKeyPressed(rl.KeyboardKey.TAB) {
		switch p.tool {
		case .Turret:
			p.tool = .Horizontal_Wall
		case .Horizontal_Wall:
			p.tool = .Vertical_Wall
		case .Vertical_Wall:
			p.tool = .Turret
		}
	}

	if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
		s.build = !s.build
	}

	p.tool_cooldown -= 1

	if s.build &&
	   rl.IsMouseButtonReleased(.LEFT) &&
	   p.tool_cooldown < 0 &&
	   p.currency > 0 {
		mouse := rl.GetMousePosition()
		p.currency -= 1
		switch p.tool {
		case .Turret:
			p.tool_cooldown = 120
			append(
				&s.turrets,
				Auto_Turret {
					pos = mouse,
					width = TURRET_SIZE,
					height = TURRET_SIZE,
					range = 128,
					gun = Shot_Gun{fire_rate = 30},
				},
			)
		case .Horizontal_Wall:
			p.tool_cooldown = 30
			append(
				&s.walls,
				Wall {
					max_hp = 10,
					hp = 10,
					pos = mouse,
					width = WALL_SIZE * 2,
					height = WALL_SIZE / 2,
				},
			)
		case .Vertical_Wall:
			p.tool_cooldown = 30
			append(
				&s.walls,
				Wall {
					max_hp = 10,
					hp = 10,
					pos = mouse,
					width = WALL_SIZE / 2,
					height = WALL_SIZE * 2,
				},
			)
		}

	}
}

// dir returns a vector that points from a to b.
dir :: proc(a, b: rl.Vector2) -> rl.Vector2 {
	angle := math.atan2(a.y - b.y, a.x - b.x)
	return rl.Vector2{math.cos(angle), math.sin(angle)}
}

// dir returns a vector that points from a to b.
dir_jitter :: proc(a, b: rl.Vector2) -> rl.Vector2 {
	b := b
	spread: f32 = 30
	if rand.float32() > 0.5 {
		b.x += rand.float32() * spread
	} else {
		b.x -= rand.float32() * spread
	}
	if rand.float32() > 0.5 {
		b.y += rand.float32() * spread
	} else {
		b.y -= rand.float32() * spread
	}
	angle := math.atan2(a.y - b.y, a.x - b.x)
	return rl.Vector2{math.cos(angle), math.sin(angle)}
}

dist :: proc {
	dist_vec2,
	dist_vec3,
}

dist_vec3 :: proc(a, b: rl.Vector2) -> rl.Vector2 {
	return a - b
}

dist_vec2 :: proc(a, b: rl.Vector3) -> rl.Vector2 {
	d := a - b
	return rl.Vector2{d.x, d.y}
}

abs_dist :: proc(a, b: rl.Vector2) -> rl.Vector2 {
	d := a - b
	return rl.Vector2{math.abs(d.x), math.abs(d.y)}
}

// TODO: spawn faster over time... Waves? 
update_enemies :: proc(s: ^State) {
	if s.ticks % 120 == 0 {
		en := Enemy {
			max_hp    = 3,
			hp        = 3,
			mood      = .Idle,
			speed     = 1,
			width     = ENEMY_SIZE,
			height    = ENEMY_SIZE,
			awareness = 256,
			pos       = random_point_outside_rect(
				rl.Rectangle{width = s.dimensions.x, height = s.dimensions.y},
				10,
			),
		}
		append(&s.enemies, en)
	}
	for &en, ii in s.enemies {
		update_enemy(s, &en)
		if en.hp <= 0 {
			s.player.currency += 1
			ordered_remove(&s.enemies, ii)
		}
	}
}

random_point_outside_rect :: proc(d: rl.Rectangle, margin: i32) -> rl.Vector2 {
	x: f32
	y: f32

	switch rand.float32() {
	case 0.0 ..< 0.25:
		x = f32(rl.GetRandomValue(i32(d.x), i32(d.x + d.width)))
		y = f32(rl.GetRandomValue(i32(d.y) - margin, i32(d.y)))
	case 0.25 ..< 0.50:
		x = f32(rl.GetRandomValue(i32(d.x), i32(d.x + d.width)))
		y = f32(
			rl.GetRandomValue(
				i32(d.y + d.height),
				i32(d.y + d.height) + margin,
			),
		)
	case 0.50 ..< 0.75:
		x = f32(rl.GetRandomValue(i32(d.x) - margin, i32(d.x)))
		y = f32(rl.GetRandomValue(i32(d.y), i32(d.y + d.height)))
	case 0.75 ..= 1.0:
		x = f32(
			rl.GetRandomValue(i32(d.x + d.width), i32(d.x + d.width) + margin),
		)
		y = f32(rl.GetRandomValue(i32(d.y), i32(d.y + d.height)))
	}

	return rl.Vector2{x, y}
}

update_enemy :: proc(s: ^State, en: ^Enemy) {
	en.vel = rl.Vector2{}

	en.age_ticks += 1
	defer en.pos += en.vel

	update_mood(s, en)

	switch en.mood {
	case .Agro:
		en.speed = 1
		en.vel += (dir(s.player, en) * en.speed)
	case .Idle:
		en.speed = 0.3
		en.vel += (dir(s.player, en) * en.speed)
	}

	for &enemy in s.enemies {
		if &enemy == en {
			continue
		}
		if rl.CheckCollisionBoxes(get_box(enemy), get_box(en)) {
			en.pos = de_embed(en, enemy)
		}
	}

	for &w in s.walls {
		if rl.CheckCollisionBoxes(get_box(w), get_box(en)) {
			en.pos = de_embed(en, w)
			en.vel *= -25 // TODO: better movement system
			wall_take_damage(&w)
		}
	}

	for w in s.turrets {
		if rl.CheckCollisionBoxes(get_box(w), get_box(en)) {
			en.pos = de_embed(en, w)
		}
	}

	// Is the enemy colliding with the player? 
	if rl.CheckCollisionBoxes(get_box(s.player), get_box(en)) {
		player_take_damage(&s.player)
		en.hp = 0
	}
}

update_walls :: proc(s: ^State) {
	for &w, ii in s.walls {
		update_wall(s, &w)
		if w.hp <= 0 {
			ordered_remove(&s.walls, ii)
		}
	}
}

update_wall :: proc(s: ^State, w: ^Wall) {

}

update_mood :: proc(s: ^State, en: ^Enemy) {
	d := abs_dist(s.player, en)
	if d.x <= en.awareness && d.y <= en.awareness {
		en.mood = .Agro
	}
	if d.x >= en.awareness || d.y >= en.awareness {
		en.mood = .Idle
	}
}

update_bullets :: proc(s: ^State) {
	for &b, ii in s.bullets {
		update_bullet(s, &b)
		if b.destroyed {
			ordered_remove(&s.bullets, ii)
		}
	}
}

update_bullet :: proc(s: ^State, b: ^Bullet) {

	// If bullet is oob, destroy it.
	if !rl.CheckCollisionBoxes(get_box(b), get_box(s.dimensions)) {
		b.destroyed = true
		return
	}

	b.pos += b.vel * b.speed
	center := rl.Vector3{b.x, b.y, 0}

	for &en in s.enemies {
		if rl.CheckCollisionBoxSphere(get_box(en), center, b.width) {
			enemy_take_damage(&en)
			b.destroyed = true
		}
	}

	for &wall in s.walls {
		if rl.CheckCollisionBoxSphere(get_box(wall), center, b.width) {
			b.destroyed = true
		}
	}
}

update_turrets :: proc(s: ^State) {
	for &en in s.turrets {
		update_turret(s, &en)
	}
}

update_turret :: proc(s: ^State, t: ^Auto_Turret) {
	// aquire target
	// find closest enemy in range, and shoot at it.

	turret_acquire_target(s, t)

	t.fire_cooldown -= 1


	if t.has_target {
		if t.fire_cooldown <= 0 {
			switch gun in t.gun {
			case Machine_Gun:
				t.fire_cooldown = gun.fire_rate
			case Shot_Gun:
				t.fire_cooldown = gun.fire_rate
			case Lazer_Gun:
				t.fire_cooldown = gun.fire_rate
			}
			turret_fire_at(s, t, t.target)
		}
	}
}

// turret_acquire_target sets the target field to point to the nearest in-range enemy.
turret_acquire_target :: proc(s: ^State, t: ^Auto_Turret) {
	t.target = rl.Vector2{}

	targets := [dynamic]rl.Vector2{}
	defer delete(targets)

	for en in s.enemies {
		if in_range(t, en, t.range) {
			append(&targets, en.pos)
		}
	}

	slice.sort_by(targets[:], proc(l, r: rl.Vector2) -> bool {
		return l.x < r.x && l.y < r.y
	})

	if len(targets) > 0 {
		t.target = targets[0]
		t.has_target = true
	} else {
		t.has_target = false
	}
}

draw_player :: proc(s: ^State) {
	half_h_sz := s.player.width / 2
	half_w_sz := s.player.height / 2

	col := rl.GREEN

	if s.player.is_hit {
		col = rl.MAGENTA
	}

	col = rl.ColorAlpha(col, f32(s.player.hp) / f32(s.player.max_hp))

	rl.DrawRectangle(
		i32(s.player.x - half_w_sz),
		i32(s.player.y - half_h_sz),
		i32(s.player.width),
		i32(s.player.height),
		col,
	)

	for w in s.walls {
		r := rl.GetCollisionRec(
			rect_from_entity(s.player),
			rect_from_entity(w),
		)
		rl.DrawRectangleRec(r, rl.PURPLE)
	}
}

draw_enemies :: proc(s: ^State) {
	for en in s.enemies {
		draw_enemy(s, en)
	}
}

draw_turrets :: proc(s: ^State) {
	for en in s.turrets {
		draw_turret(s, en)
	}
}

draw_bullets :: proc(s: ^State) {
	for en in s.bullets {
		draw_bullet(s, en)
	}
}

draw_enemy :: proc(s: ^State, en: Enemy) {
	// Draw body.
	col := rl.MAROON

	if en.mood == .Agro {
		col = rl.RED
	}

	col = rl.ColorAlpha(col, f32(en.hp) / f32(en.max_hp))

	half_w_sz := en.width / 2
	half_h_sz := en.height / 2

	rl.DrawRectangle(
		i32(en.x - half_w_sz),
		i32(en.y - half_h_sz),
		i32(en.width),
		i32(en.height),
		col,
	)

	if s.debug {
		// Draw agro radius.
		rl.DrawCircleLines(
			i32(en.x),
			i32(en.y),
			en.awareness,
			rl.ColorAlpha(rl.PURPLE, 0.2),
		)
	}
}

draw_bullet :: proc(s: ^State, en: Bullet) {
	// NOTE: Assume width is the size for the bullet sphere.
	rl.DrawCircle(i32(en.x), i32(en.y), en.width, rl.ORANGE)
}

draw_turret :: proc(s: ^State, en: Auto_Turret) {
	// Base.
	rl.DrawCircle(i32(en.x), i32(en.y), f32(en.width / 2), rl.GRAY)

	if en.has_target && s.debug {
		rl.DrawLine(
			i32(en.x),
			i32(en.y),
			i32(en.target.x),
			i32(en.target.y),
			rl.LIGHTGRAY,
		)

	}
	if en.has_target {
		// Barrel that rotates around the base.
		rl.DrawRectanglePro(
			rl.Rectangle{x = en.x, y = en.y, width = 5, height = 15},
			rl.Vector2{2.5, 0},
			math.to_degrees(
				math.atan2(en.target.y - en.y, en.target.x - en.x),
			) -
			90,
			rl.GRAY,
		)
	}
}

draw_walls :: proc(s: ^State) {
	for &w in s.walls {
		draw_wall(s, w)
	}
}

draw_wall :: proc(s: ^State, en: Wall) {
	half_w_sz := en.width / 2
	half_h_sz := en.height / 2

	col := rl.DARKGRAY
	col = rl.ColorAlpha(col, f32(en.hp) / f32(en.max_hp))

	rl.DrawRectangle(
		i32(en.x - half_w_sz),
		i32(en.y - half_h_sz),
		i32(en.width),
		i32(en.height),
		col,
	)
}

draw_ui :: proc(s: ^State) {
	hp_text := rl.TextFormat("Health: %d", s.player.hp)
	hp_text_width := rl.MeasureText(hp_text, 24)
	rl.DrawText(hp_text, 10, 10, 24, rl.WHITE)

	currency_text := rl.TextFormat("Currency: %d", s.player.currency)
	rl.DrawText(currency_text, 30 + hp_text_width, 10, 24, rl.WHITE)
}

in_range :: proc(a, b: rl.Vector2, range: f32) -> bool {
	d := abs_dist(a, b)
	if d.x <= range && d.y <= range {
		return true
	}
	return false
}

get_box :: proc {
	get_box_from_entity,
	get_box_from_dims,
}

get_box_from_entity :: proc(en: Entity) -> rl.BoundingBox {
	return (rl.BoundingBox {
				min = rl.Vector3 {
					en.pos.x - en.width / 2,
					en.pos.y - en.height / 2,
					0,
				},
				max = rl.Vector3 {
					en.pos.x + en.width / 2,
					en.pos.y + en.height / 2,
					0,
				},
			})
}

get_box_from_dims :: proc(dims: rl.Vector2) -> rl.BoundingBox {
	return rl.BoundingBox{max = rl.Vector3{dims.x, dims.y, 0}}
}

player_take_damage :: proc(pl: ^Player) {
	pl.hp -= 1
	pl.is_hit = true
	pl.hit_duration = 15
}

reset_state :: proc(s: ^State) {
	s.player.hp = s.player.max_hp
	s.player.pos = s.start
	s.player.currency = 1
	s.stage = .Playing

	clear(&s.enemies)
	clear(&s.turrets)
	clear(&s.walls)
	clear(&s.bullets)
}


turret_fire_at :: proc(s: ^State, t: ^Auto_Turret, target: rl.Vector2) {
	switch gun in t.gun {
	case Machine_Gun:
		bullet := Bullet {
			pos    = t.pos,
			vel    = dir(target, t.pos),
			width  = 2,
			height = 2,
			speed  = 2,
		}

		append(&s.bullets, bullet)
	case Shot_Gun:
		for ii in 0 ..< 4 {
			bullet := Bullet {
				pos    = t.pos,
				vel    = dir_jitter(target, t.pos),
				width  = 2,
				height = 2,
				speed  = 2,
			}

			append(&s.bullets, bullet)
		}
	case Lazer_Gun:

	}
}


// de_embed resolves colliding entities, returning the new position of the subject.
de_embed :: proc(subject: Entity, object: Entity) -> (pos: rl.Vector2) {
	pos = subject.pos

	subject_rect := rect_from_entity(subject)
	object_rect := rect_from_entity(object)

	object_box := get_box(object)

	r := rl.GetCollisionRec(subject_rect, object_rect)

	// Pick the axis with the larger distance, then pick the side
	// the collision rect is closer to. 
	if r.width > r.height {
		if math.abs(r.y - object_box.max.y) >
		   math.abs(r.y - object_box.min.y) {
			pos.y -= r.height
		} else {
			pos.y += r.height
		}
	} else {
		if math.abs(r.x - object_box.max.x) >
		   math.abs(r.x - object_box.min.x) {
			pos.x -= r.width
		} else {
			pos.x += r.width
		}
	}

	return pos
}

rect_from_entity :: proc(en: Entity) -> rl.Rectangle {
	b := get_box(en)
	return (rl.Rectangle {
				x = b.min.x,
				y = b.min.y,
				width = b.max.x - b.min.x,
				height = b.max.y - b.min.y,
			})
}

enemy_take_damage :: proc(enemy: ^Enemy) {
	enemy.hp -= 1
}

wall_take_damage :: proc(wall: ^Wall) {
	wall.hp -= 1
}


draw_build :: proc(s: ^State) {
	if !s.build {
		return
	}

	mouse := rl.GetMousePosition()

	switch s.player.tool {
	case .Turret:
		draw_turret(
			s,
			Auto_Turret {
				pos = mouse,
				width = TURRET_SIZE,
				height = TURRET_SIZE,
				range = 128,
			},
		)
	case .Horizontal_Wall:
		draw_wall(
			s,
			Wall {
				max_hp = 10,
				hp = 10,
				pos = mouse,
				width = WALL_SIZE * 2,
				height = WALL_SIZE / 2,
			},
		)
	case .Vertical_Wall:
		draw_wall(
			s,
			Wall {
				max_hp = 10,
				hp = 10,
				pos = mouse,
				width = WALL_SIZE / 2,
				height = WALL_SIZE * 2,
			},
		)
	}
}

