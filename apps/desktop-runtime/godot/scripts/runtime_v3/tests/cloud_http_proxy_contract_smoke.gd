extends SceneTree

const Transport = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

func _initialize() -> void:
	var a := Transport.parse_https_proxy("http://proxy.example:8080")
	var b := Transport.parse_https_proxy("https://proxy.example")
	var c := Transport.parse_https_proxy("http://user:pass@proxy.example:8080")
	var d := Transport.parse_https_proxy("socks5://proxy.example:1080")
	var e := Transport.parse_https_proxy("http://[::1]:8888")
	var ok := a == {"host": "proxy.example", "port": 8080} \
		and b == {"host": "proxy.example", "port": 443} \
		and c.is_empty() \
		and d.is_empty() \
		and e == {"host": "::1", "port": 8888}
	print("[CLOUD-PROXY-CONTRACT] ok=", ok, " env_configured=", not Transport.environment_https_proxy().is_empty())
	quit(0 if ok else 1)
