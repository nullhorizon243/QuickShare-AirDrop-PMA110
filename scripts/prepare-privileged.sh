#!/system/bin/sh
set -eu

script_dir="$(dirname "$0")"
[ -f "$script_dir/config.env" ] || { echo 'Missing config.env' >&2; exit 1; }
[ -f "$script_dir/common.sh" ] || { echo 'Missing common.sh' >&2; exit 1; }
# shellcheck source=config.env
. "$script_dir/config.env"
# shellcheck source=common.sh
. "$script_dir/common.sh"

tar_input="$1"
verify_file_sha256 "$tar_input" "${MOSEY_PRIV_TAR_SHA256:-}" || {
    echo 'Privileged archive SHA-256 verification failed. Rebuild the APK.' >&2
    exit 1
}

bb=/data/adb/ksu/bin/busybox
app_dir=/system/priv-app
perm_dir=/system/etc/permissions
apk=$app_dir/MoseyApp/MoseyApp.apk
xml=$perm_dir/privapp-permissions-com.google.android.mosey.xml
network=/system_ext/lib64/oplusex/com.oplus.NetworkAssistSys/liboplus_network_servers.so
ui=/system_ext/priv-app/SystemUI
leaves_dir="$STATE_DIR/leaves"

test "$(id -u)" = 0
test "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)"
test "$(getprop ro.build.display.id)" = "$TARGET_BUILD"
test "$(getprop sys.boot_completed)" = 1
test ! -e /data/adb/modules/codex-mosey-check
test ! -e /data/adb/modules_update/codex-mosey-check
test ! -e "$apk"
test ! -e "$xml"
if awk '$5 ~ /^\/system\/(priv-app|etc\/permissions)(\/|$)/ {found=1} END {exit !found}' /proc/1/mountinfo; then
    echo 'An existing mount intersects the proposed overlay.' >&2
    exit 1
fi

ensure_root_dir "$STATE_DIR"
ensure_root_dir "$leaves_dir"

network_hash="$(sha256sum "$network")"
ui_count="$(ls -A "$ui" | wc -l)"
app_count="$(ls -A "$app_dir" | wc -l)"
perm_count="$(ls -A "$perm_dir" | wc -l)"
test "$app_count" -gt 0
test "$perm_count" -gt 0
work="$(mktemp -d "${leaves_dir}/leaf.XXXXXX")"
chown 0:0 "$work" && chmod 700 "$work"
mkdir -m 700 "$work/stage"
printf '%s\n' "$(pidof system_server)" > "$work/previous-pid"
printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id)" > "$work/boot-id"

cat > "$work/rollback.sh" <<'ROLLBACK'
#!/system/bin/sh
set -eu
work="$1"
bb=/data/adb/ksu/bin/busybox
test "$(id -u)" = 0
test "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)"
case "$work" in /data/adb/quickshare-pma110/leaves/leaf.*) ;; *) exit 1 ;; esac
unmount_ours() {
    target="$1"
    source="$2"
    if awk -v p="$target" -v s="lowerdir=$source:" '
        $5==p {line=$0; count++}
        END {exit !(count==1 && index(line,s))}
    ' /proc/1/mountinfo; then
        "$bb" umount -l "$target" || exit 1
    fi
}
unmount_ours /system/etc/permissions "$work/stage/permissions"
unmount_ours /system/priv-app "$work/stage/priv-app"
if ! grep -Fq "lowerdir=$work/stage/" /proc/1/mountinfo; then
    "$bb" umount -l "$work/stage" 2>/dev/null || true
    rmdir "$work/stage" 2>/dev/null || true
fi
test -r /system_ext/lib64/oplusex/com.oplus.NetworkAssistSys/liboplus_network_servers.so
ROLLBACK

ready=no
cleanup() {
    if [ "$ready" != yes ]; then
        /system/bin/sh "$work/rollback.sh" "$work" || echo "ERROR: leaf rollback failed for ${work}" >&2
    fi
}
trap cleanup EXIT
"$bb" mount -t tmpfs -o size=16m tmpfs "$work/stage"
"$bb" tar -xf "$tar_input" -C "$work/stage"

# Verify unpacked members before mounting into /system: regular files only, zero symlinks, exact digests.
if [ -n "$(find "$work/stage" -type l)" ]; then
    echo 'Privileged archive contains disallowed symlinks.' >&2
    exit 1
fi
[ "$(find "$work/stage" -type f | wc -l)" -eq 2 ] || {
    echo 'Privileged archive contains unexpected files.' >&2
    exit 1
}
stage_apk="$work/stage/priv-app/MoseyApp/MoseyApp.apk"
stage_xml="$work/stage/permissions/privapp-permissions-com.google.android.mosey.xml"
[ -f "$stage_apk" ] && [ ! -L "$stage_apk" ] && [ -s "$stage_apk" ] || exit 1
[ -f "$stage_xml" ] && [ ! -L "$stage_xml" ] && [ -s "$stage_xml" ] || exit 1
[ "$(sha256sum "$stage_apk" | cut -d' ' -f1)" = "$MOSEY_APK_SHA256" ] || {
    echo 'Unpacked MoseyApp.apk SHA-256 mismatch.' >&2
    exit 1
}
[ "$(sha256sum "$stage_xml" | cut -d' ' -f1)" = "$MOSEY_PERM_SHA256" ] || {
    echo 'Unpacked privapp-permissions XML SHA-256 mismatch.' >&2
    exit 1
}

chown -R 0:0 "$work/stage"
chcon -R u:object_r:system_file:s0 "$work/stage"
"$bb" mount -t overlay -o "ro,lowerdir=$work/stage/priv-app:$app_dir" overlay "$app_dir"
"$bb" mount -t overlay -o "ro,lowerdir=$work/stage/permissions:$perm_dir" overlay "$perm_dir"

test -r "/proc/1/root$apk"
test -r "/proc/1/root$xml"
test "$(sha256sum "$network")" = "$network_hash"
test "$(ls -A "$ui" | wc -l)" -eq "$ui_count"
test "$(ls -A "$app_dir" | wc -l)" -eq "$((app_count + 1))"
test "$(ls -A "$perm_dir" | wc -l)" -eq "$((perm_count + 1))"

cat > "$work/watch.sh" <<'WATCHDOG'
#!/system/bin/sh
set -eu
work="$1"
old_pid="$(cat "$work/previous-pid")"
last_pid="$old_pid"
seen_new=0
for step in $(seq 1 80); do
    sleep 0.5
    test ! -e "$work/cancel" || exit 0
    pid="$(pidof system_server 2>/dev/null || true)"
    state="$(getprop sys.boot_completed)"
    if [ -n "$pid" ] && [ "$pid" != "$old_pid" ]; then
        if [ "$state" = 1 ]; then
            printf 'boot_completed PID %s\n' "$pid" > "$work/watch-result"
            exit 0
        fi
        if [ "$pid" != "$last_pid" ]; then
            seen_new=$((seen_new + 1))
            last_pid="$pid"
            if [ "$seen_new" -ge 2 ]; then
                echo 'framework restarted more than once' > "$work/watch-result"
                break
            fi
        fi
    fi
done
if [ ! -e "$work/watch-result" ]; then echo 'framework startup timed out' > "$work/watch-result"; fi
/system/bin/sh "$work/rollback.sh" "$work"
echo 'temporary overlays withdrawn' >> "$work/watch-result"
WATCHDOG

ready=yes
printf 'WORK=%s\n' "$work"
printf 'Original network library and SystemUI remain visible in PID 1 namespace.\n'
