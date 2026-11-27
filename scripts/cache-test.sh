#!/system/bin/sh
set -eu
bb=/data/adb/ksu/bin/busybox
work="$1"
original="$2"
override="$3"

script_dir="$(dirname "$0")"
if [ -f "$script_dir/common.sh" ]; then
    # shellcheck source=common.sh
    . "$script_dir/common.sh"
elif [ -f "$work/common.sh" ]; then
    # shellcheck source=common.sh
    . "$work/common.sh"
else
    echo 'Missing common.sh' >&2
    exit 1
fi

package=com.google.android.gms
[ -f "$work/cache-path" ] && [ ! -L "$work/cache-path" ] || exit 1
cache="$(cat "$work/cache-path")"
case "$cache" in /data/user/0/com.google.android.gms/app_phenotype_shared/*/h6omGAQ-2fOaCXXuzmJOPA==.pb) ;; *) exit 1 ;; esac
parent="${work%/*}"
suffix="${parent##*.}"
backup="${cache%/*}/.codex-mosey-original.${suffix}"
staged="${cache%/*}/.codex-mosey-test.${suffix}"
lock="$work/rollback-lock"
mosey=com.google.android.mosey
provider=$mosey/.ExternalSharingService
coarse=android.permission.ACCESS_COARSE_LOCATION
background=android.permission.ACCESS_BACKGROUND_LOCATION
fine=android.permission.ACCESS_FINE_LOCATION

permission_state() {
    dumpsys package "$mosey" 2>/dev/null | awk -v permission="$1" '
        /^  Package \[/ {pkg++}
        pkg == 1 && /^    User 0:/ {u=1}
        pkg == 1 && /^    User [0-9]+:/ && !/^    User 0:/ {u=0}
        u && $1 == permission ":" && !seen {gsub(/.*granted=/, ""); sub(/,.*/, ""); print; seen=1}'
}
filewatch=
stop_filewatch() {
    if [ -n "$filewatch" ]; then
        kill "$filewatch" 2>/dev/null || true
        wait "$filewatch" 2>/dev/null || true
        filewatch=
    fi
}

digest() {
    sha256sum "$1" | cut -d' ' -f1
}

# Outputs PID of the main GMS process if running, empty if not running.
# Returns non-zero if UID lookup itself fails (so callers never mistake lookup error for exit).
main_pid() {
    target_uid="$(resolve_package_uid_u0 "$package")" || return 1
    for pid in $(pidof "$package" 2>/dev/null || true); do
        name="$(tr '\000' '\n' </proc/"$pid"/cmdline 2>/dev/null | head -1)"
        if [ "$name" = "$package" ]; then
            awk -v u="$target_uid" '/^Uid:/ {exit ($2 != u)}' /proc/"$pid"/status || continue
            printf '%s\n' "$pid"
            return 0
        fi
    done
    return 0
}

restart_nearby() {
    process="$(main_pid)" || {
        echo 'Failed to resolve Google Play services UID/PID' >&2
        return 1
    }
    [ -n "$process" ] || return 0
    kill -TERM "$process" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        current="$(main_pid)" || {
            echo 'Failed to re-check Google Play services UID/PID after SIGTERM' >&2
            return 1
        }
        [ "$current" = "$process" ] || return 0
        sleep 0.2
    done
    return 1
}

# Explicit error checking throughout restore(): never rely on set -e when invoked under `||`.
restore() (
    trap '' PIPE
    flock -x 9 9>&9 || exit 1
    stop_session_workers "$parent" || exit 1
    if [ -f "$work/component-armed" ]; then
        restore_output="$(pm default-state --user 0 "$provider" 2>&1)" || { log_note "$restore_output" >&2; exit 1; }
        /system/bin/rm "$work/component-armed" || exit 1
    fi
    [ -f "$work/cache-armed" ] || exit 0
    if [ "$original" != "$override" ] && [ -f "$cache" ] && [ ! -L "$cache" ] && [ "$(digest "$cache")" = "$override" ]; then
        [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(digest "$backup")" = "$original" ] || exit 1
        mv -fT "$backup" "$cache" || exit 1
        [ "$(digest "$cache")" = "$original" ] || exit 1
        log_note 'Original Nearby cache restored and verified'
    elif [ -f "$cache" ] && [ ! -L "$cache" ]; then
        log_note 'Copy already replaced by original or newer cache'
    else
        [ -f "$backup" ] && [ ! -L "$backup" ] && [ "$(digest "$backup")" = "$original" ] || exit 1
        ln "$backup" "$cache" || exit 1
        [ "$(digest "$cache")" = "$original" ] || exit 1
        log_note 'Original Nearby cache recreated and verified'
    fi
    if [ -f "$backup" ]; then /system/bin/rm "$backup" || exit 1; fi
    if [ -f "$staged" ]; then /system/bin/rm "$staged" || exit 1; fi
    if [ -f "$work/cache-installed" ]; then
        restore_output="$(restart_nearby 2>&1)" || {
            log_note "Could not restart the Google Play services main process after rollback: $restore_output" >&2
            exit 1
        }
    fi
    if [ -f "$work/background-armed" ]; then
        if [ "$(permission_state "$background")" = true ]; then
            restore_output="$(pm revoke --user 0 "$mosey" "$background" 2>&1)" || { log_note "$restore_output" >&2; exit 1; }
        fi
        [ "$(permission_state "$background")" = false ] || exit 1
        /system/bin/rm "$work/background-armed" || exit 1
        log_note 'Background location restored to denied'
    fi
    if [ -f "$work/coarse-armed" ]; then
        if [ "$(permission_state "$coarse")" = true ]; then
            restore_output="$(pm revoke --user 0 "$mosey" "$coarse" 2>&1)" || { log_note "$restore_output" >&2; exit 1; }
        fi
        [ "$(permission_state "$coarse")" = false ] || exit 1
        /system/bin/rm "$work/coarse-armed" || exit 1
        log_note 'Approximate location restored to denied'
    fi
    if [ -f "$work/cache-installed" ]; then
        /system/bin/rm "$work/cache-installed" || exit 1
    fi
    /system/bin/rm "$work/cache-armed" || exit 1
) 9>"$lock"

if [ "${4:-}" = watchdog ]; then
    owner="$5"
    while kill -0 "$owner" 2>/dev/null && [ -f "$work/cache-armed" ]; do
        sleep 2
    done
    if [ -f "$work/cache-armed" ]; then
        touch "$parent/stop"
        restore || echo 'ERROR: cache watchdog restore failed; cache-armed preserved' >&2
    fi
    exit
fi

if [ "${4:-}" = restore-only ]; then
    restore
    exit
fi

test "$(id -u)" = 0
test "$(getprop sys.boot_completed)" = 1
if ! user_state="$(am get-started-user-state 0 2>&1)" || [ "$user_state" != RUNNING_UNLOCKED ]; then
    printf 'Unable to verify User 0 is unlocked: %s\n' "${user_state:-no response}" >&2
    exit 1
fi
test -f "$cache" && test ! -L "$cache" && test "$(digest "$cache")" = "$original"
test -f "$work/nearby-test.pb" && test ! -L "$work/nearby-test.pb" && test "$(digest "$work/nearby-test.pb")" = "$override"
expected_uid="$(resolve_package_uid_u0 "$package")"
test "$(stat -c '%a:%u:%g' "$cache")" = "644:${expected_uid}:${expected_uid}"
test ! -e "$backup" && test ! -e "$staged" && test ! -e "$work/cache-armed"
initial_pid="$(main_pid)" || { echo 'Failed to resolve Google Play services before loading' >&2; exit 1; }
if [ -z "$initial_pid" ] && [ ! -e "$parent/automatic-load" ]; then
    echo 'Open Quick Share once so the Google Play services main process can start' >&2
    exit 1
fi
coarse_before="$(permission_state "$coarse")"
background_before="$(permission_state "$background")"
fine_before="$(permission_state "$fine")"
case "${coarse_before}:${background_before}:${fine_before}" in
    true:true:true|true:false:true|true:true:false|true:false:false|false:false:false) ;;
    *) echo 'Unexpected starting location permission state' >&2; exit 1 ;;
esac
stamp="$(date '+%m-%d %H:%M:%S.000')"
touch "$work/cache-armed"
trap 'stop_filewatch; restore || echo "ERROR: cache restore failed; cache-armed preserved" >&2' EXIT
"$bb" nohup /system/bin/setsid /system/bin/sh -c "$LOG_THROUGH_PIPE" quickshare-log \
    "$work/cache-watchdog.log" /system/bin/sh "$work/cache-test.sh" "$work" "$original" "$override" watchdog "$$" \
    </dev/null >/dev/null 2>&1 7>&- &

if [ "$coarse_before" = false ]; then
    touch "$work/coarse-armed"
    pm grant --user 0 "$mosey" "$coarse"
fi
test "$(permission_state "$coarse")" = true
if [ "$background_before" = false ]; then
    touch "$work/background-armed"
    pm grant --user 0 "$mosey" "$background"
fi
test "$(permission_state "$background")" = true
test "$(permission_state "$fine")" = "$fine_before"
echo 'Checked background and approximate location for this session'
if [ "$original" != "$override" ]; then
    ln "$cache" "$backup"
    cp -p "$cache" "$staged"
    expected_context="$(stat -c %C "$cache")"
    chcon "$expected_context" "$staged"
    cat "$work/nearby-test.pb" >"$staged"
    test "$(stat -c '%a:%u:%g:%C' "$staged")" = "$(stat -c '%a:%u:%g:%C' "$cache")"
    test "$(digest "$staged")" = "$override"
    test "$(digest "$cache")" = "$original"
    touch "$work/cache-installed"
    mv -fT "$staged" "$cache"
    test "$(digest "$cache")" = "$override"
    echo 'One flag present in test cache'
else
    echo "Nearby flag is already enabled in the original cache"
fi
/system/bin/sh -c "$RUN_RECORDED_PROCESS" quickshare-filewatch "$parent" filewatch-process "$$" \
    "$bb" inotifyd - "$cache:ar" >"$work/cache-access.log" 2>&1 &
filewatch=$!
oldpid="$(main_pid)"
restart_nearby
if [ -n "$oldpid" ]; then
    echo "Reloaded the main process (old PID ${oldpid})"
else
    echo 'Google Play services main process was idle; Quick Share will start it as needed'
fi
"$bb" unshare -m --propagation private /system/bin/sh "$work/probe.sh" "$work/payload.tar" "$work" || true
stop_filewatch
restore
printf 'Cache read events during probe: '
grep -c "^a[[:space:]]" "$work/cache-access.log" || true
echo "Test main process PID $(main_pid || true)"
echo "Test cache SHA-256 $(digest "$cache")"
logcat -b main -b system -d -v brief -T "$stamp" |
    grep -Ei 'FilePhenotypeFlags.*(45704091|nearby)|Failure.*mosey|com.google.android.mosey.*(isVintfDeclared|not in VINTF|start proc|bad version|not whitelisted)|ExternalSharingService.*(bind|crash|died)' |
    grep -vi adbd | cut -c 1-280 | tail -n 30
