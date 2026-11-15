extends Node

# Autoload: AudioManager
# Plays sounds that must survive scene changes (e.g. UI sounds fired right before
# change_scene_to_file). Scene-local AudioStreamPlayers get freed with their scene,
# cutting playback off mid-sound. Sounds are organized by role so each category can
# have its own bus routing and pool.

const UI_SOUNDS := {
	"menu_move": preload("res://assets/audio/menumove.mp3"),
	"menu_start": preload("res://assets/audio/start.mp3"),
	"menu_lose": preload("res://assets/audio/losesound.mp3"),
}
const UI_POOL_SIZE := 4

var _ui_players: Array[AudioStreamPlayer] = []
var _ui_next := 0


func _ready() -> void:
	_init_ui_players()


func _init_ui_players() -> void:
	if not _ui_players.is_empty():
		return
	for i in UI_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = "SFX"
		add_child(player)
		_ui_players.append(player)


func play_ui(sound_name: String) -> void:
	var stream: AudioStream = UI_SOUNDS.get(sound_name)
	if stream == null:
		push_warning("AudioManager: unknown UI sound '%s'" % sound_name)
		return
	# Lazy init: play_ui can be called before _ready (e.g. by an earlier autoload).
	_init_ui_players()
	var player := _ui_players[_ui_next]
	_ui_next = (_ui_next + 1) % _ui_players.size()
	player.stream = stream
	player.play()
