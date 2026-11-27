#!/system/bin/sh
set -eu

bb=/data/adb/ksu/bin/busybox
work="$1"
STATE_DIR='/data/adb/quickshare-pma110'
config_loaded=0
if [ -f "$work/config.env" ]; then
    # shellcheck source=config.env
    . "$work/config.env"
    config_loaded=1
fi
script_dir="$(dirname "$0")"
if [ -f "$script_dir/common.sh" ]; then
    # shellcheck source=common.sh
    . "$script_dir/common.sh"
elif [ -f "$work/common.sh" ]; then
    # shellcheck source=common.sh
    . "$work/common.sh"
fi

dir=/system_ext/etc/vintf/manifest
data=/apex/apex-info-list.xml
stock_network=/system_ext/lib64/oplusex/com.oplus.NetworkAssistSys/liboplus_network_servers.so
iface=com.google.android.moseyservice.IMoseyService/default
stage="$work/stage"
manifest="$dir/manifest_mosey.xml"
manifest_source="$stage/manifest"
apex_source="$stage/apex-copy"
vintf_lock="$STATE_DIR/vintf.lock"

mount_count() {
    awk -v path="$1" '$5 == path {n++} END { print n+0 }' /proc/self/mountinfo
}

registered() {
    "$work/query_declared" "$iface"
}

# Explicit error checking throughout rollback(): never rely on set -e when invoked under `||`.
rollback() (
    trap '' PIPE
    flock -x 8 8>&8 || exit 1
    [ -f "$work/armed" ] || exit 0
    stop_session_workers "$work" || exit 1
    finish_signal_trace "$work" || :
    if awk -v path="$dir" -v lower="lowerdir=$manifest_source:" '$5 == path && index($0, lower) { found=1 } END {exit !found}' /proc/self/mountinfo; then
        "$bb" umount "$dir" || exit 1
    fi
    if [ "$(mount_count "$data")" = 1 ] && [ -f "$apex_source" ] && [ "$(stat -c '%d:%i' "$data")" = "$(stat -c '%d:%i' "$apex_source")" ]; then
        "$bb" umount "$data" || exit 1
    fi
    [ ! -e "$manifest" ] || exit 1
    if registered | grep -Fxq 'Live service declaration present=1'; then
        [ "$(mount_count "$data")" = 0 ] || exit 1
        if ! cmp -s "$apex_source" "$data" || [ "$(stat -c %Y "$data")" = "$(stat -c %Y "$apex_source")" ]; then
            cp -p "$data" "$apex_source" || exit 1
            chcon "$(stat -c %C "$data")" "$apex_source" || exit 1
            touch -m "$apex_source" || exit 1
        fi
        cmp -s "$apex_source" "$data" || exit 1
        [ "$(stat -c %Y "$data")" != "$(stat -c %Y "$apex_source")" ] || exit 1
        "$bb" mount --bind "$apex_source" "$data" || exit 1
        refresh_result="$(registered)" || refresh_result=
        "$bb" umount "$data" || exit 1
        [ "$refresh_result" = 'Live service declaration present=0' ] || exit 1
    fi
    [ -f "$work/stock-network-sha" ] && [ "$(sha256sum "$stock_network")" = "$(cat "$work/stock-network-sha")" ] || exit 1
    registered | grep -Fxq 'Live service declaration present=0' || exit 1
    if [ "$(mount_count "$stage")" = 1 ]; then
        "$bb" umount "$stage" || exit 1
    fi
    unlink "$work/armed" || exit 1
) 8>"$work/rollback.lock"

test "$(id -u)" = 0
test "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)"

# Allow watchdog and restore to clean up without depending on config.env.
if [ "${2:-}" = watchdog ]; then
    owner="$3"
    while kill -0 "$owner" 2>/dev/null && [ -f "$work/armed" ]; do
        sleep 2
    done
    if [ -f "$work/armed" ]; then
        touch "$work/stop"
        feature="$work/feature"
        if [ -f "$feature/cache-armed" ]; then
            read -r original override < "$feature/hashes.txt"
            /system/bin/sh "$feature/cache-test.sh" "$feature" "$original" "$override" restore-only || true
        fi
        rollback || echo 'ERROR: VINTF watchdog rollback failed; armed marker preserved' >&2
    fi
    exit
fi
if [ "${2:-}" = restore ]; then
    rollback
    exit
fi

[ "$config_loaded" = 1 ] || { echo 'Missing config.env' >&2; exit 1; }
test "$(getprop ro.build.display.id)" = "$TARGET_BUILD"
ensure_root_dir "$STATE_DIR"

umask 077
exec 7>"$vintf_lock"
flock -n 7 7>&7 || { echo 'Another startup is already active' >&2; exit 1; }
printf '%s\n' "$$" > "$work/owner-pid"
test "$(getprop sys.boot_completed)" = 1
test "$(getprop apex.all.ready)" = true
test "$(getprop init.svc.servicemanager)" = running
check_no_staged_sessions
test ! -e "$manifest"
test ! -e "$work/armed"
test -f "$work/manifest_mosey.xml" && test ! -L "$work/manifest_mosey.xml"
test "$(sha256sum "$work/manifest_mosey.xml" | cut -d' ' -f1)" = "$MOSEY_MANIFEST_SHA256"
test "$(mount_count "$data")" = 0
if awk -v prefix="$dir" 'index($5, prefix)==1 {found=1} END {exit !found}' /proc/1/mountinfo; then
    echo 'Existing mount within proposed manifest directory' >&2
    exit 1
fi
manager="$(pidof servicemanager)"
framework="$(pidof system_server)"
boot_id="$(cat /proc/sys/kernel/random/boot_id)"
test "$(readlink "/proc/${manager}/ns/mnt")" = "$(readlink /proc/self/ns/mnt)"
registered | grep -Fx 'Live service declaration present=0'
stat -c '%d:%i:%Y:%C' "$data" > "$work/stock-apex-id"
sha256sum "$data" > "$work/stock-apex-sha"
sha256sum "$stock_network" > "$work/stock-network-sha"
stock_manifest="$(cd "$dir" && sha256sum ./*.xml | sort)"
mkdir "$stage"
touch "$work/armed"
trap 'rollback || echo "ERROR: VINTF rollback failed; armed marker preserved" >&2' EXIT
"$bb" nohup /system/bin/setsid /system/bin/sh -c "$LOG_THROUGH_PIPE" quickshare-log \
    "$work/watchdog.log" /system/bin/sh "$work/live-vintf.sh" "$work" watchdog "$$" \
    </dev/null >/dev/null 2>&1 7>&- &
"$bb" mount -t tmpfs -o size=2048k tmpfs "$stage"
# Keep the overlay root accessible to Android servicemanager (UID 1000).
mkdir -m "$(stat -c %a "$dir")" "$manifest_source"
cp "$work/manifest_mosey.xml" "$manifest_source/"
chmod 0644 "$manifest_source/manifest_mosey.xml"
chcon -R u:object_r:system_file:s0 "$manifest_source"
cp -p "$data" "$apex_source"
chcon "$(stat -c %C "$data")" "$apex_source"
touch -m "$apex_source"
cmp -s "$apex_source" "$data"
test "$(stat -c '%a:%u:%g:%C' "$data")" = "$(stat -c '%a:%u:%g:%C' "$apex_source")"
test "$(stat -c %Y "$data")" != "$(stat -c %Y "$apex_source")"
"$bb" mount -t overlay -o "ro,lowerdir=$manifest_source:$dir" overlay "$dir"
test "$stock_manifest" = "$(cd "$dir" && sha256sum ./*.xml | grep -Fv './manifest_mosey.xml' | sort)"
cmp -s "$manifest" "$work/manifest_mosey.xml"
test "$(sha256sum "$stock_network")" = "$(cat "$work/stock-network-sha")"
registered | grep -Fx 'Live service declaration present=0'
"$bb" mount --bind "$apex_source" "$data"
"$bb" mount -o remount,bind,ro "$data"
test "$(sha256sum "$data")" = "$(cat "$work/stock-apex-sha")"
if ! registered | grep -Fx 'Live service declaration present=1'; then
    echo 'Android 系统未读取到原厂服务声明，已停止加载。' >&2
    exit 1
fi
test "$(pidof servicemanager)" = "$manager"
test "$(pidof system_server)" = "$framework"
test "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_id"
"$bb" umount "$data"
test "$(stat -c '%d:%i:%Y:%C' "$data")" = "$(cat "$work/stock-apex-id")"
registered | grep -Fx 'Live service declaration present=1'
echo 'Original APEX metadata path restored while declaration remains active'
if [ -f "$work/probe.sh" ]; then
    /system/bin/sh "$work/probe.sh" "$work"
fi
rollback
test "$(pidof servicemanager)" = "$manager"
test "$(pidof system_server)" = "$framework"
test "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_id"
test "$(getprop sys.boot_completed)" = 1
echo 'Live declaration and rollback verified with unchanged service, framework and boot IDs'
