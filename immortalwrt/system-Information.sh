#!/bin/bash
# ================================================
# Имя скрипта: Скрипт получения системной информации
# Описание: Скрипт для получения основной информации о системе (CPU, память, диск и т.д.)
# Версия: 1.0
# Автор: DHDAXCW
# ================================================

echo "=== Системная информация ==="

# Информация о CPU
echo -e "\n=== Информация о CPU ==="
echo -e "Общее количество ядер CPU: $(nproc)"
echo "Подробная информация о CPU:"
if [ -f /proc/cpuinfo ]; then
  echo "Модель: $(grep 'model name' /proc/cpuinfo | head -n1 | cut -d':' -f2 | sed 's/^\s*//')"
  echo "Текущая частота: $(grep 'cpu MHz' /proc/cpuinfo | head -n1 | cut -d':' -f2 | sed 's/^\s*//') MHz"
  echo "Размер кэша: $(grep 'cache size' /proc/cpuinfo | head -n1 | cut -d':' -f2 | sed 's/^\s*//')"
  echo "Архитектура: $(lscpu | grep 'Architecture' | cut -d':' -f2 | sed 's/^\s*//')"
  echo "Ядер на сокет: $(lscpu | grep 'Core(s) per socket' | cut -d':' -f2 | sed 's/^\s*//')"
  echo "Потоков на ядро: $(lscpu | grep 'Thread(s) per core' | cut -d':' -f2 | sed 's/^\s*//')"

  MAX_FREQ=$(lscpu | grep -E 'CPU max MHz|CPU MHz max' | cut -d':' -f2 | sed 's/^\s*//')
  MIN_FREQ=$(lscpu | grep -E 'CPU min MHz|CPU MHz min' | cut -d':' -f2 | sed 's/^\s*//')
  echo "Макс. частота: ${MAX_FREQ:-неизвестно} MHz"
  echo "Мин. частота: ${MIN_FREQ:-неизвестно} MHz"
else
  echo "Информация о CPU недоступна (файл /proc/cpuinfo отсутствует)"
fi

# Информация о памяти
echo -e "\n=== Информация о памяти ==="
free -h | awk '/^Mem:/ {print "Total Memory\t: " $2 "\nUsed Memory\t: " $3 "\nFree Memory\t: " $4}'

# Информация о дисках
echo -e "\n=== Информация о дисках ==="
df -h | grep -E '^/dev/' | awk '{print "Device: " $1 "\tSize: " $2 "\tUsed: " $3 "\tAvail: " $4 "\tMount: " $6}'

# Информация о сетевых адаптерах
echo -e "\n=== Информация о сетевых адаптерах ==="
if command -v ethtool >/dev/null 2>&1; then
  for iface in $(ip -br addr show | awk '{print $1}' | grep -v '^lo$'); do
    echo "Имя интерфейса: $iface"
    echo "Состояние\t: $(ip -br addr show | grep "^$iface" | awk '{print $2}')"
    echo "IP-адрес\t: $(ip -br addr show | grep "^$iface" | awk '{print $3}')"
    echo "Скорость\t: $(ethtool "$iface" 2>/dev/null | grep 'Speed:' | awk '{print $2}' || echo 'неизвестно')"
    echo "----------------"
  done
else
  echo "ethtool не установлен, отображается только базовая информация"
  ip -br addr show | awk '{print "Интерфейс: " $1 "\tСостояние: " $2 "\tIP: " $3}'
fi

# Дополнительные сведения о системе
echo -e "\n=== Дополнительные сведения о системе ==="
uname -a
[ -f /proc/version ] && echo "Информация о версии:" && cat /proc/version
[ -f /etc/issue.net ] && echo "Дистрибутив (net):" && cat /etc/issue.net
[ -f /etc/issue ] && echo "Дистрибутив:" && cat /etc/issue
echo -e "\nОграничения ресурсов:"
ulimit -a
