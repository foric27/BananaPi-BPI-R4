local fs = require "nixio.fs"
local CADDYFILE = "/etc/caddy/Caddyfile"

local m, s, o
m = Map("caddy", translate("Caddy"), translate("Caddy — расширяемая серверная платформа с автоматическим HTTPS, быстрый и масштабируемый многоплатформенный HTTP/1-2-3 веб-сервер (используется как reverse proxy)") .. "<br/>" .. "Проект: " .. [[<a href="https://github.com/caddyserver/caddy" target="_blank">]] .. translate("github.com/caddyserver/caddy") .. "</a>&nbsp; &nbsp;&nbsp;" .. "Документация: " .. [[<a href="https://caddyserver.com/docs/" target="_blank">]] .. translate("caddyserver.com/docs/") .. [[</a>]])

m:section(SimpleSection).template  = "caddy/caddy_status"

s = m:section(TypedSection, "caddy")
s.addremove = false
s.anonymous = true

o = s:option(Flag, "enabled", translate("Включено"))
o.rmempty = false
o.default = 0

o = s:option(Button, "btnrm", translate("Перезапустить"))
o.inputtitle = translate("Перезапустить")
o.description = translate("Быстро перезапустить сервис без изменения параметров")
o.inputstyle = "apply"
o:depends("enabled", "1")
o.write = function()
	os.execute("/etc/init.d/caddy restart")
end

o = s:option(Value, "bin_dir", translate("Путь к программе"),
	translate("Путь к бинарному файлу caddy<br>Например: /usr/bin/caddy"))
o.datatype = "string"
o.default = "/usr/bin/caddy"
o.rmempty = false

o = s:option(Value, "log_dir", translate("Путь к логам"),
	translate("Путь к access-логу для просмотра на вкладке «Логи».<br>Должен совпадать с output file в Caddyfile, например: /tmp/caddy/requests.log"))
o.datatype = "string"
o.default = "/tmp/caddy/requests.log"
o.rmempty = false

o = s:option(TextValue, "caddyfile", translate("Файл конфигурации Caddyfile"),
	translate("Прямое редактирование /etc/caddy/Caddyfile.<br>Команда запуска: caddy run --config /etc/caddy/Caddyfile --adapter caddyfile<br>Пример reverse proxy:<br><code>:8080 {<br>&nbsp;&nbsp;reverse_proxy 127.0.0.1:80<br>}</code><br>Для установки пароля используйте: caddy hash-password --plaintext ваш_пароль<br>Изменения применяются после перезапуска сервиса."))
o.rows = 25
o.wrap = "off"
o.cfgvalue = function(self, section)
	return fs.readfile(CADDYFILE) or ""
end
o.write = function(self, section, value)
	if value then
		fs.writefile(CADDYFILE, (value:gsub("\r\n", "\n")))
	end
end
o.remove = function(self, section)
end

o = s:option(Button, "admin_info", translate("Проверить конфигурацию"),
	translate("Проверить файл конфигурации Caddyfile на ошибки"))

o.rawhtml = true
o.template = "caddy/admin_info"

return m
