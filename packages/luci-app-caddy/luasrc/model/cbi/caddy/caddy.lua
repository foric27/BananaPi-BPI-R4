local m, s
m = Map("caddy", translate("Caddy"), translate("Caddy - это расширяемая серверная платформа с автоматическим HTTPS, быстрый и масштабируемый многоplatformенный HTTP/1-2-3 веб-сервер") .. "<br/>" .. "Проект: " .. [[<a href="https://github.com/caddyserver/caddy" target="_blank">]] .. translate("github.com/caddyserver/caddy") .. "</a>&nbsp; &nbsp;&nbsp;" .. "Документация: " .. [[<a href="https://caddyserver.com/docs/" target="_blank">]] .. translate("caddyserver.com/docs/") .. [[</a>]])

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

e=s:option(ListValue,"cmd",translate("Режим запуска"),
	translate("Пользовательский конфиг - если не уверены, не меняйте"))
e:value("По умолчанию")
e:value("Пользовательский")

o = s:option(TextValue, "caddyfile", translate("Файл конфигурации Caddyfile"),
	translate("Конфигурационный файл Caddy, путь: /etc/caddy/Caddyfile<br>Команда запуска: caddy run --config /etc/caddy/Caddyfile --adapter caddyfile<br>Для установки пароля используйте: $(uci -q get caddy.@caddy[0].bin_dir) hash-password --plaintext ваш_пароль"))
o.rows = 3
o.wrap = "off"
o:depends("cmd", "Пользовательский")

o = s:option(Value, "port", translate("Порт"))
o.datatype = "and(port,min(1))"
o.default = "12311"
o:depends("cmd", "По умолчанию")

o = s:option(Flag,"file_pass", translate("Включить аутентификацию"))
o.datatype = "string"
o.default = "0"
o:depends("cmd", "По умолчанию")

o = s:option(Value,"file_username", translate("Имя пользователя"))
o.datatype = "string"
o.default = "admin"
o:depends("file_pass", "1")

o = s:option(Value,"file_password", translate("Пароль"))
o.datatype = "string"
o.password = true
o.default = "123456"
o:depends("file_pass", "1")

o = s:option(Flag, "filezip", translate("Включить сжатие"))
o.default = 0
o:depends("cmd", "По умолчанию")

o = s:option(Flag, "log", translate("Включить логирование"))
o.default = 1
o:depends("cmd", "По умолчанию")

o = s:option(Value, "log_dir", translate("Путь к логам"),
	translate("Путь для сохранения логов<br>Рекомендуется /tmp, например: /tmp/caddy/requests.log"))
o.datatype = "string"
o.default = "/tmp/caddy/requests.log"
o:depends("log", "1")

o = s:option(Value, "bin_dir", translate("Путь к программе"),
	translate("Путь к бинарному файлу caddy<br>Например: /usr/bin/caddy"))
o.datatype = "string"
o.default = "/usr/bin/caddy"

o = s:option(Value, "data_dir", translate("Корневая директория"),
	translate("Директория для файлового сервера, по умолчанию /mnt"))
o.datatype = "string"
o.default = "/mnt"
o:depends("cmd", "По умолчанию")

o = s:option(Flag, "webdav", translate("Включить WebDAV"))
o.default = "0"
o:depends("cmd", "По умолчанию")

o = s:option(Flag,"webdav_pass", translate("Включить аутентификацию"))
o.datatype = "string"
o:depends("webdav", "1")
o.default = "0"

o = s:option(Value,"webdav_username", translate("Имя пользователя"))
o.datatype = "string"
o.default = "admin"
o:depends("webdav_pass", "1")

o = s:option(Value,"webdav_password", translate("Пароль"))
o.datatype = "string"
o.password = true
o.default = "123456"
o:depends("webdav_pass", "1")

o = s:option(Value,"webdav_port", translate("Порт WebDAV"))
o.datatype = "and(port,min(1))"
o.default = "12322"
o:depends("webdav", "1")

o = s:option(Flag, "webzip", translate("Включить сжатие"))
o.default = 0
o:depends("webdav", "1")

o = s:option(Value, "webdav_data_dir", translate("Директория WebDAV"),
	translate("Директория для WebDAV, по умолчанию /mnt<br>Адрес подключения: http://IP:ПОРТ/dav"))
o.datatype = "string"
o:depends("webdav", "1")
o.default = "/mnt"

o = s:option(Flag, "allow_wan", translate("Разрешить доступ из WAN"))
o.rmempty = false

o = s:option(Flag, "api", translate("Включить API-интерфейс"))
o:depends("cmd", "По умолчанию")

o = s:option(Button, "admin_info", translate("Проверить конфигурацию"),
	translate("Проверить файл конфигурации Caddyfile на ошибки"))

o.rawhtml = true
o.template = "caddy/admin_info"

return m
