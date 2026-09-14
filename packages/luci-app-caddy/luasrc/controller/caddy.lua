module("luci.controller.caddy", package.seeall)

local fs = require "nixio.fs"

function index()
	entry({"admin", "nas"}, firstchild(), _("NAS") , 45).dependent = false
	if not fs.access("/etc/config/caddy") then
		return
	end

	local page = entry({"admin", "nas", "caddy"}, alias("admin", "nas", "caddy", "basic"), _("Caddy"), 20)
	page.dependent = true
	page.acl_depends = { "luci-app-caddy" }

	entry({"admin", "nas"}, firstchild(), "NAS", 44).dependent = false
	entry({"admin", "nas", "caddy", "basic"}, cbi("caddy/caddy"), _("Основные настройки"), 1).leaf = true
	entry({"admin", "nas", "caddy", "log"}, cbi("caddy/caddy_log"), _("Логи"), 2).leaf = true
	entry({"admin", "nas", "caddy", "caddy_status"}, call("caddy_status")).leaf = true
	entry({"admin", "nas", "caddy", "get_log"}, call("get_log")).leaf = true
	entry({"admin", "nas", "caddy", "clear_log"}, call("clear_log")).leaf = true
	entry({"admin", "nas", "caddy", "admin_info"}, call("admin_info")).leaf = true
end

local function uci_cursor()
	return require "luci.model.uci".cursor()
end

local function caddy_bin()
	local uci = uci_cursor()
	local bin = uci:get("caddy", "@caddy[0]", "bin_dir")

	if not bin or bin == "" or not fs.access(bin, "x") then
		bin = "/usr/bin/caddy"
	end

	return bin
end

local function shell_quote(s)
	return "'" .. (s:gsub("'", '')) .. "'"
end

local function log_path()
	local uci = uci_cursor()
	local path = uci:get("caddy", "@caddy[0]", "log_dir")

	if not path or path == "" then
		path = "/tmp/caddy/requests.log"
	end

	return path
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function caddy_pid()
	local f = io.popen("pidof caddy 2>/dev/null")
	if not f then
		return nil
	end
	local pids = f:read("*all") or ""
	f:close()
	return tonumber(pids:match("%S+"))
end

-- utime+stime из /proc/<pid>/stat (поля 12-13 после comm в скобках)
local function read_stat_ticks(pid)
	local f = io.open("/proc/" .. pid .. "/stat", "r")
	if not f then
		return nil
	end
	local data = f:read("*all")
	f:close()

	local rest = data:match("%)%s+(.+)$")
	if not rest then
		return nil
	end

	local n, utime, stime = 0
	for token in rest:gmatch("%S+") do
		n = n + 1
		if n == 12 then
			utime = tonumber(token)
		elseif n == 13 then
			stime = tonumber(token)
			break
		end
	end

	if not utime or not stime then
		return nil
	end

	return utime + stime
end

local clk_tck = nil
local function get_clk_tck()
	if not clk_tck then
		local f = io.popen("getconf CLK_TCK 2>/dev/null")
		if f then
			clk_tck = tonumber(f:read("*l")) or 100
			f:close()
		else
			clk_tck = 100
		end
	end
	return clk_tck
end

-- Кеш-обёртка: refresh_fn вызывается не чаще раза в max_age секунд;
-- даже пустой результат записывается в файл, чтобы не порождать
-- повторные (сетевые) запросы на каждом опросе статуса.
local function cached_tag(path, refresh_fn, max_age)
	local st = fs.stat(path)
	if st and st.mtime and (os.time() - st.mtime) < max_age then
		local content = fs.readfile(path)
		if content and content ~= "" then
			return trim(content)
		end
	end

	local value = trim(refresh_fn() or "")
	if value == "" then
		value = "unknown"
	end
	fs.writefile(path, value)
	return value
end

local function refresh_local_version()
	local f = io.popen(shell_quote(caddy_bin()) .. " -v 2>/dev/null | awk '{print $1}' | sed 's/[^0-9.]*//g'")
	if not f then
		return nil
	end
	local v = f:read("*all") or ""
	f:close()
	return v
end

local function refresh_remote_version()
	local f = io.popen("curl -L -k -s --connect-timeout 3 --max-time 8 --user-agent 'Mozilla/5.0' https://api.github.com/repos/caddyserver/caddy/releases/latest 2>/dev/null | grep tag_name | sed 's/[^0-9.]*//g'")
	if not f then
		return nil
	end
	local v = f:read("*all") or ""
	f:close()
	return v
end

local cpu_state = nil

function caddy_status()
	local e = {}

	-- PID / running
	local pid = caddy_pid()
	e.running = pid ~= nil

	-- Uptime (считается в Lua, без fork)
	local tagfile = io.open("/tmp/caddy_time", "r")
	if tagfile then
		local start_time = tonumber(tagfile:read("*l"))
		tagfile:close()
		if start_time then
			local uptime = os.time() - start_time
			if uptime < 0 then
				uptime = 0
			end
			local days = math.floor(uptime / 86400)
			local rem = uptime % 86400
			e.caddysta = (days > 0 and (days .. "d ") or "") ..
				string.format("%02dh%02dm%02ds", math.floor(rem / 3600),
					math.floor((rem % 3600) / 60), rem % 60)
		end
	end
	e.caddysta = e.caddysta or "unknown"

	-- CPU: дельта utime+stime между опросами (без fork)
	if pid then
		local ticks = read_stat_ticks(pid)
		if ticks then
			local now = os.time()
			if cpu_state and cpu_state.pid == pid and cpu_state.ticks and now > cpu_state.ts then
				local pct = (ticks - cpu_state.ticks) / ((now - cpu_state.ts) * get_clk_tck()) * 100
				if pct < 0 then
					pct = 0
				end
				e.caddycpu = string.format("%.1f", pct)
			end
			cpu_state = { pid = pid, ticks = ticks, ts = now }
		end
	else
		cpu_state = nil
	end
	e.caddycpu = e.caddycpu or "unknown"

	-- RAM: /proc/<pid>/status (без fork)
	if pid then
		local f = io.open("/proc/" .. pid .. "/status", "r")
		if f then
			for line in f:lines() do
				local kb = line:match("^VmRSS:%s+(%d+)%s+kB")
				if kb then
					e.caddyram = string.format("%.2f MB", tonumber(kb) / 1024)
					break
				end
			end
			f:close()
		end
	end
	e.caddyram = e.caddyram or "unknown"

	-- Версии: с кешем и защитой от повторных запросов
	e.caddytag = cached_tag("/tmp/caddy.tag", refresh_local_version, 86400)
	e.caddynewtag = cached_tag("/tmp/caddynew.tag", refresh_remote_version, 3600)

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function get_log()
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(fs.readfile(log_path()) or "")
end

function clear_log()
	fs.writefile(log_path(), "")
	luci.http.prepare_content("application/json")
	luci.http.write_json({ ok = true })
end

function admin_info()
	local out = luci.sys.exec(shell_quote(caddy_bin()) .. " validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1")

	luci.http.prepare_content("application/json")
	luci.http.write_json({ validate = out })
end
