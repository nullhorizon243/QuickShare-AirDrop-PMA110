#!/system/bin/sh
set -eu

tar_input="$1"
testdir="$2"
parent="${testdir%/*}"

[ -f "$testdir/config.env" ] || { echo 'Missing config.env' >&2; exit 1; }
[ -f "$testdir/common.sh" ] || { echo 'Missing common.sh' >&2; exit 1; }
# shellcheck source=config.env
. "$testdir/config.env"
# shellcheck source=common.sh
. "$testdir/common.sh"

verify_file_sha256 "$tar_input" "${MOSEY_DAEMON_TAR_SHA256:-}" || {
    echo 'Daemon archive SHA-256 verification failed. Rebuild the APK.' >&2
    exit 1
}

bb=/data/adb/ksu/bin/busybox
iface=com.google.android.moseyservice.IMoseyService/default
network=/system_ext/lib64/oplusex/com.oplus.NetworkAssistSys/liboplus_network_servers.so
action=com.google.android.gms.nearby.QUICK_SHARE
provider=com.google.android.mosey/.ExternalSharingService
mounts_dir="$STATE_DIR/mounts"

test "$(id -u)" = 0
test "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)"
test "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)"
if grep -q ' shared:' /proc/self/mountinfo; then exit 1; fi
test -r "/proc/1/root$network"
case "$(service check "$iface")" in *'not found') ;; *) exit 1 ;; esac

ensure_root_dir "$STATE_DIR"
ensure_root_dir "$mounts_dir"
record_process "$testdir/native-monitor" "$$"

scratch="$(mktemp -d "${mounts_dir}/mount.XXXXXX")"
chown 0:0 "$scratch" && chmod 700 "$scratch"
mounted_scratch=0
mounted_bin=0
mounted_lib=0
supervisor=
exit_reason=startup-failed
radio_before="$(cat /sys/class/net/wonder0/flags 2>/dev/null || true)"
reset_radio() {
    case "$radio_before" in 0x1002|0x1000|"")
        if [ -d /sys/class/net/wondertap0 ]; then
            ip link set dev wonder0 down
            log_note 'Test radio released'
        fi
        ;;
    esac
}
record_exit() {
    if printf '%s|%s|%s\n' "$(date '+%F %T %z')" "$exit_reason" "$1" >"$parent/native-exit.tmp"; then
        mv -f "$parent/native-exit.tmp" "$parent/native-exit"
    fi
    log_note "Native probe exit=$1 reason=$exit_reason"
}

cleanup() {
    trap '' PIPE
    rm -f "$parent/ready" "$parent/native-restarting"
    if [ -n "$supervisor" ]; then
        if [ -e "$parent/stop-requested" ]; then exit_reason=user-stop; fi
        result=0
        kill -TERM "$supervisor" 2>/dev/null || true
        stop_recorded_process "$testdir/native-process" || return 1
        wait "$supervisor" 2>/dev/null || result=$?
        record_exit "$result" || true
    fi
    finish_signal_trace "$parent" || :
    reset_radio
    if [ "$mounted_lib" = 1 ]; then umount /system_ext/lib64 || true; fi
    if [ "$mounted_bin" = 1 ]; then umount /system_ext/bin || true; fi
    if [ "$mounted_scratch" = 1 ]; then umount "$scratch" || true; fi
    rmdir "$scratch" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit_reason=monitor-signal; exit 143' TERM
"$bb" mount -t tmpfs -o size=32m tmpfs "$scratch"
mounted_scratch=1
"$bb" tar -xf "$tar_input" -C "$scratch" ./bin ./lib64

# Verify unpacked daemon members before mounting: regular files only, zero symlinks, verified digests.
if [ -n "$(find "$scratch" -type l)" ]; then
    echo 'Daemon archive contains disallowed symlinks.' >&2
    exit 1
fi
[ "$(find "$scratch" -type f | wc -l)" -eq 3 ] || {
    echo 'Daemon archive contains unexpected files.' >&2
    exit 1
}
for req in "$scratch/bin/mosey_server" "$scratch/lib64/libmosey_daemon_ffi.so" "$scratch/lib64/libmosey_local_binder.so"; do
    [ -f "$req" ] && [ ! -L "$req" ] && [ -s "$req" ] || { echo "Missing or invalid daemon member: ${req}" >&2; exit 1; }
done
[ "$(sha256sum "$scratch/bin/mosey_server" | cut -d' ' -f1)" = "$MOSEY_SERVER_SHA256" ] || {
    echo 'Unpacked mosey_server SHA-256 mismatch.' >&2
    exit 1
}
[ "$(sha256sum "$scratch/lib64/libmosey_daemon_ffi.so" | cut -d' ' -f1)" = "$MOSEY_DAEMON_FFI_SHA256" ] || {
    echo 'Unpacked libmosey_daemon_ffi.so SHA-256 mismatch.' >&2
    exit 1
}
verify_file_sha256 "$scratch/lib64/libmosey_local_binder.so" "${MOSEY_SHIM_SHA256:-}" || {
    echo 'Unpacked libmosey_local_binder.so SHA-256 mismatch.' >&2
    exit 1
}

chown -R 0:0 "$scratch"
chcon -R u:object_r:system_file:s0 "$scratch"
chcon u:object_r:mosey_server_exec:s0 "$scratch/bin/mosey_server"
chcon u:object_r:system_lib_file:s0 "$scratch/lib64" "$scratch/lib64/"*.so
"$bb" mount -t overlay -o "ro,lowerdir=$scratch/bin:/system_ext/bin" overlay /system_ext/bin
mounted_bin=1
"$bb" mount -t overlay -o "ro,lowerdir=$scratch/lib64:/system_ext/lib64" overlay /system_ext/lib64
mounted_lib=1
test -r "/proc/1/root$network"

start_native() {
    /system/bin/sh -c "$RUN_RECORDED_PROCESS" quickshare-native "$parent" native-process "$$" \
        env LD_PRELOAD=/system_ext/lib64/libmosey_local_binder.so /system_ext/bin/mosey_server \
        >"$scratch/server.log" 2>&1 &
    supervisor=$!
    for i in 1 2 3 4 5; do
        sleep 0.5
        kill -0 "$supervisor" 2>/dev/null || return 1
        case "$(service check "$iface")" in *': found') return 0 ;; esac
    done
    return 1
}

refresh_provider() {
    if dumpsys package com.google.android.mosey | grep -Eq '^ +com[.]google[.]android[.]mosey[./]ExternalSharingService[[:space:]]*$'; then
        echo 'Extension component already explicitly configured, skipping re-registration'
        return
    fi
    cmd package query-services --brief --user 0 -a com.google.android.nearby.SHARING_PROVIDER -p com.google.android.mosey | grep -F "$provider" || return 1
    touch "$testdir/component-armed" || return 1
    pm disable --user 0 "$provider" || return 1
    sleep 1
    pm default-state --user 0 "$provider" || return 1
    rm "$testdir/component-armed" || return 1
    cmd package query-services --brief --user 0 -a com.google.android.nearby.SHARING_PROVIDER -p com.google.android.mosey | grep -F "$provider"
}

requested_stop() {
    if [ -e "$parent/stop-requested" ]; then
        echo user-stop
    elif [ -e "$parent/stop" ]; then
        echo recovery-stop
    fi
}

read_pid() {
    local pid
    pid="$(pidof "$1")" || return 1
    case "$pid" in ''|0|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$pid"
}

sample_framework() {
    observed_boot="$(getprop sys.boot_completed)" || observed_boot=
    observed_framework="$(read_pid system_server)" || observed_framework=
    observed_manager="$(read_pid servicemanager)" || observed_manager=
}

framework_unchanged() {
    sample_framework
    [ "$observed_boot" = 1 ] && [ "$observed_framework" = "$framework" ] &&
        [ "$observed_manager" = "$manager" ]
}

monitor_native() {
    local cause change pending_change= status=0
    exit_reason=unexpected-exit
    while kill -0 "$supervisor" 2>/dev/null; do
        cause="$(requested_stop)"
        if [ -z "$cause" ]; then
            sample_framework
            change=
            # Empty or invalid samples give no evidence that the running session changed.
            if [ "$observed_boot" = 0 ]; then
                change='sys.boot_completed=0'
            elif [ -n "$observed_framework" ] && [ "$observed_framework" != "$framework" ]; then
                change="system_server PID $framework -> $observed_framework"
            elif [ -n "$observed_manager" ] && [ "$observed_manager" != "$manager" ]; then
                change="servicemanager PID $manager -> $observed_manager"
            fi
            if [ -n "$change" ] && [ "$change" = "$pending_change" ]; then
                printf 'Confirmed Android framework change: %s\n' "$change"
                cause=framework-change
            fi
            pending_change="$change"
        fi
        if [ -n "$cause" ]; then
            exit_reason="$cause"
            kill -TERM "$supervisor" 2>/dev/null || true
            stop_recorded_process "$testdir/native-process" || return 1
            break
        fi
        sleep 2
    done
    wait "$supervisor" || status=$?
    supervisor=
    finish_signal_trace "$parent" || :
    record_exit "$status" || true
    reset_radio
}

mark_native_ready() {
    local since
    since="$(uptime_seconds)" || since=
    printf '%s\n' "$since" >"$parent/healthy-since.tmp" &&
        mv -f "$parent/healthy-since.tmp" "$parent/healthy-since" &&
        touch "$parent/ready" "$parent/activated"
}

nearby_cache_enabled() (
    read -r cache <"$testdir/cache-path" || exit 1
    [ -f "$cache" ] && [ ! -L "$cache" ] || exit 1
    [ "$("$parent/nearby-flag" --status "$cache" 2>/dev/null)" = enabled ]
)

recover_native() {
    touch "$parent/native-restarting" || return 1
    rm -f "$parent/ready"
    # Only recover inside the current, still valid activation.
    [ -z "$(requested_stop)" ] && framework_unchanged || return 1
    sed -n '1,12p' "$scratch/server.log"
    echo 'Attempting automatic native restart'
    exit_reason=startup-failed
    start_native || return 1
    [ -z "$(requested_stop)" ] && framework_unchanged || return 1
    refresh_provider || return 1
    for step in $(seq 1 12); do
        [ -z "$(requested_stop)" ] && framework_unchanged || return 1
        kill -0 "$supervisor" 2>/dev/null || return 1
        if provider_bound && service check "$iface" | grep -q ': found$' && nearby_cache_enabled; then
            mark_native_ready && touch "$parent/native-recovered" || return 1
            rm -f "$parent/native-restarting"
            echo 'Native restart succeeded and Google Play services reconnected'
            return 0
        fi
        sleep 1
    done
    return 1
}

monitor_with_recovery() {
    local inline_used=0 since
    while :; do
        since="$(cat "$parent/healthy-since")" || since=
        monitor_native
        if [ "$exit_reason" != unexpected-exit ] || [ -n "$(requested_stop)" ] || ! framework_unchanged; then
            return 0
        fi
        if recovery_window_elapsed "$since"; then
            touch "$parent/recovery-rearmed"
            inline_used=0
        fi
        if [ "$inline_used" = 1 ]; then
            echo 'Native process exited again within the recovery interval'
            return 0
        fi
        inline_used=1
        if ! recover_native; then
            echo 'Automatic native restart did not complete; rolling back'
            return 1
        fi
    done
}

stamp="$(date '+%m-%d %H:%M:%S.000')"
if ! framework="$(read_pid system_server)" || ! manager="$(read_pid servicemanager)"; then
    echo 'Cannot establish the Android framework PIDs' >&2
    exit 1
fi
if ! start_native; then
    echo 'Native Binder failed to register' >&2
    exit 1
fi
echo 'Native Binder registered=yes'
if [ ! -e "$parent/automatic-load" ]; then
    /system/bin/input keyevent KEYCODE_HOME
fi
/system/bin/am start -W --user 0 -a "$action" -p com.google.android.gms
sleep 3
refresh_provider
sleep 7
echo 'After package manager component re-registration'
dumpsys activity services com.google.android.mosey |
    grep -E '(nothing)|ExternalSharingService|ConnectionRecord|app=ProcessRecord' | head -n 15
service check "$iface"
if ! provider_bound; then
    echo 'Quick Share did not connect to the extension, rolling back' >&2
    exit 1
fi
mark_native_ready
echo 'Ready for manual tests. Waiting for a stop request.'
monitor_with_recovery
sed -n '1,12p' "$scratch/server.log"
logcat -b main -b system -b crash -d -v brief -T "$stamp" |
    grep -Ei 'com.google.android.mosey|libbinder.AidlLazyServiceRegistrar|mosey_server|ReceiveManagerStart|Mosey|Awdl.*(error|fail)|Skipping provider|Bound to provider|Connected to provider|AirDrop|INITIALIZATION_COMPLETED|Registered service result|Failed to bind to provider|external provider registry|ReceiveManagerStart' |
    grep -Evi 'adbd|BtScan[.]ScanController|AppsFilter|DexOptimize|D/PackageManager|ImsResolver|ShortcutService|PluginManagerImpl|Satellite|OCSCacheHelper|CarrierSvcBindHelper|IconDebug|W/ActivityManager: Skipping manifest' | sed -E 's/(localDeviceName=)[^,)]*/\1[omitted]/g' | sed -E 's/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/[MAC]/g' | cut -c 1-245 | tail -n 48
case "$(service check "$iface")" in
    *'not found') echo 'Temporary Binder service stopped' ;;
    *) exit 1 ;;
esac
test -r "/proc/1/root$network"
