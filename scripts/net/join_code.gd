class_name NetJoinCode
extends RefCounted
## Join codes (Netz). v1 = a typeable encoding of IPv4 + UDP port, NOT a secret and NOT an account:
## 6 bytes (4 IP + 2 port) -> 48 bits -> 10 Crockford base32 chars, shown as "GC-XXXXX-XXXXX" (legacy "DN-" codes still decode).
## Decoding is forgiving: case, spaces, dashes, missing prefix, O->0 and I/L->1 are accepted.
## With a relay or Steam later, a code becomes a room / lobby id instead (see DESIGN.md §4.3); the
## "kind" field of decode() keeps that door open.

const ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ" ## Crockford base32 (no I L O U)
const LEN := 10


static func prefix() -> String:
	return str(NetConfig.get_value("join_code.prefix", "GC"))


## "" if ip is not a dotted IPv4 or the port is out of range.
static func encode(ip: String, port: int) -> String:
	var parts := ip.strip_edges().split(".")
	if parts.size() != 4 or port < 1 or port > 65535:
		return ""
	var v := 0
	for p in parts:
		if not p.is_valid_int() or int(p) < 0 or int(p) > 255:
			return ""
		v = (v << 8) | int(p)
	v = (v << 16) | port
	var s := ""
	for i in LEN: # 10 x 5 bits = 50 bits, top 2 always 0
		s = ALPHABET[v & 31] + s
		v >>= 5
	return "%s-%s-%s" % [prefix(), s.substr(0, 5), s.substr(5, 5)]


## {ok, kind: "direct", address, port, error}
static func decode(code: String) -> Dictionary:
	var c := code.strip_edges().to_upper().replace(" ", "").replace("-", "").replace("_", "")
	var pre := prefix().to_upper()
	for pf in [pre, "DN"]: # "DN" = codes shared before the Gravecrew rename
		if c.length() == LEN + pf.length() and c.begins_with(pf):
			c = c.substr(pf.length())
			break
	c = c.replace("O", "0").replace("I", "1").replace("L", "1")
	if c.length() != LEN:
		return {"ok": false, "error": "bad_length"}
	var v := 0
	for ch in c:
		var i := ALPHABET.find(ch)
		if i < 0:
			return {"ok": false, "error": "bad_char"}
		v = (v << 5) | i
	if v >> 48 != 0:
		return {"ok": false, "error": "out_of_range"}
	var port := v & 0xFFFF
	var ipv := v >> 16
	var ip := "%d.%d.%d.%d" % [(ipv >> 24) & 255, (ipv >> 16) & 255, (ipv >> 8) & 255, ipv & 255]
	if port == 0:
		return {"ok": false, "error": "bad_port"}
	return {"ok": true, "kind": "direct", "address": ip, "port": port}


## "1.2.3.4", "1.2.3.4:7777", "[::1]:7777", "host.name:7777" -> {address, port}; port defaults to default_port.
static func parse_address(text: String, default_port: int) -> Dictionary:
	var t := text.strip_edges()
	if t == "":
		return {"ok": false, "error": "empty"}
	var addr := t
	var port := default_port
	if t.begins_with("["): # [ipv6]:port
		var close := t.find("]")
		if close < 0:
			return {"ok": false, "error": "bad_address"}
		addr = t.substr(1, close - 1)
		var rest := t.substr(close + 1)
		if rest.begins_with(":"):
			if not rest.substr(1).is_valid_int():
				return {"ok": false, "error": "bad_port"}
			port = int(rest.substr(1))
	elif t.count(":") == 1:
		addr = t.get_slice(":", 0)
		var ps := t.get_slice(":", 1)
		if not ps.is_valid_int():
			return {"ok": false, "error": "bad_port"}
		port = int(ps)
	if port < 1 or port > 65535 or addr == "":
		return {"ok": false, "error": "bad_port" if addr != "" else "bad_address"}
	return {"ok": true, "address": addr, "port": port}
