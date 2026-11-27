#!/system/bin/sh
set -eu
umask 077

bundle="$1"
action="$2"
extra="${3:-}"
allow_gms_code=
case "$extra" in
    '') ;;
    --allow-gms-code=*)
        allow_gms_code="${extra#--allow-gms-code=}"
        case "$allow_gms_code" in ''|*[!0-9]*) echo '参数无效。' >&2; exit 1 ;; esac
        ;;
    *) echo '参数无效。' >&2; exit 1 ;;
esac

[ -f "$bundle/common.sh" ] || { echo '缺少公共脚本 common.sh。' >&2; exit 1; }
# shellcheck source=common.sh
. "$bundle/common.sh"

# Default fallback values allow status/stop/logs cleanup even if config.env were absent.
STATE_DIR='/data/adb/quickshare-pma110'
config_loaded=0
if [ -f "$bundle/config.env" ]; then
    # shellcheck source=config.env
    . "$bundle/config.env"
    config_loaded=1
fi

state="$STATE_DIR"
runs_dir="$state/runs"
leaves_dir="$state/leaves"
tmp_dir="$state/tmp"
gms=com.google.android.gms
mosey=com.google.android.mosey
iface=com.google.android.moseyservice.IMoseyService/default
bb=/data/adb/ksu/bin/busybox
ksud=/data/adb/ksud
cache_dir=/data/user/0/com.google.android.gms/app_phenotype_shared
cache_name=h6omGAQ-2fOaCXXuzmJOPA==.pb
checked_gms_code=

fail() {
    echo "$*" >&2
    exit 1
}

require_config() {
    [ "$config_loaded" = 1 ] || fail '缺少环境配置文件 config.env。'
    [ -n "${TARGET_DEVICE:-}" ] && [ -n "${TARGET_BUILD:-}" ] && [ -n "${MOSEY_APK_SHA256:-}" ] ||
        fail '环境配置文件 config.env 缺少必要字段。'
}

digest() { sha256sum "$1" | cut -d' ' -f1; }
boot_id() { cat /proc/sys/kernel/random/boot_id; }

privileged() {
    dump_out="$(dumpsys package "$mosey" 2>/dev/null)" || return 1
    printf '%s\n' "$dump_out" | awk -v target="$mosey" '
        /^Hidden system packages:/ {exit}
        /^[^[:space:]]/ {in_pkg=0}
        /^  Package \[/ {in_pkg=index($0, "Package [" target "]") != 0; user=""; next}
        !in_pkg {next}
        /privatePkgFlags=\[.*[[:space:]\[]PRIVILEGED[[:space:]\]]/ {priv=1}
        /^    User [0-9]+:/ {
            user=$2
            if (user == "0:" && $0 ~ /[[:space:]]installed=true([[:space:]]|$)/ &&
                $0 ~ /[[:space:]]enabled=[01]([[:space:]]|$)/) u0_ok=1
        }
        (user == "" || user == "0:") && /android[.]permission[.]BLUETOOTH_PRIVILEGED: granted=true([,[:space:]]|$)/ {bt=1}
        (user == "" || user == "0:") && /android[.]permission[.]MANAGE_WIFI_INTERFACES: granted=true([,[:space:]]|$)/ {wifi=1}
        END {exit !(priv && u0_ok && bt && wifi)}'
}

native_running() {
    service check "$iface" | grep -q ': found$'
}

manifest_mounted() {
    awk -v lower="lowerdir=$1/stage/manifest:" '
        $5=="/system_ext/etc/vintf/manifest" && index($0,lower) {found=1}
        END {exit !found}' /proc/1/mountinfo
}

starting() {
    [ -f "$1/owner-pid" ] && [ ! -L "$1/owner-pid" ] || return 1
    pid="$(cat "$1/owner-pid")"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/${pid}/cmdline" ] &&
        tr '\000' ' ' <"/proc/${pid}/cmdline" | grep -Fq "$1/live-vintf.sh $1"
}

run_valid() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    case "$1" in "${runs_dir}"/run.*) ;; *) return 1 ;; esac
    suffix="${1##*.}"
    case "$suffix" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
    [ "$(stat -c '%a:%u:%g' "$1" 2>/dev/null || true)" = '700:0:0' ]
}

active() {
    [ -d "$runs_dir" ] && [ ! -L "$runs_dir" ] || return 1
    for run in "$runs_dir"/run.*; do
        run_valid "$run" || continue
        if [ -f "$run/ready" ] && [ ! -e "$run/stop" ] && manifest_mounted "$run"; then
            native_running && return 0
        fi
    done
    return 1
}

leaf_mounted() {
    awk -v app="lowerdir=$1/stage/priv-app:" -v perm="lowerdir=$1/stage/permissions:" '
        $5=="/system/priv-app" && index($0,app) {a++}
        $5=="/system/etc/permissions" && index($0,perm) {p++}
        END {exit !(a==1 && p==1)}' /proc/1/mountinfo
}

leaf_valid() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    case "$1" in "${leaves_dir}"/leaf.*) ;; *) return 1 ;; esac
    suffix="${1##*.}"
    case "$suffix" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
    [ "$(stat -c '%a:%u:%g' "$1" 2>/dev/null || true)" = '700:0:0' ]
}

mounted_leaf() {
    [ -d "$leaves_dir" ] && [ ! -L "$leaves_dir" ] || return 1
    for leaf in "$leaves_dir"/leaf.*; do
        if leaf_valid "$leaf" && leaf_mounted "$leaf"; then
            echo "$leaf"
            return 0
        fi
    done
    return 1
}

prepared_leaf() {
    [ -f "$state/prepared" ] && [ ! -L "$state/prepared" ] &&
        read -r leaf prepared_boot prepared_pid <"$state/prepared" || return 1
    leaf_valid "$leaf" || return 1
    [ "$prepared_boot" = "$(boot_id)" ] &&
        [ "$prepared_pid" = "$(pidof system_server)" ] &&
        leaf_mounted "$leaf" || return 1
    echo "$leaf"
}

gms_version() {
    local ver
    ver="$(
        set -o pipefail
        dumpsys package "$gms" 2>/dev/null | awk '
            /^[[:space:]]+versionCode=/ && !seen {split($1,a,"="); print a[2]; seen=1}'
    )" || return 1
    case "$ver" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$ver"
}

check_gms_code() {
    code="$(gms_version)" || fail '无法读取 Google Play 服务（com.google.android.gms）的版本信息。'
    if [ "$code" != "$VERIFIED_GMS_CODE" ]; then
        if [ "$allow_gms_code" != "$code" ]; then
            printf '\nGMS_MISMATCH|%s|%s|%s\n' "$code" "$VERIFIED_GMS_NAME" "$VERIFIED_GMS_CODE"
            exit 42
        fi
        echo "已确认兼容加载：当前 Google Play 服务版本为 ${code}（已验证基准为 ${VERIFIED_GMS_NAME} / ${VERIFIED_GMS_CODE}）。"
    fi
    checked_gms_code="$code"
}

require_same_gms() {
    current_code="$(gms_version)" || fail '无法重新读取 Google Play 服务版本。'
    [ "$current_code" = "$checked_gms_code" ] ||
        fail "操作中检测到 Google Play 服务版本变为 ${current_code}，已停止后续步骤。请查看状态后重新操作。"
}

check_build() {
    require_config
    [ "$(getprop ro.product.model)" = "$TARGET_DEVICE" ] ||
        fail "这份工具默认仅供 ${TARGET_DEVICE} 使用。"
    actual_build="$(getprop ro.build.display.id)"
    [ "$actual_build" = "$TARGET_BUILD" ] ||
        fail "当前系统版本（${actual_build:-未知}）与配置的已验证版本（${TARGET_BUILD}）不一致。如需适配新固件，请修改 scripts/config.env 后重新构建。"
    [ "$(am get-started-user-state 0 2>/dev/null)" = RUNNING_UNLOCKED ] &&
        [ "$(getprop sys.boot_completed)" = 1 ] || fail '请解锁手机，等桌面完全加载后再试。'
    [ -x "$bb" ] && [ -x "$ksud" ] || fail '未找到 KernelSU 工具（/data/adb/ksud 与 busybox）。本工具目前仅适配 KernelSU。'
    check_no_staged_sessions || exit 1
}

verify_apk() {
    require_config
    require_installed="${1:-optional}"
    pkg_list="$(pm list packages --user 0 "$mosey" 2>&1)" ||
        fail "无法查询用户 0 的已安装包状态：${pkg_list:-命令失败}"
    if ! printf '%s\n' "$pkg_list" | grep -Fxq "package:${mosey}"; then
        if [ "$require_installed" = required ]; then
            fail '未检测到用户 0 已生效的 Quick Share Extension。'
        fi
        return 0
    fi
    existing="$(pm path --user 0 "$mosey" 2>&1)" ||
        fail "无法查询 Quick Share Extension 安装路径：${existing:-命令失败}"
    [ -n "$existing" ] || fail 'Quick Share Extension 路径返回为空，无法确认安装状态。'
    case "$existing" in *'
'*) fail '检测到 Quick Share Extension 存在拆分包更新（可能来自 Play 商店）。请先卸载该扩展或卸载其更新后重试。' ;; esac
    case "$existing" in package:/data/app/*/base.apk|package:/system/priv-app/MoseyApp/MoseyApp.apk) ;;
        *) fail '当前 Quick Share Extension 安装路径不符合预期，请先卸载后重试。' ;;
    esac
    apk_path="${existing#package:}"
    [ -f "$apk_path" ] && [ ! -L "$apk_path" ] || fail 'Quick Share Extension 文件状态异常。'
    [ "$(digest "$apk_path")" = "$MOSEY_APK_SHA256" ] ||
        fail '当前已安装的 Quick Share Extension 与本包原厂组件版本不一致。请先卸载该扩展或其更新后重试。'
}

restore_stale() {
    [ -d "$runs_dir" ] && [ ! -L "$runs_dir" ] || return 0
    for run in "$runs_dir"/run.*; do
        run_valid "$run" || continue
        if starting "$run"; then
            fail '还有一个会话正在运行或退出。请稍后查看状态。'
        fi
        touch "$run/stop"
        stop_session_workers "$run" || fail '上次会话的后台进程尚未退出。'
        finish_signal_trace "$run" || :
        if manifest_mounted "$run"; then
            [ -f "$run/armed" ] && [ ! -L "$run/armed" ] ||
                fail '发现缺少回滚标记的 VINTF 挂载，已暂停清理。'
            if native_running; then
                fail '旧会话的后台仍在运行，请先点「撤回」。'
            fi
        fi
        feature="$run/feature"
        if [ -f "$feature/cache-armed" ] || [ -f "$feature/component-armed" ]; then
            [ -d "$feature" ] && [ ! -L "$feature" ] ||
                fail '发现异常会话目录。'
            [ -f "$feature/cache-path" ] && [ ! -L "$feature/cache-path" ] ||
                fail '旧会话缺少配置路径记录。'
            read -r original override <"$feature/hashes.txt" || fail '旧会话缺少校验记录。'
            [ "${#original}" = 64 ] && [ "${#override}" = 64 ] ||
                fail '旧会话校验记录异常。'
            case "$original$override" in *[!0-9a-f]*) fail '旧会话校验记录异常。' ;; esac
            cp "$bundle/common.sh" "$feature/common.sh" 2>/dev/null || true
            /system/bin/sh "$bundle/cache-test.sh" "$feature" "$original" "$override" restore-only ||
                fail '上次的临时设置没有完整撤回。请查看日志。'
            echo '已处理前一次重启留下的临时设置。'
        fi
        if [ -f "$run/armed" ] && [ ! -L "$run/armed" ]; then
            /system/bin/sh "$bundle/live-vintf.sh" "$run" restore ||
                fail '上次的 VINTF 挂载或缓存状态尚未完整撤回。请查看日志。'
            if manifest_mounted "$run"; then
                fail '上次的 VINTF 挂载仍存在，已暂停操作。'
            fi
        fi
        if [ -f "$run/ready" ] && [ ! -L "$run/ready" ]; then
            unlink "$run/ready"
        fi
    done
}

cache_path() {
    paths="$(find "$cache_dir" -maxdepth 2 -type f -name "$cache_name" 2>/dev/null)"
    case "$paths" in *'
'*|'' ) return 1 ;; esac
    account_dir="${paths%/*}"
    account="${account_dir##*/}"
    case "$account" in ''|*[!A-Za-z0-9_=-]*) return 1 ;; esac
    [ "$paths" = "${cache_dir}/${account}/${cache_name}" ] || return 1
    [ ! -L "$paths" ] && [ ! -L "$account_dir" ] || return 1
    printf '%s\n' "$paths"
}

cache_mode() (
    cache="$(cache_path)" || exit 1
    ensure_root_dir "$state" || exit 1
    ensure_root_dir "$tmp_dir" || exit 1
    scratch="$(mktemp -d "${tmp_dir}/status.XXXXXX")" || exit 1
    chmod 700 "$scratch" || exit 1
    trap 'rm -f "$scratch/nearby-flag"; rmdir "$scratch" 2>/dev/null || true' EXIT
    cp "$bundle/nearby-flag" "$scratch/nearby-flag" &&
        chmod 0700 "$scratch/nearby-flag" &&
        "$scratch/nearby-flag" --status "$cache"
)

link_status() {
    if provider_bound; then
        echo 'Google Play 服务  已连接扩展'
    else
        echo 'Google Play 服务  未连接扩展'
    fi
    code="$(gms_version 2>/dev/null || true)"
    if [ "$config_loaded" = 1 ] && [ -n "$code" ] && [ "$code" != "$VERIFIED_GMS_CODE" ]; then
        echo "Google Play 服务版本  ${code}（非基准 ${VERIFIED_GMS_CODE}，兼容模式）"
    fi
    mode="$(cache_mode 2>/dev/null)" || mode=unknown
    case "$mode" in
        enabled) echo 'Nearby 本地开关  已开启' ;;
        disabled) echo 'Nearby 本地开关  已关闭' ;;
        absent) echo 'Nearby 本地开关  配置中未找到' ;;
        *) echo 'Nearby 本地开关  无法读取' ;;
    esac
}

stage_live() {
    local mode="${1:-manual}"
    verify_file_sha256 "$bundle/daemon.tar" "${MOSEY_DAEMON_TAR_SHA256:-}" ||
        fail '后台服务归档校验失败，请重新构建 APK。'
    ensure_root_dir "$runs_dir" || exit 1
    paths="$(cache_path)" || fail '找不到唯一的 Nearby 配置。请先确保用户 0 已打开过 Quick Share 并生成配置，再试。'
    uid="$(resolve_package_uid_u0 "$gms")" || fail '无法识别用户 0 的 Google Play 服务 UID。'
    [ "$(stat -c '%a:%u:%g' "$paths")" = "644:${uid}:${uid}" ] ||
        fail "Nearby 配置权限与预期不符（期望 644:${uid}:${uid}）。"

    run="$(mktemp -d "${runs_dir}/run.XXXXXX")"
    chown 0:0 "$run" && chmod 700 "$run"
    feature="$run/feature"
    mkdir -m 700 "$feature"
    cp "$bundle/config.env" "$bundle/common.sh" "$bundle/restore.sh" "$bundle/live-vintf.sh" \
        "$bundle/probe.sh" "$bundle/manifest_mosey.xml" "$bundle/query_declared" \
        "$bundle/cache-test.sh" "$bundle/probe-native.sh" "$bundle/nearby-flag" "$run/"
    chmod 700 "$run/query_declared" "$run/nearby-flag"
    cp "$bundle/config.env" "$bundle/common.sh" "$bundle/cache-test.sh" "$feature/"
    cp "$bundle/probe-native.sh" "$feature/probe.sh"
    if [ "$mode" = automatic ]; then
        ln "$bundle/daemon.tar" "$run/daemon.tar"
        touch "$run/automatic-load"
    else
        cp "$bundle/daemon.tar" "$run/daemon.tar"
    fi
    ln "$run/daemon.tar" "$feature/payload.tar"
    cp "$paths" "$feature/nearby-original.pb"
    cp "$bundle/nearby-flag" "$feature/nearby-flag"
    chmod 700 "$feature/nearby-flag"
    "$feature/nearby-flag" "$feature/nearby-original.pb" "$feature/nearby-test.pb"
    unlink "$feature/nearby-flag"
    printf '%s %s\n' "$(digest "$feature/nearby-original.pb")" "$(digest "$feature/nearby-test.pb")" >"$feature/hashes.txt"
    unlink "$feature/nearby-original.pb"
    printf '%s\n' "$paths" >"$feature/cache-path"
    require_same_gms
    session_boot="$(boot_id)" || fail '无法读取本次开机标识。'
    printf '%s %s\n' "$session_boot" "$checked_gms_code" >"$run/recovery-allowed"
    "$bb" nohup /system/bin/setsid /system/bin/sh -c "$LOG_THROUGH_PIPE" quickshare-log \
        "$run/live.log" /system/bin/sh "$run/restore.sh" "$run" supervise \
        </dev/null >/dev/null 2>&1 8>&- &
    echo '正在加载原厂声明和后台服务。Quick Share 可能会自动打开。'
    for step in $(seq 1 40); do
        if [ -f "$run/ready" ] && manifest_mounted "$run" && native_running; then
            echo '已加载 Quick Share ↔ AirDrop。'
            return
        fi
        if [ "$step" -gt 3 ] && ! starting "$run"; then break; fi
        sleep 1
    done
    if [ -f "$run/live.log" ]; then tail -20 "$run/live.log"; fi
    fail 'Quick Share 尚未连接到后台服务。可点「撤回」后再试。'
}

can_rebuild_session() {
    local since
    [ -f "$bundle/activated" ] && [ -f "$bundle/recovery-allowed" ] &&
        [ ! -e "$bundle/stop-requested" ] || return 1
    if [ ! -e "$bundle/automatic-load" ] || [ -f "$bundle/recovery-rearmed" ]; then
        return 0
    fi
    [ -f "$bundle/healthy-since" ] &&
        read -r since <"$bundle/healthy-since" && recovery_window_elapsed "$since"
}

supervise_session() {
    run_valid "$bundle" || exit 1
    /system/bin/sh "$bundle/live-vintf.sh" "$bundle" || :
    if ! can_rebuild_session; then
        if [ -f "$bundle/automatic-load" ] && [ ! -e "$bundle/stop-requested" ]; then
            log_note '自动重建后的会话未稳定运行足够久，已暂停再次自动重建。'
        fi
        return 0
    fi
    /system/bin/sh -c "$LOG_THROUGH_PIPE" quickshare-recovery "$bundle/recovery.log" \
        /system/bin/sh "$bundle/restore.sh" "$bundle" recover
}

recover_session() {
    local rebuilt_run
    run_valid "$bundle" || exit 1
    can_rebuild_session || return 0
    [ -f "$bundle/recovery-allowed" ] && [ ! -L "$bundle/recovery-allowed" ] &&
        read -r recovery_boot recovery_code <"$bundle/recovery-allowed" || return 0
    [ -f "$bundle/activated" ] && [ ! -e "$bundle/stop-requested" ] &&
        [ "$recovery_boot" = "$(boot_id)" ] || return 0
    case "$recovery_code" in ''|*[!0-9]*) return 1 ;; esac

    previous_framework=
    for step in $(seq 1 15); do
        [ ! -e "$bundle/stop-requested" ] || return 0
        framework="$(pidof system_server 2>/dev/null || true)"
        manager="$(pidof servicemanager 2>/dev/null || true)"
        if [ -n "$framework" ] && [ -n "$manager" ] && [ "$(getprop sys.boot_completed)" = 1 ]; then
            if [ "$previous_framework" = "$framework/$manager" ]; then break; fi
            previous_framework="$framework/$manager"
        else
            previous_framework=
        fi
        if [ "$step" = 15 ]; then fail '自动重建已停止：Android 框架未恢复稳定。'; fi
        sleep 2
    done

    exec 8>"$state/operation.lock"
    for step in 1 2 3 4 5; do
        [ ! -e "$bundle/stop-requested" ] || return 0
        if flock -n 8 8>&8; then break; fi
        if [ "$step" = 5 ]; then fail '自动重建已停止：恢复工具仍在处理其他操作。'; fi
        sleep 1
    done
    can_rebuild_session || return 0
    unlink "$bundle/recovery-allowed"
    if active; then return 0; fi
    checked_gms_code="$recovery_code"
    check_build
    require_same_gms
    privileged || fail '自动重建已停止：特权扩展未生效。'
    verify_apk required
    restore_stale
    if native_running; then fail '自动重建已停止：Mosey 服务仍被占用。'; fi
    echo '正在自动重建 Quick Share 会话。'
    stage_live automatic
    rebuilt_run="$run"
    if [ ! -f "$rebuilt_run/ready" ] || ! manifest_mounted "$rebuilt_run" || ! native_running ||
        ! provider_bound || [ "$(cache_mode 2>/dev/null)" != enabled ]; then
        stop
        fail '自动重建后未能确认扩展连接或 Nearby 开关，已撤回。'
    fi
    touch "$rebuilt_run/auto-rebuilt"
    echo '自动重建成功，后台、扩展连接和 Nearby 开关均正常。'
}

load() {
    reloaded_after_stop=0
    if active; then
        mode="$(cache_mode 2>/dev/null)" || mode=unknown
        case "$mode" in
            disabled|absent)
                check_build
                verify_apk required
                check_gms_code
                echo '检测到 Nearby 开关已关闭或移除，正在用当前配置重新加载。'
                stop
                reloaded_after_stop=1
                ;;
            *)
                echo '后台服务已在运行。'
                link_status
                return
                ;;
        esac
    fi
    if [ "$reloaded_after_stop" = 1 ]; then
        # Exit 42 is reserved for confirmation before changing the session.
        require_same_gms
    else
        check_build
        check_gms_code
    fi
    restore_stale
    require_same_gms
    if native_running; then fail '已有其他 Mosey 服务在运行。'; fi
    if privileged; then
        verify_apk required
        if [ -f "$state/prepared" ]; then unlink "$state/prepared"; fi
        stage_live
        return
    fi
    verify_apk optional
    ensure_root_dir "$leaves_dir" || exit 1
    if ! leaf="$(prepared_leaf)"; then
        if mounted_leaf >/dev/null; then
            fail '检测到特权扩展挂载仍在，但系统未启用该特权扩展（当前「撤回」不会卸载已软重启的扩展挂载）。请先整机重启清除残留挂载；若使用临时 Root 请重新取得 Root 后重试，或先手动安装与构建时 SHA-256 一致的原厂 MoseyApp.apk 再走「加载 → 软重启 → 加载」。'
        fi
        require_same_gms
        if ! result="$(/system/bin/sh "$bundle/prepare-privileged.sh" "$bundle/privileged-app.tar" 2>&1)"; then
            echo "$result"
            fail '无法挂载特权扩展。请确认没有旧测试模块或其他挂载占用了这两个目录。'
        fi
        leaf="$(printf '%s\n' "$result" | sed -n 's/^WORK=//p')"
        leaf_valid "$leaf" || fail '未取得合法的特权扩展挂载目录。'
        printf '%s %s %s\n' "$leaf" "$(boot_id)" "$(pidof system_server)" >"$state/prepared"
    fi
    echo '特权扩展已准备好。选择「软重启」，回到桌面后再打开本工具点「加载」。'
}

restart_framework() {
    check_build
    check_gms_code
    if privileged || active; then fail '特权扩展已生效，无需软重启。'; fi
    leaf="$(prepared_leaf)" || fail '请先点「加载」，准备特权扩展。'
    [ -f /system/priv-app/MoseyApp/MoseyApp.apk ] && [ ! -L /system/priv-app/MoseyApp/MoseyApp.apk ] ||
        fail '待加载的 APK 文件状态异常。'
    [ "$(digest "/system/priv-app/MoseyApp/MoseyApp.apk")" = "$MOSEY_APK_SHA256" ] ||
        fail '待加载的 APK 校验失败。'
    check_no_staged_sessions || exit 1
    ksud_ver="$("$ksud" --version 2>/dev/null || true)"
    if ! "$ksud" soft-reboot --help >/dev/null 2>&1; then
        fail "当前 KernelSU（${ksud_ver:-未知版本}）不支持 soft-reboot 命令。"
    fi
    if [ "$ksud_ver" != "$VERIFIED_KSUD_VERSION" ]; then
        echo "提示：当前 KernelSU 版本为 ${ksud_ver:-未知}（已验证基准为 ${VERIFIED_KSUD_VERSION}），将尝试调用 soft-reboot。"
    fi
    require_same_gms
    for f in "$leaf/cancel" "$leaf/watch-result"; do
        if [ -f "$f" ]; then unlink "$f"; fi
    done
    "$bb" nohup /system/bin/setsid /system/bin/sh "$leaf/watch.sh" "$leaf" >"$leaf/watch.log" 2>&1 </dev/null 8>&- &
    echo '正在交给 KernelSU 软重启。进入桌面后请打开本工具，点「加载」。'
    "$ksud" soft-reboot
}

stop() {
    if [ -d "$runs_dir" ] && [ ! -L "$runs_dir" ]; then
        for run in "$runs_dir"/run.*; do
            run_valid "$run" || continue
            if [ -f "$run/recovery-allowed" ] || manifest_mounted "$run" || starting "$run"; then
                touch "$run/stop-requested" "$run/stop"
            fi
        done
        busy=no
        for step in $(seq 1 30); do
            busy=no
            for run in "$runs_dir"/run.*; do
                run_valid "$run" || continue
                if starting "$run" || { manifest_mounted "$run" && native_running; }; then busy=yes; fi
            done
            [ "$busy" = no ] && break
            sleep 1
        done
        [ "$busy" = no ] || fail '服务仍在退出，或挂载尚未撤回。请查看日志。'
    fi
    restore_stale
    if leaf="$(prepared_leaf)"; then
        /system/bin/sh "$leaf/rollback.sh" "$leaf"
        unlink "$state/prepared"
        echo '已撤回尚未生效的特权扩展挂载。'
    fi
    echo '已停止临时后台服务和测试配置。已生效的特权扩展挂载会随整机重启消失。'
}

status() {
    echo "系统  $(getprop ro.build.display.id)"
    if privileged; then
        echo '特权扩展  已生效'
    elif prepared_leaf >/dev/null; then
        echo '特权扩展  已准备，等待软重启'
    elif mounted_leaf >/dev/null; then
        echo '特权扩展  挂载仍在但未生效（请整机重启清除挂载，必要时手动预装同版原厂 APK）'
    else
        echo '特权扩展  待准备'
    fi
    if active; then
        echo '后台服务  运行中'
        for run in "$runs_dir"/run.*; do
            run_valid "$run" || continue
            if [ -f "$run/auto-rebuilt" ] && manifest_mounted "$run"; then
                echo '本次会话  已自动重建'
                break
            fi
            if [ -f "$run/native-recovered" ] && manifest_mounted "$run"; then
                echo '本次会话  已自动重启后台'
                break
            fi
        done
    elif native_running; then
        echo '后台服务  已注册，工具会话未就绪'
    else
        echo '后台服务  未运行'
    fi
    link_status
    show_last_exit
}

latest_run_file() {
    name="$1"
    latest=
    newest=0
    [ -d "$runs_dir" ] && [ ! -L "$runs_dir" ] || return 1
    for run in "$runs_dir"/run.*; do
        run_valid "$run" || continue
        entry="$run/$name"
        [ -f "$entry" ] && [ ! -L "$entry" ] || continue
        changed="$(stat -c %Y "$entry" 2>/dev/null)" || continue
        if [ "$changed" -ge "$newest" ]; then
            newest="$changed"
            latest="$entry"
        fi
    done
    [ -n "$latest" ] && printf '%s\n' "$latest"
}

show_last_exit() {
    last="$(latest_run_file native-exit)" || return 0
    IFS='|' read -r when cause result <"$last" || return 0
    case "$cause" in
        user-stop) reason='手动撤回' ;;
        recovery-stop) reason='会话清理' ;;
        framework-change) reason='Android 系统状态变化' ;;
        monitor-signal) reason='监控进程收到终止信号' ;;
        startup-failed) reason='后台启动失败' ;;
        *) reason='后台自行退出或被终止，来源未明' ;;
    esac
    case "$result" in
        137) detail='，SIGKILL' ;;
        139) detail='，SIGSEGV' ;;
        143) detail='，SIGTERM' ;;
        *) detail= ;;
    esac
    printf '最近一次后台退出  %s\n%s（退出码 %s%s）\n' "$when" "$reason" "$result" "$detail"
}

logs() {
    show_last_exit
    if signal_log="$(latest_run_file native-signals)"; then
        echo '最近的内核终止信号记录'
        tail -12 "$signal_log"
    fi
    if recovery_log="$(latest_run_file recovery.log)"; then
        echo '最近一次自动重建记录'
        tail -12 "$recovery_log"
    fi
    if latest_log="$(latest_run_file live.log)"; then
        tail -30 "$latest_log"
    else
        echo '暂无后台服务日志。'
    fi
}

[ "$(id -u)" = 0 ] || fail '请确保已取得 KernelSU Root，并在 KernelSU 中授权本工具。'
[ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ] || fail '无法进入系统挂载环境。'

case "$action" in
    status) status; exit ;;
    logs) logs; exit ;;
    supervise) supervise_session; exit ;;
    recover) recover_session; exit ;;
    stop)
        ensure_root_dir "$state" || exit 1
        exec 8>"$state/operation.lock"
        flock -n 8 8>&8 || fail '有一个操作尚未结束。请稍后再试。'
        stop
        exit
        ;;
    load|restart)
        require_config
        [ "$(getprop ro.product.model)" = "$TARGET_DEVICE" ] || fail "这份工具默认仅供 ${TARGET_DEVICE} 使用。"
        ensure_root_dir "$state" || exit 1
        exec 8>"$state/operation.lock"
        flock -n 8 8>&8 || fail '有一个操作尚未结束。请稍后再试。'
        if [ "$action" = restart ]; then restart_framework; else load; fi
        ;;
    *) fail '操作无效。' ;;
esac
