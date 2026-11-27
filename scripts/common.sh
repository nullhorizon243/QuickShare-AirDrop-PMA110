#!/system/bin/sh
# Shared helpers for Root-only state validation, staged OTA checks, and User 0 UID lookup.

verify_file_sha256() (
    path="$1"
    expected="$2"
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "${#expected}" -eq 64 ] || return 1
    case "$expected" in *[!0-9a-f]*) return 1 ;; esac
    actual="$(sha256sum "$path")" || return 1
    [ "${actual%% *}" = "$expected" ]
)

ensure_root_dir() {
    dir_path="$1"
    if [ -L "$dir_path" ] || { [ -e "$dir_path" ] && [ ! -d "$dir_path" ]; }; then
        echo "状态路径异常（非普通目录）：${dir_path}" >&2
        return 1
    fi
    if [ ! -d "$dir_path" ]; then
        mkdir -m 700 "$dir_path" || return 1
    fi
    chown 0:0 "$dir_path" || return 1
    chmod 700 "$dir_path" || return 1
    [ "$(stat -c '%a:%u:%g' "$dir_path" 2>/dev/null || true)" = '700:0:0' ] || {
        echo "目录权限与属主校验失败：${dir_path}" >&2
        return 1
    }
}

# Android shell commands pass stdio to system services, which cannot use our Root-only log files.
LOG_THROUGH_PIPE='
    log_file="$1"
    shift
    "$@" 2>&1 | { cat >"$log_file" || cat >/dev/null; }
'

log_note() (
    trap '' PIPE
    printf '%s\n' "$*" 2>/dev/null || :
)

# Restore the retry allowance after ten minutes of working service, using the boot clock.
RECOVERY_STABLE_SECONDS=600

uptime_seconds() (
    read -r elapsed remainder </proc/uptime || exit 1
    elapsed="${elapsed%%.*}"
    case "$elapsed" in ''|*[!0-9]*) exit 1 ;; esac
    printf '%s\n' "$elapsed"
)

recovery_window_elapsed() (
    started="$1"
    case "$started" in ''|*[!0-9]*) exit 1 ;; esac
    now="$(uptime_seconds)" || exit 1
    [ "$((now - started))" -ge "$RECOVERY_STABLE_SECONDS" ]
)

provider_bound() (
    set -o pipefail
    dumpsys activity services com.google.android.mosey 2>/dev/null | awk '
        /ServiceRecord\{/ {
            if (provider && app && client) connected=1
            provider=($0 ~ / u0 com[.]google[.]android[.]mosey\/(com[.]google[.]android[.]mosey)?[.]?ExternalSharingService([[:space:]]|\})/)
            app=client=0
        }
        provider && /app=ProcessRecord\{.*:com[.]google[.]android[.]mosey\// {app=1}
        provider && /binding=AppBindRecord\{.*ExternalSharingService:com[.]google[.]android[.]gms\}/ {client=1}
        END {exit !(connected || (provider && app && client))}'
)

process_start_time() (
    case "$1" in ''|0|1|*[!0-9]*) exit 1 ;; esac
    IFS= read -r process_stat <"/proc/$1/stat" || exit 1
    printf '%s\n' "${process_stat##*) }" |
        awk '$1 != "Z" && $20 ~ /^[0-9]+$/ {print $20; found=1} END {exit !found}'
)

record_process() (
    record="$1"
    pid="$2"
    started="$(process_start_time "$pid" 2>/dev/null)" || exit 1
    boot="$(cat /proc/sys/kernel/random/boot_id)" || exit 1
    printf '%s %s %s\n' "$boot" "$pid" "$started" >"$record.tmp" &&
        mv -f "$record.tmp" "$record"
)

recorded_pid() (
    [ -f "$1" ] && [ ! -L "$1" ] || exit 1
    read -r boot pid started extra <"$1" || exit 1
    [ -z "$extra" ] && [ "$boot" = "$(cat /proc/sys/kernel/random/boot_id)" ] || exit 1
    current="$(process_start_time "$pid" 2>/dev/null)" || exit 1
    [ "$current" = "$started" ] || exit 1
    printf '%s\n' "$pid"
)

stop_recorded_process() (
    record="$1"
    pid="$(recorded_pid "$record")" || exit 0
    kill -TERM "$pid" 2>/dev/null || :
    for step in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(recorded_pid "$record")" = "$pid" ] || exit 0
        sleep 0.2
    done
    [ "$(recorded_pid "$record")" = "$pid" ] || exit 0
    kill -KILL "$pid" 2>/dev/null || :
    for step in 1 2 3 4 5; do
        [ "$(recorded_pid "$record")" = "$pid" ] || exit 0
        sleep 0.2
    done
    exit 1
)

stop_session_workers() {
    stop_recorded_process "$1/feature/native-monitor" &&
        stop_recorded_process "$1/feature/native-process" &&
        stop_recorded_process "$1/feature/filewatch-process"
}

RUN_RECORDED_PROCESS='
    set -eu
    session="$1" record="$2" owner="$3"
    shift 3
    . "$session/feature/common.sh"
    [ "$PPID" = "$owner" ] && [ ! -e "$session/stop" ] || exit 1
    record_process "$session/feature/$record" "$$"
    if [ "$record" = native-process ]; then
        if start_signal_trace "$session" "$$" 2>/dev/null; then
            log_note "Kernel signal tracing armed for PID $$"
        else
            log_note "Kernel signal tracing unavailable for PID $$"
        fi
    fi
    [ "$PPID" = "$owner" ] && [ ! -e "$session/stop" ] || exit 1
    exec "$@"
'

signal_trace_path() (
    suffix="${1##*.}"
    case "$suffix" in ''|*[!A-Za-z0-9]*) exit 1 ;; esac
    for tracefs in /sys/kernel/tracing /sys/kernel/debug/tracing; do
        if [ -d "$tracefs/instances" ]; then
            printf '%s\n' "$tracefs/instances/quickshare-$suffix"
            exit 0
        fi
    done
    exit 1
)

start_signal_trace() (
    trace="$(signal_trace_path "$1")" || exit 1
    mkdir "$trace" || exit 1
    event="$trace/events/signal/signal_generate"
    if printf '0\n' >"$trace/tracing_on" &&
        printf '4\n' >"$trace/buffer_size_kb" &&
        printf 'pid == %s && (sig == 15 || sig == 9)\n' "$2" >"$event/filter" &&
        printf '1\n' >"$event/enable" &&
        printf '1\n' >"$trace/tracing_on"; then
        exit 0
    fi
    rmdir "$trace" || :
    exit 1
)

finish_signal_trace() (
    trace="$(signal_trace_path "$1")" || exit 0
    [ -d "$trace" ] || exit 0
    printf '0\n' >"$trace/tracing_on" || :
    output="$(grep 'signal_generate:' "$trace/trace" | tail -12)" || output=
    if [ -n "$output" ]; then
        printf '%s\n' "$output" >>"$1/native-signals" || :
    fi
    rmdir "$trace" 2>/dev/null || [ ! -d "$trace" ]
)

check_no_staged_sessions() {
    local staged_out staged_rc=0
    # PackageManagerShellCommand also returns 1 after successfully listing staged sessions.
    staged_out="$(cmd package list staged-sessions --only-ready --only-sessionid --only-parent 2>&1)" || staged_rc=$?
    case "$staged_rc" in
        0|1)
            [ -n "$staged_out" ] || return 0
            if printf '%s\n' "$staged_out" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]*$'; then
                echo '有待应用的系统更新，已暂停操作。' >&2
                return 1
            fi
            ;;
    esac
    printf '无法查询待应用的系统更新状态（退出码 %s）：%s\n' \
        "$staged_rc" "${staged_out:-无输出}" >&2
    return 1
}

resolve_package_uid_u0() {
    pkg_name="$1"
    uid=
    pm_out="$(pm list packages -U --user 0 "$pkg_name" 2>/dev/null)" || pm_out=
    if [ -n "$pm_out" ]; then
        uid="$(printf '%s\n' "$pm_out" | awk -v p="package:${pkg_name}" '
            $1 == p {
                for (i = 2; i <= NF; i++) {
                    if ($i ~ /^uid:[0-9]+$/) {
                        sub(/^uid:/, "", $i)
                        print $i
                        exit
                    }
                }
            }')"
    fi
    if [ -z "$uid" ]; then
        uid="$(
            set -o pipefail
            dumpsys package "$pkg_name" 2>/dev/null | awk -v target="Package [${pkg_name}]" '
                index($0, target) && /^  Package \[/ {in_pkg=1; next}
                in_pkg && /^  Package \[/ {in_pkg=0}
                in_pkg && !seen && /^[[:space:]]+(userId|appId)=[0-9]+/ {
                    sub(/^[^=]*=/, "")
                    sub(/[^0-9].*$/, "")
                    print
                    seen=1
                }'
        )" || uid=
    fi
    if [ -z "$uid" ] && [ -d "/data/user/0/${pkg_name}" ] && [ ! -L "/data/user/0/${pkg_name}" ]; then
        uid="$(stat -c '%u' "/data/user/0/${pkg_name}" 2>/dev/null || true)"
    fi
    case "$uid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$uid" -ge 10000 ] || return 1
    printf '%s\n' "$uid"
}
