package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:bufio"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"
import "core:unicode"
import "core:slice"
import "core:testing"
import "core:math"
import "core:sort"
import rl "vendor:raylib"

/*
	TODO:
		- fully directional movement (not stuck to 8 discrete directions)
		- turret line of sight (cast a ray, see if wall is hit?)
		- breakable walls
		- breakable turret
		- trip-mine weapon
		- killable player
		- kill score
		- faster spawn rate over time
		- destroy bullets after lifetime
		- proection objective
*/

WALL_SIZE    :: 16
TURRET_SIZE  :: 16
BULLET_SIZE  :: 16
PLAYER_SIZE  :: 16
PLAYER_SPEED :: 16
ENEMY_SIZE   :: 16
ENEMY_SPEED  :: 16

Entity :: struct {
	using pos: rl.Vector2,
	size: f32,
	speed: f32,
	vel: rl.Vector2,
}

Player :: struct {
	using entity: Entity,

	max_hp: int,
	hp: int,

	weapon: Weapon,
	weapon_cooldown: i32,
}

Weapon :: enum {
	Turret,
	Wall,
}

Enemy :: struct {
	using entity: Entity,

	max_hp: int,
	hp: int,
	awareness: f32,
	mood: Enemy_Mood,

	ticks_since_last_idle_change: i32,
	idle_vel: rl.Vector2,
}

Enemy_Mood :: enum {
	Idle,
	Agro,
}

Wall :: struct {
	using entity: Entity,
	max_hp: i32,
	hp: i32,
}

Auto_Turret :: struct {
	using entity: Entity,

	range: f32,
	target: rl.Vector2,
	has_target: bool,


	fire_rate: i32,
	fire_cooldown: i32,
}

Bullet :: struct {
	using entity: Entity,
	destroyed: bool,
}

State :: struct {
	dimensions: rl.Vector2,
	start: rl.Vector2,
	player: Player,
	stride: i32,
	stage: Stage,

	enemy_spawn_rate: int,
	enemy_spawn_cooldown: int,

    ticks: i64,

	enemies: [dynamic]Enemy,
	turrets: [dynamic]Auto_Turret,
	walls:   [dynamic]Wall,
	bullets: [dynamic]Bullet,

	debug: bool,
}

Stage :: enum {
	Playing,
	Paused,
}

main :: proc() {
	width := f32(PLAYER_SIZE*83)
	height := f32(PLAYER_SIZE*41)

	player := Player{
    	size = PLAYER_SIZE,
    	speed = 10,
		x = 30,
		y = 30,
	}

	state := State{
		dimensions = rl.Vector2{width, height},
		start = player,
		player = player,
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
    if rl.IsKeyPressed(rl.KeyboardKey.ZERO) {
    	s.debug = !s.debug
    }

    s.ticks += 1

	switch s.stage {
	case .Playing:
		// if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
		// 	s.stage = .Paused
		// 	return
		// }

		update_player(s, &s.player)
		update_enemies(s)
		update_turrets(s)
		update_bullets(s)

	case .Paused:
		if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
			s.stage = .Playing
			return
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

	case .Paused:
		width := rl.MeasureText("paused", 30)
		rl.DrawText("paused", i32(s.dimensions.x)/2-(width/2), i32(s.dimensions.y)/2, 30, rl.WHITE)
	}

	rl.EndDrawing()
}

update_player :: proc(s: ^State, p: ^Player) {
	s.player.vel = rl.Vector2{}
	defer s.player.pos += s.player.vel

	player_input(s, &s.player)
}

player_input :: proc(s: ^State, p: ^Player) {
	if rl.IsKeyDown(rl.KeyboardKey.RIGHT) {
		p.vel.x += p.speed
	}
	if rl.IsKeyDown(rl.KeyboardKey.LEFT) {
		p.vel.x -= p.speed
	}
	if rl.IsKeyDown(rl.KeyboardKey.UP) {
		p.vel.y -= p.speed
	}
	if rl.IsKeyDown(rl.KeyboardKey.DOWN) {
		p.vel.y += p.speed
	}

	if rl.IsKeyPressed(rl.KeyboardKey.TAB) {
		switch p.weapon {
		case .Turret:
			p.weapon = .Wall
		case .Wall:
			p.weapon = .Turret
		}
	}

	p.weapon_cooldown -= 1

	if rl.IsKeyDown(rl.KeyboardKey.SPACE) && p.weapon_cooldown < 0 {
		switch p.weapon {
		case .Turret:
    		p.weapon_cooldown = 120
    		append(&s.turrets, Auto_Turret{
    			pos = p.pos,
    			size = TURRET_SIZE,
    			range = 128,
    			fire_rate = 30,
    		})
    	case .Wall:
		p.weapon_cooldown = 2
    		append(&s.walls, Wall{
    			max_hp = 10,
    			hp = 10,
    			pos = p.pos,
    			size = WALL_SIZE,
    		})
		}
	}
}

// dir returns the normalized distance between two points.
// TODO: handle more than just 8 directions.
dir :: proc(a, b: rl.Vector2) -> rl.Vector2 {
	d := dist(a, b)
	out := rl.Vector2{0, 0}
	if d.x < 0 {
    	out.x = -1
	}
	if d.x > 0 {
    	out.x = 1
	}
	if d.y < 0 {
    	out.y = -1
	}
	if d.y > 0 {
    	out.y = 1
	}
	return out
}

dist :: proc(a, b: rl.Vector2) -> rl.Vector2 {
	return a - b
}

abs_dist :: proc(a, b: rl.Vector2) -> rl.Vector2 {
	d := a - b
	return rl.Vector2{
		math.abs(d.x),
		math.abs(d.y),
	}
}

update_enemies :: proc(s: ^State) {

	if s.ticks % 120 == 0 {
        en := Enemy{
            max_hp = 3,
            hp = 3,
            mood = .Idle,
            speed = 1,
            size = ENEMY_SIZE,
            awareness = 256,
			pos = rl.Vector2{
                f32(rl.GetRandomValue(0, i32(s.dimensions.x))),
                f32(rl.GetRandomValue(0, i32(s.dimensions.y))),
			},
		}
		append(&s.enemies, en)
	}
	for en, ii in &s.enemies {
		update_enemy(s, &en)
		if en.hp <= 0 {
			ordered_remove(&s.enemies, ii)
		}
	}
}

update_enemy :: proc(s: ^State, en: ^Enemy) {
	en.vel = rl.Vector2{}

	update_mood(s, en)

	switch en.mood {
	case .Agro:
		// TODO:
		// hunt down player
		en.vel += dir(s.player, en) * en.speed
	case .Idle:
		// passively move around or be still
    	en.ticks_since_last_idle_change += 1
    	if en.ticks_since_last_idle_change > 30 {
        	en.ticks_since_last_idle_change = 0
        	en.idle_vel = rl.Vector2{}
			en.idle_vel += rl.Vector2{f32(rl.GetRandomValue(-1, 1)), f32(rl.GetRandomValue(-1, 1))}
    	}

    	en.vel += en.idle_vel
	}

	en.pos += en.vel

	for w in s.walls {
		if rl.CheckCollisionBoxes(get_box(w), get_box(en)) {
    		// FIXME: de-embed only by nearest axis
			d := dist(w, en)
			if math.abs(d.x) < math.abs(d.y) {
				en.pos.x -= d.x
			} else if math.abs(d.y) < math.abs(d.x) {
				en.pos.y -= d.y
			} else {
				en.pos -= d
			}
		}
	}
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
	for b, ii in &s.bullets {
    	update_bullet(s, &b)
    	if b.destroyed {
    		ordered_remove(&s.bullets, ii)
    	}
	}
}

update_bullet :: proc(s: ^State, b: ^Bullet) {
	b.pos += b.vel * b.speed
	// TODO: check & handle collisions with enemy.
	for en in &s.enemies {
		box := rl.BoundingBox{
			min = rl.Vector3{en.x-en.size/2, en.y-en.size/2, 0},
			max = rl.Vector3{en.x+en.size/2, en.y+en.size/2, 0},
		}
		center := rl.Vector3{b.x, b.y, 0}
		if rl.CheckCollisionBoxSphere(box, center, b.size) {
			en.hp -= 1
			b.destroyed = true
		}
	}
}

update_turrets :: proc(s: ^State) {
	for en in &s.turrets {
    	update_turret(s, &en)
	}
}

update_turret :: proc(s: ^State, t: ^Auto_Turret) {
	// aquire target
	// find closest enemy in range, and shoot at it.

	acquire_target(s, t)

	t.fire_cooldown -= 1

	if t.has_target {
    	if t.fire_cooldown <= 0 {
    		t.fire_cooldown = t.fire_rate
    		append(&s.bullets, Bullet{
    			pos = t.pos,
    			vel = dir(t.target, t.pos),
    			size = 4,
    			speed = 1,
    		})
    	}
	}
}

acquire_target :: proc(s: ^State, t: ^Auto_Turret) {
    t.target = rl.Vector2{}

	targets := [dynamic]rl.Vector2{}
	defer delete(targets)

	for en in s.enemies {
		if in_range(t, en, t.range) {
			append(&targets, en.pos)
		}
	}

	// FIXME: not sure if this works as expected.
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
	half_sz := s.player.size/2
    rl.DrawRectangle(i32(s.player.x-half_sz), i32(s.player.y-half_sz), i32(s.player.size), i32(s.player.size), rl.GREEN)
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
	col = rl.ColorAlpha(col, f32(255*en.hp/en.max_hp))

	half_sz := en.size/2
	rl.DrawRectangle(i32(en.x-half_sz), i32(en.y-half_sz), i32(en.size), i32(en.size), col)

	if s.debug {
    	// Draw agro radius.
    	rl.DrawCircleLines(i32(en.x), i32(en.y), en.awareness, rl.PURPLE)
	}
}

draw_bullet :: proc(s: ^State, en: Bullet) {
	rl.DrawCircle(i32(en.x), i32(en.y), en.size, rl.ORANGE)
}

draw_turret :: proc(s: ^State, en: Auto_Turret) {
	half_sz := en.size/2
	rl.DrawRectangle(i32(en.x-half_sz), i32(en.y-half_sz), i32(en.size), i32(en.size), rl.GRAY)

	if en.has_target && s.debug {
    	rl.DrawLine(i32(en.x), i32(en.y), i32(en.target.x), i32(en.target.y), rl.LIGHTGRAY)
	}
}


draw_walls :: proc(s: ^State) {
	for w in &s.walls {
		draw_wall(s, w)
	}
}

draw_wall :: proc(s: ^State, en: Wall) {
	half_sz := en.size/2
	rl.DrawRectangle(i32(en.x-half_sz), i32(en.y-half_sz), i32(en.size), i32(en.size), rl.DARKGRAY)
}

in_range :: proc(a, b: rl.Vector2, range: f32) -> bool {
	d := abs_dist(a, b)
	if d.x <= range && d.y <= range {
    	return true
	}
	return false
}

get_box :: proc(en: Entity) -> rl.BoundingBox {
	return rl.BoundingBox{
		min = rl.Vector3{en.pos.x - en.size/2, en.pos.y - en.size/2, 0},
		max = rl.Vector3{en.pos.x + en.size/2, en.pos.y + en.size/2, 0},
	}
}
