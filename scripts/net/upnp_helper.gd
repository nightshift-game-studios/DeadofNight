class_name NetUpnp
extends RefCounted
## UPnP auto port-open for hosting (Netz). Runs discovery on a Thread (UPNP.discover blocks ~2 s) and reports
## through `callback.call(result: Dictionary)` on the main thread:
##   {ok, external_ip, ip_class, message, double_nat}
## ip_class(): "public" | "private" | "cgnat" | "loopback" | "invalid". A private / CGNAT "external" address means
## the router itself sits behind another NAT (double NAT / carrier-grade NAT): friends can't reach it directly.

var _thread: Thread
var _upnp: UPNP
var _mapped_port := 0


static func ip_class(ip: String) -> String:
	var p := ip.strip_edges().split(".")
	if p.size() != 4:
		return "invalid"
	var b: Array[int] = []
	for s in p:
		if not s.is_valid_int() or int(s) < 0 or int(s) > 255:
			return "invalid"
		b.append(int(s))
	if b[0] == 127:
		return "loopback"
	if b[0] == 10 or (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or (b[0] == 192 and b[1] == 168) or (b[0] == 169 and b[1] == 254):
		return "private"
	if b[0] == 100 and b[1] >= 64 and b[1] <= 127:
		return "cgnat"
	if b[0] == 0 or b[0] >= 224:
		return "invalid"
	return "public"


## Human message for the lobby given a finished result.
static func describe(ok: bool, ext_ip: String, err: String = "") -> Dictionary:
	var cls := ip_class(ext_ip) if ext_ip != "" else "invalid"
	var dn := cls == "private" or cls == "cgnat"
	var msg := ""
	if not ok:
		msg = "UPnP unavailable (%s). Forward UDP port manually and allow Gravecrew in Windows Firewall." % (err if err != "" else "no gateway")
	elif dn:
		msg = "Your router reports %s as its internet address: double NAT / carrier-grade NAT. Friends can't reach you directly; use a VPN (Tailscale) for now." % ext_ip
	else:
		msg = "UPnP opened the port. Share %s." % ext_ip
	return {"ok": ok and not dn, "external_ip": ext_ip, "ip_class": cls, "double_nat": dn, "message": msg}


func open_async(port: int, callback: Callable) -> void:
	close()
	_thread = Thread.new()
	_thread.start(_worker.bind(port, callback))


func _worker(port: int, callback: Callable) -> void:
	var u := UPNP.new()
	var ms := int(NetConfig.get_value("upnp.discover_ms", 2000))
	var ttl := int(NetConfig.get_value("upnp.discover_ttl", 2))
	var r := u.discover(ms, ttl)
	var res: Dictionary
	if r != UPNP.UPNP_RESULT_SUCCESS or u.get_gateway() == null or not u.get_gateway().is_valid_gateway():
		res = describe(false, "", "discover result %d" % r)
	else:
		var m := u.add_port_mapping(port, port, str(NetConfig.get_value("upnp.description", "Gravecrew")), "UDP", 0)
		if m != UPNP.UPNP_RESULT_SUCCESS:
			res = describe(false, "", "add_port_mapping result %d" % m)
		else:
			_upnp = u
			_mapped_port = port
			res = describe(true, u.query_external_address())
	callback.call_deferred(res)


## Removes the mapping (if any) and joins the worker thread.
func close() -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	if _upnp and _mapped_port > 0:
		_upnp.delete_port_mapping(_mapped_port, "UDP")
	_upnp = null
	_mapped_port = 0
