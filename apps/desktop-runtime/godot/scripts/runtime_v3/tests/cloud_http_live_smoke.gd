extends SceneTree

const Transport = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")
const TARGETS := [
	"http://127.0.0.1:5173/",
	"https://example.com/",
	"https://cpetxqbqyrtpppbicdbw.supabase.co/functions/v1/cloud-api/v1/health",
]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var all_completed := true
	for url in TARGETS:
		var request := HTTPRequest.new()
		request.timeout = 8.0
		Transport.configure_https_proxy(request)
		get_root().add_child(request)
		var state := {"done": false, "result": -1, "response": 0, "body": ""}
		request.request_completed.connect(func(result: int, response: int, _headers: PackedStringArray, body: PackedByteArray):
			state["result"] = result
			state["response"] = response
			state["body"] = body.get_string_from_utf8().left(120)
			state["done"] = true
		)
		var start_error := request.request(url, PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
		if start_error != OK:
			print("[CLOUD-HTTP-LIVE] url=", url, " start_error=", start_error)
			all_completed = false
			request.queue_free()
			continue
		for _step in range(100):
			if bool(state["done"]):
				break
			await create_timer(0.1).timeout
		print("[CLOUD-HTTP-LIVE] url=", url, " done=", state["done"], " result=", state["result"], " response=", state["response"], " body=", state["body"])
		if not bool(state["done"]):
			all_completed = false
		request.queue_free()
	quit(0 if all_completed else 1)
