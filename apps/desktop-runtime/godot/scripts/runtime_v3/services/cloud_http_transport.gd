extends RefCounted

## Shared Cloud HTTP transport policy. Godot HTTPRequest does not automatically
## consume HTTPS_PROXY on Windows, so corporate networks that require an
## outbound proxy otherwise fail before DNS/TLS with response_code=0.

static func configure_https_proxy(request: HTTPRequest) -> void:
	if not is_instance_valid(request):
		return
	var parsed := environment_https_proxy()
	if parsed.is_empty():
		return
	request.set_https_proxy(str(parsed["host"]), int(parsed["port"]))


static func environment_https_proxy() -> Dictionary:
	# OCP_HTTPS_PROXY is populated by the Windows launcher from either an
	# explicit process proxy or the current user's Windows Internet Settings.
	# Keep standard proxy environment variables as portable fallbacks for
	# non-Windows/dev launches.
	var raw := OS.get_environment("OCP_HTTPS_PROXY").strip_edges()
	if raw.is_empty():
		raw = OS.get_environment("HTTPS_PROXY").strip_edges()
	if raw.is_empty():
		raw = OS.get_environment("https_proxy").strip_edges()
	if raw.is_empty():
		raw = OS.get_environment("HTTP_PROXY").strip_edges()
	if raw.is_empty():
		raw = OS.get_environment("http_proxy").strip_edges()
	return parse_https_proxy(raw)


static func parse_https_proxy(raw_value: String) -> Dictionary:
	var raw := raw_value.strip_edges()
	if raw.is_empty() or raw.contains("@"):
		return {}
	var scheme := "http"
	var scheme_index := raw.find("://")
	if scheme_index >= 0:
		scheme = raw.substr(0, scheme_index).to_lower()
		if scheme not in ["http", "https"]:
			return {}
		raw = raw.substr(scheme_index + 3)
	var slash := raw.find("/")
	if slash >= 0:
		raw = raw.substr(0, slash)
	if raw.is_empty():
		return {}

	var host := ""
	var port := 80 if scheme == "http" else 443
	if raw.begins_with("["):
		var close := raw.find("]")
		if close <= 1:
			return {}
		host = raw.substr(1, close - 1)
		if close + 1 < raw.length():
			if raw.substr(close + 1, 1) != ":":
				return {}
			var port_text := raw.substr(close + 2)
			if not port_text.is_valid_int():
				return {}
			port = int(port_text)
	else:
		var colon := raw.rfind(":")
		if colon > 0:
			var port_text := raw.substr(colon + 1)
			if not port_text.is_valid_int():
				return {}
			host = raw.substr(0, colon)
			port = int(port_text)
		else:
			host = raw

	host = host.strip_edges()
	if host.is_empty() or port < 1 or port > 65535:
		return {}
	return {"host": host, "port": port}
