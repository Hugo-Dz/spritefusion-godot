@tool
extends VBoxContainer

const API_BASE_URL := "https://www.spritefusion.com"
const SESSION_PATH := "user://spritefusion/session.cfg"
const SESSION_DIR := "user://spritefusion"
const ASSET_REGISTRY_PATH := "user://spritefusion/assets.json"
const OUTPUT_DIR := "res://spritefusion/generated"
const SPRITEFRAMES_ANIMATION_NAME := "default"
const CONTENT_MIN_WIDTH := 220.0
const JSON_REQUEST_TIMEOUT_SECONDS := 30.0
const GENERATION_REQUEST_TIMEOUT_SECONDS := 600.0
const DOWNLOAD_REQUEST_TIMEOUT_SECONDS := 120.0
const GENERATION_SIZES := [64, 32, 16]

var _session: Dictionary = {}
var _asset_registry: Dictionary = {}
var _content: VBoxContainer
var _status_label: Label
var _poll_timer: Timer
var _pending_device_code := ""
var _pending_verification_url := ""
var _pending_user_code := ""
var _poll_interval := 5
var _after_refresh: Callable
var _prompt_input: TextEdit
var _size_input: OptionButton
var _animation_prompt_input: TextEdit
var _generate_button: Button
var _image_asset_input: OptionButton
var _image_asset_preview: TextureRect
var _image_asset_paths: Array = []
var _animate_button: Button
var _pricing_button: Button
var _scan_requested := false
var _navigate_after_scan := ""

func _ready() -> void:
	set_process(false)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_load_session()
	_load_asset_registry()
	_build_shell()
	_render()


func _exit_tree() -> void:
	if _poll_timer:
		_poll_timer.stop()


## scan() is only safe from normal main-loop flow, not from HTTPRequest's
## deferred callbacks. Route it through _process, which is a safe context
## by construction. Fire-and-forget: nothing in the plugin waits on it —
## the plugin's own outputs (.res/.tres) don't go through the import
## pipeline; the scan only makes new files visible in the FileSystem dock.
func _request_filesystem_scan(navigate_to := "") -> void:
	if navigate_to != "":
		_navigate_after_scan = navigate_to
	_scan_requested = true
	set_process(true)


func _process(_delta: float) -> void:
	set_process(false)
	if not _scan_requested:
		return

	var fs := EditorInterface.get_resource_filesystem()
	if fs.is_scanning():
		set_process(true)  # retry next frame
		return

	_scan_requested = false
	if _navigate_after_scan != "":
		var target := _navigate_after_scan
		_navigate_after_scan = ""
		fs.filesystem_changed.connect(
			func() -> void: EditorInterface.get_file_system_dock().navigate_to_path(target),
			CONNECT_ONE_SHOT
		)
	fs.scan()


func _build_shell() -> void:
	var scroll_container := ScrollContainer.new()
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll_container)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.custom_minimum_size = Vector2(CONTENT_MIN_WIDTH, 0)
	_content.add_theme_constant_override("separation", 8)
	scroll_container.add_child(_content)

	_poll_timer = Timer.new()
	_poll_timer.one_shot = true
	_poll_timer.timeout.connect(_poll_device_token)
	add_child(_poll_timer)


func _render() -> void:
	# Preserve user input across rebuilds.
	var prompt_text := _prompt_input.text if is_instance_valid(_prompt_input) else ""
	var selected_size := 64
	if is_instance_valid(_size_input) and _size_input.selected >= 0:
		selected_size = _size_input.get_selected_id()
	var animation_prompt_text := _animation_prompt_input.text if is_instance_valid(_animation_prompt_input) else ""
	var selected_asset_path := ""
	if is_instance_valid(_image_asset_input) and not _image_asset_paths.is_empty():
		var selected_index := _image_asset_input.selected
		if selected_index >= 0 and selected_index < _image_asset_paths.size():
			selected_asset_path = _image_asset_paths[selected_index]

	_clear_content()
	_add_status_area()

	if _is_connected():
		_render_connected(prompt_text, selected_size, animation_prompt_text, selected_asset_path)
	elif _pending_device_code != "":
		_render_connecting()
	else:
		_render_disconnected()


func _clear_content() -> void:
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()


func _add_status_area() -> void:
	_status_label = Label.new()
	_status_label.custom_minimum_size = Vector2(CONTENT_MIN_WIDTH, 0)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = ""
	_status_label.visible = false
	_content.add_child(_status_label)

	_pricing_button = Button.new()
	_pricing_button.text = "View plans"
	_pricing_button.visible = false
	_pricing_button.pressed.connect(_open_pricing)
	_content.add_child(_pricing_button)


func _render_disconnected() -> void:
	_set_status("Connect your Sprite Fusion account to generate pixel art.")

	var connect_button := Button.new()
	connect_button.text = "Connect"
	connect_button.pressed.connect(_start_device_flow)
	_content.add_child(connect_button)


func _render_connecting() -> void:
	_set_status("Approve this code in your browser.")

	var code_label := Label.new()
	code_label.text = _pending_user_code
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_label.add_theme_font_size_override("font_size", 24)
	_content.add_child(code_label)

	var open_button := Button.new()
	open_button.text = "Open connection page"
	open_button.pressed.connect(func() -> void:
		if _pending_verification_url != "":
			OS.shell_open(_pending_verification_url)
	)
	_content.add_child(open_button)

	var cancel_button := Button.new()
	cancel_button.text = "Cancel"
	cancel_button.pressed.connect(_cancel_device_flow)
	_content.add_child(cancel_button)


func _render_connected(prompt_text := "", selected_size := 64, animation_prompt_text := "", selected_asset_path := "") -> void:
	var email := Label.new()
	email.custom_minimum_size = Vector2(CONTENT_MIN_WIDTH, 0)
	email.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	email.text = "Connected as %s" % _session.get("email", "Sprite Fusion user")
	email.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(email)

	_add_section_label("Generate")

	_prompt_input = TextEdit.new()
	_prompt_input.placeholder_text = "Prompt"
	_prompt_input.custom_minimum_size = Vector2(0, 96)
	_prompt_input.text = prompt_text
	_content.add_child(_prompt_input)

	_size_input = OptionButton.new()
	for size in GENERATION_SIZES:
		_size_input.add_item("%sx%s" % [size, size], size)
	var selected_size_index := GENERATION_SIZES.find(selected_size)
	_size_input.select(max(0, selected_size_index))
	_content.add_child(_with_label("Size", _size_input))

	_generate_button = Button.new()
	_generate_button.text = "Generate"
	_generate_button.pressed.connect(_handle_generate_pressed)
	_content.add_child(_generate_button)

	_add_section_label("Animate", 16)

	_image_asset_input = OptionButton.new()
	_image_asset_paths = _get_image_asset_paths()
	if _image_asset_paths.is_empty():
		_image_asset_input.add_item("Generate an image first")
		_image_asset_input.disabled = true
	else:
		for index in _image_asset_paths.size():
			var asset_path: String = _image_asset_paths[index]
			var asset_metadata: Dictionary = _asset_registry.get(asset_path, {})
			var preview_texture := _load_texture(asset_path, 32)
			var option_label := "%s - %02d" % [_format_asset_option(asset_metadata), index + 1]
			if preview_texture:
				_image_asset_input.add_icon_item(preview_texture, option_label)
			else:
				_image_asset_input.add_item(option_label)
		_image_asset_input.item_selected.connect(_handle_source_image_selected)

		var restored_index := _image_asset_paths.find(selected_asset_path)
		if restored_index >= 0:
			_image_asset_input.select(restored_index)
	_content.add_child(_with_label("Source image", _image_asset_input))

	_image_asset_preview = TextureRect.new()
	_image_asset_preview.custom_minimum_size = Vector2(CONTENT_MIN_WIDTH, 120)
	_image_asset_preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_image_asset_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image_asset_preview.visible = not _image_asset_paths.is_empty()
	_content.add_child(_image_asset_preview)
	if not _image_asset_paths.is_empty():
		var preview_index = max(0, _image_asset_input.selected)
		_set_source_image_preview(_image_asset_paths[preview_index])

	_animation_prompt_input = TextEdit.new()
	_animation_prompt_input.placeholder_text = "Prompt"
	_animation_prompt_input.custom_minimum_size = Vector2(0, 96)
	_animation_prompt_input.text = animation_prompt_text
	_content.add_child(_animation_prompt_input)

	_animate_button = Button.new()
	_animate_button.text = "Animate"
	_animate_button.disabled = _image_asset_paths.is_empty()
	_animate_button.pressed.connect(_handle_animate_pressed)
	_content.add_child(_animate_button)

	var logout_button := Button.new()
	logout_button.text = "Logout"
	logout_button.pressed.connect(_logout)
	_content.add_child(logout_button)


func _add_section_label(text: String, top_spacing := 0) -> void:
	if top_spacing > 0:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, top_spacing)
		_content.add_child(spacer)

	var label := Label.new()
	label.text = text
	var base_font_size = max(get_theme_font_size("font_size", "Label"), get_theme_font_size("font_size", "Button"))
	label.add_theme_font_size_override("font_size", base_font_size + 2)
	_content.add_child(label)


func _with_label(label_text: String, control: Control) -> VBoxContainer:
	var wrapper := VBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	wrapper.add_child(label)
	wrapper.add_child(control)
	return wrapper


func _set_status(message: String, show_pricing := false) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = message
		_status_label.visible = message != ""
	if is_instance_valid(_pricing_button):
		_pricing_button.visible = show_pricing


func _set_generate_button_loading(is_loading: bool) -> void:
	if not is_instance_valid(_generate_button):
		return

	_generate_button.disabled = is_loading
	_generate_button.text = "Generating..." if is_loading else "Generate"


func _set_animate_button_loading(is_loading: bool) -> void:
	if not is_instance_valid(_animate_button):
		return

	_animate_button.disabled = is_loading
	_animate_button.text = "Animating..." if is_loading else "Animate"


func _is_connected() -> bool:
	return _session.get("access_token", "") != "" and _session.get("refresh_token", "") != ""


func _start_device_flow() -> void:
	_set_status("Creating connection code...")
	if not _post_json("/api/integrations/auth/device/start?integration=godot", {}, Callable(self, "_on_device_start_completed")):
		_set_status("Unable to start connection.")


func _on_device_start_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_set_status("Unable to start connection.")
		return

	var data := _parse_json_body(body)
	_pending_device_code = data.get("deviceCode", "")
	_pending_verification_url = data.get("verificationUriComplete", "")
	_pending_user_code = data.get("userCode", "")
	_poll_interval = int(data.get("interval", 5))
	_render()
	_poll_timer.start(_poll_interval)


func _poll_device_token() -> void:
	if _pending_device_code == "":
		return

	if not _post_json(
		"/api/integrations/auth/device/token",
		{ "deviceCode": _pending_device_code },
		Callable(self, "_on_device_token_completed")
	):
		_set_status("Connection check failed. Retrying...")
		_poll_timer.start(_poll_interval)


func _on_device_token_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS:
		_set_status("Connection check failed. Retrying...")
		_poll_timer.start(_poll_interval)
		return

	var data := _parse_json_body(body)
	if response_code >= 200 and response_code < 300:
		_save_session(data)
		_pending_device_code = ""
		_pending_verification_url = ""
		_pending_user_code = ""
		_poll_timer.stop()
		_render()
		return

	var error := str(data.get("error", "authorization_pending"))
	if error == "authorization_pending":
		_set_status("Waiting for approval...")
		_poll_timer.start(_poll_interval)
	elif error == "slow_down":
		_poll_interval += 5
		_set_status("Waiting before polling again...")
		_poll_timer.start(_poll_interval)
	elif error == "expired_token":
		_cancel_device_flow()
		_set_status("Connection code expired.")
	elif error == "access_denied":
		_cancel_device_flow()
		_set_status("Connection cancelled.")
	else:
		_cancel_device_flow()
		_set_status("Unable to connect.")


func _cancel_device_flow() -> void:
	_pending_device_code = ""
	_pending_verification_url = ""
	_pending_user_code = ""
	if _poll_timer:
		_poll_timer.stop()
	_render()


func _handle_generate_pressed() -> void:
	var prompt := _prompt_input.text.strip_edges()
	if prompt == "":
		_set_status("Prompt is required.")
		return

	var payload := {
		"prompt": prompt,
		"size": _size_input.get_selected_id(),
	}

	if _is_session_expiring():
		_set_generate_button_loading(true)
		_set_status("")
		_refresh_session(Callable(self, "_send_generate_request").bind(payload, false))
	else:
		_send_generate_request(payload, false)


func _handle_animate_pressed() -> void:
	var source_asset := _get_selected_image_asset()
	if source_asset.is_empty():
		_set_status("Generate an image first.")
		return

	var prompt := _animation_prompt_input.text.strip_edges()
	if prompt == "":
		_set_status("Animation prompt is required.")
		return

	var image_data_url := _read_png_data_url(str(source_asset.get("path", "")))
	if image_data_url == "":
		_set_status("Unable to read source image.")
		return

	var payload := {
		"prompt": prompt,
		"imageDataUrl": image_data_url,
		"sourceImageAssetId": source_asset.get("assetId", ""),
		"outputFrames": 8,
		"colors": 24,
	}

	if _is_session_expiring():
		_set_animate_button_loading(true)
		_set_status("")
		_refresh_session(Callable(self, "_send_animation_request").bind(payload, false))
	else:
		_send_animation_request(payload, false)


func _send_generate_request(payload: Dictionary, did_refresh: bool) -> void:
	_set_generate_button_loading(true)
	_set_status("")
	var did_start_request := _post_bearer_json(
		"/api/pixel-art-generator/image",
		payload,
		_session.get("access_token", ""),
		Callable(self, "_on_generate_completed"),
		[payload, did_refresh]
	)
	if not did_start_request:
		_set_generate_button_loading(false)


func _send_animation_request(payload: Dictionary, did_refresh: bool) -> void:
	_set_animate_button_loading(true)
	_set_status("")
	var did_start_request := _post_bearer_json(
		"/api/pixel-art-generator/animation",
		payload,
		_session.get("access_token", ""),
		Callable(self, "_on_animation_completed"),
		[payload, did_refresh]
	)
	if not did_start_request:
		_set_animate_button_loading(false)


func _on_generate_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	payload: Dictionary,
	did_refresh: bool,
	request: HTTPRequest
) -> void:
	request.queue_free()

	if response_code == 401 and not did_refresh and _session.get("refresh_token", "") != "":
		_refresh_session(Callable(self, "_send_generate_request").bind(payload, true))
		return

	if result != HTTPRequest.RESULT_SUCCESS:
		_set_generate_button_loading(false)
		_set_status("Generation request failed.")
		return

	if response_code < 200 or response_code >= 300:
		_set_generate_button_loading(false)
		var error_data := _parse_json_body(body)
		_set_generation_error_status(error_data, response_code)
		return

	var events := _parse_event_stream(body.get_string_from_utf8())
	var last_event: Dictionary = events[-1] if not events.is_empty() else {}
	if last_event.get("type", "") != "succeeded":
		_set_generate_button_loading(false)
		_set_generation_error_status(last_event)
		return

	var assets: Array = []
	var asset_indexes_by_id := {}
	for generation_event in events:
		var event_assets = generation_event.get("assets", [])
		if typeof(event_assets) != TYPE_ARRAY:
			continue
		for asset in event_assets:
			if typeof(asset) != TYPE_DICTIONARY:
				continue
			var asset_id := str(asset.get("id", ""))
			if asset_id == "":
				continue
			if asset_indexes_by_id.has(asset_id):
				assets[asset_indexes_by_id[asset_id]] = asset
			else:
				asset_indexes_by_id[asset_id] = assets.size()
				assets.append(asset)
	if assets.is_empty():
		_set_generate_button_loading(false)
		_set_status("Generation returned no image.")
		return

	var downloadable_assets := _get_downloadable_image_assets(assets)
	if downloadable_assets.is_empty():
		_set_generate_button_loading(false)
		_set_status("Generated images have no download URL.")
		return

	_download_image_assets(downloadable_assets, str(payload.get("prompt", "sprite-fusion")))


func _on_animation_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	payload: Dictionary,
	did_refresh: bool,
	request: HTTPRequest
) -> void:
	request.queue_free()

	if response_code == 401 and not did_refresh and _session.get("refresh_token", "") != "":
		_refresh_session(Callable(self, "_send_animation_request").bind(payload, true))
		return

	if result != HTTPRequest.RESULT_SUCCESS:
		_set_animate_button_loading(false)
		_set_status("Animation request failed.")
		return

	if response_code < 200 or response_code >= 300:
		_set_animate_button_loading(false)
		var error_data := _parse_json_body(body)
		_set_generation_error_status(error_data, response_code)
		return

	var last_event := _consume_event_stream(body.get_string_from_utf8())
	if last_event.get("type", "") != "success":
		_set_animate_button_loading(false)
		_set_generation_error_status(last_event)
		return

	var asset: Dictionary = last_event.get("asset", {})
	var asset_id := str(asset.get("id", ""))
	if asset_id == "":
		_set_animate_button_loading(false)
		_set_status("Animation returned no asset.")
		return

	_download_animation_spritesheet(asset, str(payload.get("prompt", "sprite-fusion")), false)


func _set_generation_error_status(error_data: Dictionary, response_code := 0) -> void:
	if _needs_active_plan(error_data, response_code):
		_set_status("You need an active plan", true)
		return

	_set_status(_format_generation_error(error_data))


func _needs_active_plan(error_data: Dictionary, response_code: int) -> bool:
	if response_code != 402:
		return false

	var credits = error_data.get("credits", null)
	if typeof(credits) == TYPE_DICTIONARY and str(credits.get("subscriptionPlan", "")) == "none":
		return true

	return str(error_data.get("error", "")) == "An active subscription is required."


func _format_generation_error(error_data: Dictionary) -> String:
	var message := str(error_data.get("error", "Generation failed."))
	var credits = error_data.get("credits", null)
	if typeof(credits) == TYPE_DICTIONARY and credits.has("credits"):
		return "%s Credits: %s." % [message, str(credits.get("credits", 0))]
	return message


func _open_pricing() -> void:
	OS.shell_open(API_BASE_URL + "/pixel-art-generator#pricing")


func _parse_event_stream(stream_text: String) -> Array:
	var events := []
	var normalized := stream_text.replace("\r\n", "\n")
	for raw_event in normalized.split("\n\n", false):
		var data_lines := []
		for line in raw_event.split("\n", false):
			if line.begins_with("data:"):
				data_lines.append(line.substr(5).strip_edges())
		if data_lines.is_empty():
			continue

		var parsed = JSON.parse_string("\n".join(data_lines))
		if typeof(parsed) != TYPE_DICTIONARY:
			continue

		events.append(parsed)

	return events


func _consume_event_stream(stream_text: String) -> Dictionary:
	var events := _parse_event_stream(stream_text)

	return events[-1] if not events.is_empty() else {}


func _get_downloadable_image_assets(assets: Array) -> Array:
	var downloadable_assets := []
	for asset in assets:
		if typeof(asset) != TYPE_DICTIONARY:
			continue
		if str(asset.get("assetUrl", "")) == "":
			continue
		downloadable_assets.append(asset)
	return downloadable_assets


func _download_image_assets(assets: Array, prompt: String) -> void:
	_download_next_image_asset(assets, prompt, 0, [])


func _download_next_image_asset(assets: Array, prompt: String, index: int, saved_paths: Array) -> void:
	if index >= assets.size():
		_finish_image_downloads(saved_paths)
		return

	var asset: Dictionary = assets[index]
	var asset_url := str(asset.get("assetUrl", ""))
	if not _download_asset(asset_url, Callable(self, "_on_image_asset_download_completed"), [assets, prompt, index, saved_paths]):
		_set_generate_button_loading(false)
		_set_status("Unable to download generated image.")


func _finish_image_downloads(saved_paths: Array) -> void:
	_set_generate_button_loading(false)
	_render()
	if not saved_paths.is_empty():
		_request_filesystem_scan(str(saved_paths[0]))
	_set_status("")


func _on_image_asset_download_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	assets: Array,
	prompt: String,
	index: int,
	saved_paths: Array,
	request: HTTPRequest
) -> void:
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_set_generate_button_loading(false)
		_set_status("Unable to download generated image.")
		return

	var asset: Dictionary = assets[index]
	var path := _get_output_path(prompt, "png", "", index)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		_set_generate_button_loading(false)
		_set_status("Unable to save generated image.")
		return

	file.store_buffer(body)
	file.close()
	_register_asset(path, asset, "image")
	saved_paths.append(path)
	_download_next_image_asset(assets, prompt, index + 1, saved_paths)


func _download_animation_spritesheet(asset: Dictionary, prompt: String, did_refresh: bool) -> void:
	var asset_id := str(asset.get("id", ""))
	var path := "%s/api/pixel-art-generator/assets/%s/file?file=spritesheet" % [API_BASE_URL, asset_id.uri_encode()]
	if not _download_bearer_asset(path, _session.get("access_token", ""), Callable(self, "_on_animation_spritesheet_download_completed"), [asset, prompt, did_refresh]):
		_set_animate_button_loading(false)
		_set_status("Unable to download animation spritesheet.")


func _on_animation_spritesheet_download_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	asset: Dictionary,
	prompt: String,
	did_refresh: bool,
	request: HTTPRequest
) -> void:
	request.queue_free()
	if response_code == 401 and not did_refresh and _session.get("refresh_token", "") != "":
		_refresh_session(Callable(self, "_download_animation_spritesheet").bind(asset, prompt, true))
		return

	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_set_animate_button_loading(false)
		_set_status("Unable to download animation spritesheet.")
		return

	var image := Image.new()
	if image.load_png_from_buffer(body) != OK:
		_set_animate_button_loading(false)
		_set_status("Animation returned invalid image data.")
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))

	# Reference PNG for the user. Imported lazily by the fire-and-forget
	# scan; nothing of ours depends on it.
	var spritesheet_path := _get_output_path(prompt, "png", "spritesheet")
	var png_file := FileAccess.open(spritesheet_path, FileAccess.WRITE)
	if png_file:
		png_file.store_buffer(body)
		png_file.close()

	# The texture the SpriteFrames actually uses: PortableCompressedTexture2D
	# saved as .res — a real resource, never touches the import pipeline,
	# valid the instant it's written. Lossless keeps pixel art exact.
	var texture := PortableCompressedTexture2D.new()
	texture.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
	var texture_path := spritesheet_path.get_basename() + "_texture.res"
	if ResourceSaver.save(texture, texture_path) != OK:
		_set_animate_button_loading(false)
		_set_status("Unable to save spritesheet texture.")
		return
	texture.take_over_path(texture_path)  # .tres references it by path, not embedded

	var sprite_frames_path := _get_sprite_frames_path(spritesheet_path)
	if not _create_sprite_frames_resource(texture, sprite_frames_path, asset):
		_set_animate_button_loading(false)
		_set_status("Unable to create SpriteFrames resource.")
		return

	_register_asset(spritesheet_path, asset, "animation", {
		"spriteFramesPath": sprite_frames_path,
		"texturePath": texture_path,
	})
	_render()
	_request_filesystem_scan(sprite_frames_path)
	_set_animate_button_loading(false)
	_set_status("")


func _create_sprite_frames_resource(texture: Texture2D, sprite_frames_path: String, asset: Dictionary) -> bool:
	var frame_width := int(asset.get("width", 0))
	var frame_height := int(asset.get("height", 0))
	var frame_count := int(asset.get("frameCount", 0))
	if frame_width <= 0 or frame_height <= 0 or frame_count <= 0:
		return false

	var sprite_frames := SpriteFrames.new()
	sprite_frames.set_animation_loop(SPRITEFRAMES_ANIMATION_NAME, true)
	sprite_frames.set_animation_speed(SPRITEFRAMES_ANIMATION_NAME, float(asset.get("fps", 8)))
	for frame_index in range(frame_count):
		var frame_texture := AtlasTexture.new()
		frame_texture.atlas = texture
		frame_texture.region = Rect2(frame_width * frame_index, 0, frame_width, frame_height)
		sprite_frames.add_frame(SPRITEFRAMES_ANIMATION_NAME, frame_texture)

	return ResourceSaver.save(sprite_frames, sprite_frames_path) == OK


func _refresh_session(after_refresh: Callable) -> void:
	if _session.get("refresh_token", "") == "":
		_logout()
		return

	_after_refresh = after_refresh
	_set_status("")
	var did_start_request := _post_json(
		"/api/integrations/auth/refresh",
		{ "refresh_token": _session.get("refresh_token", "") },
		Callable(self, "_on_refresh_completed")
	)
	if not did_start_request:
		_set_generate_button_loading(false)
		_set_animate_button_loading(false)


func _on_refresh_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_set_generate_button_loading(false)
		_set_animate_button_loading(false)
		_logout()
		_set_status("Session expired. Connect again.")
		return

	_save_session(_parse_json_body(body))
	var callback := _after_refresh
	_after_refresh = Callable()
	if callback.is_valid():
		callback.call()


func _is_session_expiring() -> bool:
	var expires_at := int(_session.get("expires_at", 0))
	return expires_at <= int(Time.get_unix_time_from_system()) + 60


func _get_image_asset_paths() -> Array:
	var paths := []
	for path in _asset_registry.keys():
		var asset_metadata = _asset_registry.get(path, {})
		if typeof(asset_metadata) != TYPE_DICTIONARY:
			continue
		if asset_metadata.get("type", "") != "image":
			continue
		if not FileAccess.file_exists(path):
			continue
		paths.append(path)

	paths.sort()
	return paths


func _format_asset_option(asset_metadata: Dictionary) -> String:
	var prompt := str(asset_metadata.get("prompt", "Generated image")).strip_edges()
	if prompt == "":
		prompt = "Generated image"
	if prompt.length() > 36:
		prompt = prompt.substr(0, 33) + "..."
	return prompt


func _handle_source_image_selected(index: int) -> void:
	if index < 0 or index >= _image_asset_paths.size():
		return

	_set_source_image_preview(_image_asset_paths[index])


func _set_source_image_preview(path: String) -> void:
	if not is_instance_valid(_image_asset_preview):
		return

	_image_asset_preview.texture = _load_texture(path)
	_image_asset_preview.visible = _image_asset_preview.texture != null


func _load_texture(path: String, max_size := 0) -> Texture2D:
	if path == "" or not FileAccess.file_exists(path):
		return null

	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return null
	if max_size > 0:
		var largest_side = max(image.get_width(), image.get_height())
		if largest_side > max_size:
			var scale := float(max_size) / float(largest_side)
			image.resize(max(1, int(image.get_width() * scale)), max(1, int(image.get_height() * scale)), Image.INTERPOLATE_NEAREST)

	return ImageTexture.create_from_image(image)


func _get_selected_image_asset() -> Dictionary:
	if not is_instance_valid(_image_asset_input):
		return {}
	if _image_asset_paths.is_empty():
		return {}

	var selected_index := _image_asset_input.selected
	if selected_index < 0 or selected_index >= _image_asset_paths.size():
		return {}

	var path: String = _image_asset_paths[selected_index]
	var asset_metadata = _asset_registry.get(path, {})
	if typeof(asset_metadata) != TYPE_DICTIONARY:
		return {}

	asset_metadata["path"] = path
	return asset_metadata


func _read_png_data_url(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""

	var bytes := file.get_buffer(file.get_length())
	file.close()
	return "data:image/png;base64," + Marshalls.raw_to_base64(bytes)


func _register_asset(path: String, asset: Dictionary, local_type: String, extra := {}) -> void:
	var asset_metadata := {
		"type": local_type,
		"assetId": asset.get("id", ""),
		"assetType": asset.get("type", ""),
		"assetUrl": asset.get("assetUrl", ""),
		"prompt": asset.get("prompt", ""),
		"width": asset.get("width", 0),
		"height": asset.get("height", 0),
		"createdAt": asset.get("createdAt", ""),
		"updatedAt": asset.get("updatedAt", ""),
		"savedAt": Time.get_datetime_string_from_system(true),
	}

	if asset.has("frameCount"):
		asset_metadata["frameCount"] = asset.get("frameCount", 0)
	if asset.has("fps"):
		asset_metadata["fps"] = asset.get("fps", 8)
	if asset.has("sourceImageUrl"):
		asset_metadata["sourceImageUrl"] = asset.get("sourceImageUrl", "")
	for key in extra.keys():
		asset_metadata[key] = extra[key]

	_asset_registry[path] = asset_metadata
	_save_asset_registry()


func _load_asset_registry() -> void:
	if not FileAccess.file_exists(ASSET_REGISTRY_PATH):
		return

	var file := FileAccess.open(ASSET_REGISTRY_PATH, FileAccess.READ)
	if not file:
		return

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) == TYPE_DICTIONARY:
		_asset_registry = parsed


func _save_asset_registry() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SESSION_DIR))
	var file := FileAccess.open(ASSET_REGISTRY_PATH, FileAccess.WRITE)
	if not file:
		return

	file.store_string(JSON.stringify(_asset_registry, "\t"))
	file.close()


func _save_session(data: Dictionary) -> void:
	var user = data.get("user", {})
	var email := str(_session.get("email", ""))
	if typeof(user) == TYPE_DICTIONARY:
		email = str(user.get("email", email))

	_session = {
		"access_token": data.get("access_token", ""),
		"refresh_token": data.get("refresh_token", ""),
		"expires_at": data.get("expires_at", 0),
		"token_type": data.get("token_type", "bearer"),
		"email": email,
	}

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SESSION_DIR))
	var config := ConfigFile.new()
	for key in _session.keys():
		config.set_value("session", key, _session[key])
	config.save(SESSION_PATH)


func _load_session() -> void:
	var config := ConfigFile.new()
	if config.load(SESSION_PATH) != OK:
		return

	_session = {
		"access_token": str(config.get_value("session", "access_token", "")),
		"refresh_token": str(config.get_value("session", "refresh_token", "")),
		"expires_at": int(config.get_value("session", "expires_at", 0)),
		"token_type": str(config.get_value("session", "token_type", "bearer")),
		"email": str(config.get_value("session", "email", "")),
	}


func _logout() -> void:
	_session = {}
	if FileAccess.file_exists(SESSION_PATH):
		DirAccess.remove_absolute(SESSION_PATH)
	_render()


func _post_json(path: String, payload: Dictionary, callback: Callable, extra_args: Array = []) -> bool:
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	return _post_json_request(API_BASE_URL + path, payload, headers, callback, extra_args, JSON_REQUEST_TIMEOUT_SECONDS)


func _post_bearer_json(path: String, payload: Dictionary, bearer_token: String, callback: Callable, extra_args: Array = []) -> bool:
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json", "Authorization: Bearer " + bearer_token])
	return _post_json_request(API_BASE_URL + path, payload, headers, callback, extra_args, GENERATION_REQUEST_TIMEOUT_SECONDS)


func _download_asset(url: String, callback: Callable, extra_args: Array = []) -> bool:
	return _send_download_request(url, PackedStringArray(), callback, extra_args, DOWNLOAD_REQUEST_TIMEOUT_SECONDS)


func _download_bearer_asset(url: String, bearer_token: String, callback: Callable, extra_args: Array = []) -> bool:
	return _send_download_request(url, PackedStringArray(["Authorization: Bearer " + bearer_token]), callback, extra_args, DOWNLOAD_REQUEST_TIMEOUT_SECONDS)


func _post_json_request(url: String, payload: Dictionary, headers: PackedStringArray, callback: Callable, extra_args: Array, timeout_seconds: float) -> bool:
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	add_child(request)
	request.request_completed.connect(callback.bindv(extra_args + [request]))

	var error := request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		request.queue_free()
		return false

	return true


func _send_download_request(url: String, headers: PackedStringArray, callback: Callable, extra_args: Array, timeout_seconds: float) -> bool:
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	add_child(request)
	request.request_completed.connect(callback.bindv(extra_args + [request]))

	var error := request.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		request.queue_free()
		return false

	return true


func _parse_json_body(body: PackedByteArray) -> Dictionary:
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func _get_output_path(prompt: String, extension := "png", suffix := "", index := -1) -> String:
	var file_name := _safe_file_name(prompt)
	if file_name == "":
		file_name = "sprite"
	if suffix != "":
		file_name = "%s_%s" % [file_name, suffix]
	if index >= 0:
		file_name = "%s_%s" % [file_name, index + 1]
	var timestamp := str(int(Time.get_unix_time_from_system()))
	return "%s/%s_%s.%s" % [OUTPUT_DIR, file_name, timestamp, extension]


func _get_sprite_frames_path(spritesheet_path: String) -> String:
	return spritesheet_path.get_basename() + ".tres"


func _safe_file_name(value: String) -> String:
	var output := ""
	for index in value.length():
		var character := value.substr(index, 1).to_lower()
		var is_letter := character >= "a" and character <= "z"
		var is_number := character >= "0" and character <= "9"
		if is_letter or is_number:
			output += character
		elif output.length() > 0 and not output.ends_with("_"):
			output += "_"
		if output.length() >= 40:
			break
	return output.trim_suffix("_")
