#!/bin/bash

# ===== НАСТРОЙКИ =====
INTERVAL=60                     # Интервал между проверками в секундах
WINDOW=3600                      # Интервал для определения средней нагрузки в секундах
THRESHOLD_CPU=55.0              # Уровень средней нагрузки CPU для отправки сообщения (в %)
THRESHOLD_MEM=1024000           # Уровень средней нагрузки памяти (RSS) для отправки сообщения (в KB)
COOLDOWN=14400                  # Задержка в секундах для отправки повторных сообщений (общая для CPU и памяти)

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

DATA_DIR="/var/tmp/cpu_monitor"
CPU_HISTORY_DIR="$DATA_DIR/cpu_history"
MEM_HISTORY_DIR="$DATA_DIR/mem_history"
CPU_LAST_NOTIFY="$DATA_DIR/cpu_last_notify"
MEM_LAST_NOTIFY="$DATA_DIR/mem_last_notify"
LOCK_FILE="$DATA_DIR/monitor.lock"

mkdir -p "$CPU_HISTORY_DIR" "$MEM_HISTORY_DIR" "$CPU_LAST_NOTIFY" "$MEM_LAST_NOTIFY"
# =====================

# По умолчанию фильтр отключён
FILTER_PATTERN=""

# Отладка
DEBUG=false
debug() {
    if $DEBUG; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') DEBUG: $*" >&2
    fi
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

send_telegram() {
    local message="$1"
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    message=$(echo "$message" | sed 's/"/\\"/g')
    curl -s -X POST "$url" -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=${message}" -d "parse_mode=HTML" > /dev/null
    if [ $? -eq 0 ]; then
        log "Уведомление отправлено в Telegram: ${message:0:100}..."
    else
        log "Ошибка отправки в Telegram"
    fi
}

format_message_cpu() {
    local pid="$1"
    local cmd="$2"
    local avg="$3"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local minutes=$((WINDOW / 60))
    if [ ${#cmd} -gt 200 ]; then
        cmd="${cmd:0:200}..."
    fi
    printf "⚠️ <b>Высокая нагрузка CPU</b>\nВремя: %s\nIP: %s\nВерсия rudesktop: %s\nPID: %s\nКоманда: %s\nСредняя загрузка за %d мин: %.1f%%" \
           "$timestamp" "$IP_ADDR" "$RUDESKTOP_VERSION" "$pid" "$cmd" "$minutes" "$avg"
}

format_message_mem() {
    local pid="$1"
    local cmd="$2"
    local avg="$3"  # avg в KB
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local minutes=$((WINDOW / 60))
    local avg_mb=$(echo "scale=1; $avg / 1024" | bc)
    if [ ${#cmd} -gt 200 ]; then
        cmd="${cmd:0:200}..."
    fi
    printf "🟢 <b>Высокое потребление памяти</b>\nВремя: %s\nIP: %s\nВерсия rudesktop: %s\nPID: %s\nКоманда: %s\nСредний RSS за %d мин: %.1f MB" \
           "$timestamp" "$IP_ADDR" "$RUDESKTOP_VERSION" "$pid" "$cmd" "$minutes" "$avg_mb"
}

compute_average() {
    local history_file="$1"
    local now=$(date +%s)
    local cutoff=$((now - WINDOW))
    local sum=0
    local count=0
    local temp_file="${history_file}.tmp"

    > "$temp_file"
    while IFS= read -r line; do
        read -r ts value rest <<< "$line"
        # Проверяем, что ts и value — числа
        if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$value" =~ ^[0-9.]+$ ]] && [ "$ts" -ge "$cutoff" ]; then
            echo "$line" >> "$temp_file"
            sum=$(echo "$sum + $value" | bc)
            count=$((count + 1))
        fi
    done < "$history_file" 2>/dev/null

    mv "$temp_file" "$history_file" 2>/dev/null

    if [ $count -eq 0 ]; then
        echo "0"
    else
        echo "scale=2; $sum / $count" | bc
    fi
}

monitor_loop() {
    log "Мониторинг CPU запущен. Порог CPU: $THRESHOLD_CPU% за $((WINDOW/60)) мин, интервал: $INTERVAL сек."
    log "Мониторинг памяти запущен. Порог памяти: $((THRESHOLD_MEM/1024)) MB за $((WINDOW/60)) мин."
    if [ -n "$FILTER_PATTERN" ]; then
        log "Фильтр процессов: только те, что содержат '$FILTER_PATTERN' (регистронезависимо)"
    fi

    declare -A prev_cpu_times
    declare -A prev_cmdlines
    declare -A prev_names
    # Для памяти не нужны предыдущие значения, т.к. берём текущий RSS

    while true; do
        {
            flock -x 200 || exit 1

            now=$(date +%s)
            ticks=$(getconf CLK_TCK)
            cur_data=$(mktemp)

            debug "Начало сбора данных, ticks=$ticks"

            for pid in /proc/[0-9]*; do
                pid=${pid#/proc/}
                [ ! -d "/proc/$pid" ] && continue

                # Получаем данные CPU из stat
                if [ -r "/proc/$pid/stat" ]; then
                    stat=$(cat /proc/$pid/stat 2>/dev/null) || continue
                    utime=$(echo "$stat" | awk '{print $14}')
                    stime=$(echo "$stat" | awk '{print $15}')
                    if [ -z "$utime" ] || [ -z "$stime" ]; then
                        continue
                    fi
                    total_ticks=$((utime + stime))

                    # Получаем RSS из statm (в страницах)
                    rss_pages=0
                    if [ -r "/proc/$pid/statm" ]; then
                        read -r size rss _ < /proc/$pid/statm 2>/dev/null
                        rss_pages=$rss
                    fi
                    # Преобразуем страницы в KB (обычно страница = 4KB, но лучше узнать размер страницы)
                    page_size=$(getconf PAGESIZE 2>/dev/null || echo 4096)
                    rss_kb=$((rss_pages * page_size / 1024))

                    # Командная строка
                    if [ -r "/proc/$pid/cmdline" ]; then
                        cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline | sed 's/ *$//')
                    else
                        cmdline=""
                    fi
                    if [ -z "$cmdline" ]; then
                        cmdline=$(cat /proc/$pid/comm 2>/dev/null)
                    fi
                    comm_name=$(cat /proc/$pid/comm 2>/dev/null)

                    # Применяем фильтр, если задан
                    if [ -n "$FILTER_PATTERN" ]; then
                        if ! echo "$cmdline" | grep -qi "$FILTER_PATTERN" && ! echo "$comm_name" | grep -qi "$FILTER_PATTERN"; then
                            continue
                        fi
                    fi

                    echo "$pid $total_ticks $rss_kb $comm_name $cmdline" >> "$cur_data"
                fi
            done

            lines=$(wc -l < "$cur_data")
            debug "Собрано $lines процессов (после фильтрации)"

            # Обработка собранных данных
            while read -r pid total_ticks rss_kb comm_name cmdline; do
                # --- Обработка CPU ---
                if [[ -n "${prev_cpu_times[$pid]}" ]]; then
                    prev_ticks=${prev_cpu_times[$pid]}
                    delta_ticks=$((total_ticks - prev_ticks))
                    if [ $delta_ticks -lt 0 ]; then
                        debug "Отрицательная разница для PID $pid (возможно, процесс перезапущен), сбрасываем CPU"
                        prev_cpu_times[$pid]=$total_ticks
                    else
                        cpu_percent=$(echo "scale=2; $delta_ticks * 100 / ($ticks * $INTERVAL)" | bc 2>/dev/null)
                        if [ -n "$cpu_percent" ]; then
                            debug "PID $pid CPU: delta=$delta_ticks, cpu=$cpu_percent%"
                            history_file="$CPU_HISTORY_DIR/$pid"
                            echo "$now $cpu_percent $cmdline" >> "$history_file"
                            avg_cpu=$(compute_average "$history_file")
                            debug "PID $pid CPU avg=$avg_cpu"

                            if [[ -n "$avg_cpu" ]] && (( $(echo "$avg_cpu > $THRESHOLD_CPU" | bc -l) )); then
                                last_notify_file="$CPU_LAST_NOTIFY/$pid"
                                last_ts=0
                                [ -f "$last_notify_file" ] && last_ts=$(cat "$last_notify_file")
                                if (( now - last_ts > COOLDOWN )); then
                                    debug "Порог CPU превышен для PID $pid, отправляем уведомление"
                                    msg=$(format_message_cpu "$pid" "$cmdline" "$avg_cpu")
                                    send_telegram "$msg"
                                    echo "$now" > "$last_notify_file"
                                fi
                            fi
                        fi
                    fi
                fi
                prev_cpu_times[$pid]=$total_ticks

                # --- Обработка памяти ---
                if [ "$rss_kb" -gt 0 ]; then
                    history_file="$MEM_HISTORY_DIR/$pid"
                    echo "$now $rss_kb $cmdline" >> "$history_file"
                    avg_mem=$(compute_average "$history_file")
                    debug "PID $pid MEM avg=$avg_mem KB"

                    if [[ -n "$avg_mem" ]] && (( $(echo "$avg_mem > $THRESHOLD_MEM" | bc -l) )); then
                        last_notify_file="$MEM_LAST_NOTIFY/$pid"
                        last_ts=0
                        [ -f "$last_notify_file" ] && last_ts=$(cat "$last_notify_file")
                        if (( now - last_ts > COOLDOWN )); then
                            debug "Порог памяти превышен для PID $pid, отправляем уведомление"
                            msg=$(format_message_mem "$pid" "$cmdline" "$avg_mem")
                            send_telegram "$msg"
                            echo "$now" > "$last_notify_file"
                        fi
                    fi
                fi

                prev_cmdlines[$pid]="$cmdline"
                prev_names[$pid]="$comm_name"
            done < "$cur_data"

            # Очистка устаревших PID из prev_* и last_notify
            declare -A cur_pids
            while read -r pid rest; do
                cur_pids[$pid]=1
            done < "$cur_data"

            for pid in "${!prev_cpu_times[@]}"; do
                if [[ -z "${cur_pids[$pid]}" ]]; then
                    unset prev_cpu_times[$pid]
                    unset prev_cmdlines[$pid]
                    unset prev_names[$pid]
                fi
            done

            # Очистка last_notify для мёртвых PID (CPU и память)
            for dir in "$CPU_LAST_NOTIFY" "$MEM_LAST_NOTIFY"; do
                if [ -d "$dir" ]; then
                    for file in "$dir"/*; do
                        if [ -f "$file" ]; then
                            pid=${file##*/}
                            if [[ ! -e "/proc/$pid" ]]; then
                                rm -f "$file"
                            fi
                        fi
                    done
                fi
            done

            rm -f "$cur_data"

            debug "Цикл завершён, ожидание $INTERVAL сек"
        } 200>"$LOCK_FILE"

        sleep "$INTERVAL"
    done
}

# Разбор аргументов командной строки
DAEMON_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --daemon)
            DAEMON_MODE=true
            shift
            ;;
        --filter)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Ошибка: для --filter требуется указать паттерн."
                exit 1
            fi
            FILTER_PATTERN="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            exit 1
            ;;
    esac
done

# Определяем IP адрес и версию rudesktop (один раз при запуске)
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then
    IP_ADDR="Не определен"
fi

if command -v rudesktop >/dev/null 2>&1; then
    RUDESKTOP_VERSION=$(rudesktop --version 2>/dev/null | head -1)
    if [ -z "$RUDESKTOP_VERSION" ]; then
        RUDESKTOP_VERSION="Не определена"
    fi
else
    RUDESKTOP_VERSION="Не установлен"
fi

if $DAEMON_MODE; then
    monitor_loop
else
    echo "Использование: $0 --daemon [--filter паттерн] [--debug]"
    echo "  --daemon          Запустить мониторинг в режиме демона."
    echo "  --filter паттерн  Отслеживать только процессы, содержащие указанный паттерн (регистронезависимо)."
    echo "  --debug           Включить отладочный вывод."
    echo ""
    echo "Пример: $0 --daemon --filter rudesktop"
    exit 1
fi