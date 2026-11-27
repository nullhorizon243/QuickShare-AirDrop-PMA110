package org.george.quicksharerestore;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;

public final class MainActivity extends Activity {
    private static final int INK = 0xff16253a;
    private static final int MUTED = 0xff4e5d73;
    private static final int BLUE = 0xff194fbd;
    private static final int SURFACE = 0xfff2f6fc;
    private static final int EXIT_GMS_MISMATCH = 42;
    private static final String[] FILES = {
        "config.env", "common.sh", "restore.sh", "prepare-privileged.sh", "privileged-app.tar",
        "live-vintf.sh", "manifest_mosey.xml", "query_declared", "probe.sh",
        "cache-test.sh", "probe-native.sh", "daemon.tar",
        "nearby-flag"
    };

    static final class GmsMismatch {
        final String actualCode;
        final String verifiedName;
        final String verifiedCode;

        GmsMismatch(String actualCode, String verifiedName, String verifiedCode) {
            this.actualCode = actualCode;
            this.verifiedName = verifiedName;
            this.verifiedCode = verifiedCode;
        }
    }

    private static final class ExecResult {
        final int exitCode;
        final String text;
        final GmsMismatch mismatch;

        ExecResult(int exitCode, String text, GmsMismatch mismatch) {
            this.exitCode = exitCode;
            this.text = text;
            this.mismatch = mismatch;
        }
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Button> buttons = new ArrayList<>();
    private TextView output;

    @Override
    protected void onCreate(Bundle savedState) {
        super.onCreate(savedState);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(SURFACE);

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets safe = insets.getInsets(
                WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            view.setPadding(dp(24) + safe.left, dp(34) + safe.top,
                dp(24) + safe.right, dp(24) + safe.bottom);
            return insets;
        });
        scroll.addView(column);
        setContentView(scroll);
        column.requestApplyInsets();

        TextView title = label("Quick Share 恢复", 31, INK);
        title.setTypeface(null, Typeface.BOLD);
        add(column, title, 0);
        add(column, label("Find X9 Ultra 国行 · PMA110", 15, MUTED), 9);
        add(column, label("确保 KernelSU Root 已就绪后点「加载」。如果提示等待软重启，完成软重启后再点一次「加载」。", 16, MUTED), 22);

        add(column, button("加载", true, () -> run("load", null)), 22);
        add(column, button("查看状态", false, () -> run("status", null)), 9);
        add(column, button("软重启", false, this::confirmRestart), 9);
        add(column, button("撤回", false, this::confirmStop), 9);
        add(column, button("查看日志", false, () -> run("logs", null)), 9);

        output = label("准备就绪。首次使用请在 KernelSU 的「超级用户」中授权 Quick Share 恢复。", 15, INK);
        output.setAccessibilityLiveRegion(TextView.ACCESSIBILITY_LIVE_REGION_POLITE);
        output.setTextIsSelectable(true);
        output.setPadding(dp(16), dp(14), dp(16), dp(14));
        output.setBackground(panel(Color.WHITE));
        add(column, output, 20);
    }

    private void confirmRestart() {
        new AlertDialog.Builder(this)
            .setTitle("通过 KernelSU 软重启？")
            .setMessage("仅在工具已准备好特权扩展时执行。回到桌面后，打开本工具并点「加载」。")
            .setNegativeButton("取消", null)
            .setPositiveButton("软重启", (dialog, which) -> run("restart", null))
            .show();
    }

    private void confirmStop() {
        new AlertDialog.Builder(this)
            .setTitle("停止 Quick Share 修复？")
            .setMessage("会停止临时后台服务，并撤回本次的测试开关与临时位置授权。")
            .setNegativeButton("取消", null)
            .setPositiveButton("撤回", (dialog, which) -> run("stop", null))
            .show();
    }

    private void confirmGmsMismatch(String action, GmsMismatch mismatch) {
        String actionLabel = "restart".equals(action) ? "继续软重启" : "继续加载";
        String detail = "检测到当前 Google Play 服务版本为 " + mismatch.actualCode
            + "，与本工具已验证的基准版本（" + mismatch.verifiedName + " / " + mismatch.verifiedCode + "）不同。\n\n"
            + "确认后仅针对版本 " + mismatch.actualCode + " 放行；执行时仍会通过 Nearby 配置无损校验与失败自动回滚保护，但无法保证在新版本上完全生效。是否继续？";
        output.setText("已暂停：Google Play 服务版本（" + mismatch.actualCode + "）与已验证基准不同，等待确认。");
        new AlertDialog.Builder(this)
            .setTitle("Google Play 服务版本不同")
            .setMessage(detail)
            .setCancelable(false)
            .setNegativeButton("取消", (dialog, which) ->
                output.setText("已取消：当前 Google Play 服务版本（" + mismatch.actualCode
                    + "）与已验证基准（" + mismatch.verifiedName + " / " + mismatch.verifiedCode
                    + "）不同。挂载、权限与 GMS 配置未修改。"))
            .setPositiveButton(actionLabel, (dialog, which) -> run(action, mismatch.actualCode))
            .show();
    }

    private void run(String action, String allowGmsCode) {
        setButtonsEnabled(false);
        output.setText("正在检查 Root 并执行…");
        new Thread(() -> {
            ExecResult result;
            try {
                result = execute(action, allowGmsCode);
            } catch (IOException e) {
                result = new ExecResult(1,
                    "无法启动。请确保已取得 KernelSU Root，并在 KernelSU 中授权本工具。\n" + e.getMessage(), null);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                result = new ExecResult(1, "操作已中断，请查看状态。", null);
            }
            ExecResult finalResult = result;
            main.post(() -> {
                if (isDestroyed()) return;
                setButtonsEnabled(true);
                if (finalResult.exitCode == EXIT_GMS_MISMATCH
                        && finalResult.mismatch != null
                        && !finalResult.mismatch.actualCode.equals(allowGmsCode)) {
                    confirmGmsMismatch(action, finalResult.mismatch);
                    return;
                }
                output.setText(finalResult.text);
            });
        }, "quick-share-restore").start();
    }

    static GmsMismatch parseGmsMismatchLine(String line) {
        if (line == null || !line.startsWith("GMS_MISMATCH|")) return null;
        String[] parts = line.split("\\|", -1);
        if (parts.length != 4) return null;
        if (!"GMS_MISMATCH".equals(parts[0])) return null;
        if (!isDigits(parts[1]) || parts[2].trim().isEmpty() || !isDigits(parts[3])) return null;
        return new GmsMismatch(parts[1], parts[2], parts[3]);
    }

    private static boolean isDigits(String value) {
        if (value == null || value.isEmpty()) return false;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') return false;
        }
        return true;
    }

    private ExecResult execute(String action, String allowGmsCode) throws IOException, InterruptedException {
        File bundle = prepareBundle();
        String extraArg = "";
        if (isDigits(allowGmsCode)) {
            extraArg = " " + quote("--allow-gms-code=" + allowGmsCode);
        }
        String launch = "export PATH=/system/bin:/system/xbin; "
            + "if [ \"$(id -u)\" != 0 ]; then exit 13; fi; "
            + "exec /system/bin/nsenter -t 1 -m -- /system/bin/sh "
            + quote(new File(bundle, "restore.sh").getAbsolutePath()) + " "
            + quote(bundle.getAbsolutePath()) + " " + quote(action) + extraArg;
        Process process = new ProcessBuilder("/system/bin/su", "-c", launch)
            .redirectErrorStream(true).start();
        process.getOutputStream().close();

        StringBuilder response = new StringBuilder();
        GmsMismatch mismatch = null;
        try (BufferedReader lines = new BufferedReader(new InputStreamReader(
                process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = lines.readLine()) != null) {
                GmsMismatch parsed = parseGmsMismatchLine(line);
                if (parsed != null) {
                    mismatch = parsed;
                } else if (response.length() < 14000) {
                    response.append(line).append('\n');
                }
            }
        } finally {
            process.getInputStream().close();
        }
        int exit = process.waitFor();
        String trimmed = response.toString().trim();
        if (exit == EXIT_GMS_MISMATCH && mismatch != null) {
            return new ExecResult(exit, trimmed, mismatch);
        }
        if (exit == 0) return new ExecResult(0, trimmed.length() > 0 ? trimmed : "操作已完成。", null);
        if (exit == 13 || exit == 126 || exit == 127 || trimmed.length() == 0) {
            return new ExecResult(exit,
                "请确保已取得 KernelSU Root，并在 KernelSU 的「超级用户」中授权本工具，然后重试。\n" + trimmed, null);
        }
        return new ExecResult(exit, trimmed, null);
    }

    private File prepareBundle() throws IOException {
        synchronized (MainActivity.class) {
            return prepareBundleLocked();
        }
    }

    private File prepareBundleLocked() throws IOException {
        String fingerprint = computeAssetsFingerprint(null);
        File root = getFilesDir();
        File bundle = new File(root, "bundle-" + fingerprint);
        File marker = new File(bundle, ".complete");
        if (bundle.isDirectory() && !Files.isSymbolicLink(bundle.toPath())
                && marker.isFile() && !Files.isSymbolicLink(marker.toPath())
                && marker.length() == fingerprint.length()) {
            try {
                String cached = new String(Files.readAllBytes(marker.toPath()), StandardCharsets.UTF_8);
                if (fingerprint.equals(cached) && fingerprint.equals(computeAssetsFingerprint(bundle))) {
                    return bundle;
                }
            } catch (IOException ignored) {
                // A missing or unreadable resource is rebuilt from the installed APK.
            }
        }

        File staging = new File(root, "staging-" + fingerprint + "-" + System.nanoTime());
        if (!staging.mkdir()) {
            throw new IOException("无法创建临时资源目录。");
        }
        boolean committed = false;
        try {
            byte[] buffer = new byte[32768];
            for (String name : FILES) {
                File destination = new File(staging, name);
                try (InputStream source = getAssets().open(name);
                     FileOutputStream target = new FileOutputStream(destination)) {
                    int size;
                    while ((size = source.read(buffer)) != -1) {
                        target.write(buffer, 0, size);
                    }
                    target.getFD().sync();
                }
            }
            if (!fingerprint.equals(computeAssetsFingerprint(staging))) {
                throw new IOException("解包后的资源校验失败。");
            }
            try (FileOutputStream mark = new FileOutputStream(new File(staging, ".complete"))) {
                mark.write(fingerprint.getBytes(StandardCharsets.UTF_8));
                mark.getFD().sync();
            }
            if (bundle.exists() || Files.isSymbolicLink(bundle.toPath())) {
                deleteTree(bundle);
            }
            if (!staging.renameTo(bundle)) {
                throw new IOException("无法原子切换安装包资源目录。");
            }
            committed = true;
        } finally {
            if (!committed) {
                deleteTree(staging);
            }
        }
        cleanupOldBundles(root, bundle.getName());
        return bundle;
    }

    private String computeAssetsFingerprint(File directory) throws IOException {
        MessageDigest digest;
        MessageDigest resourceDigest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
            resourceDigest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IOException("SHA-256 不可用。", e);
        }
        byte[] buffer = new byte[32768];
        for (String name : FILES) {
            digest.update(name.getBytes(StandardCharsets.UTF_8));
            digest.update((byte) 0);
            File resource = directory == null ? null : new File(directory, name);
            if (resource != null && (!resource.isFile() || Files.isSymbolicLink(resource.toPath()))) {
                throw new IOException("资源文件缺失或异常：" + name);
            }
            try (InputStream source = resource == null ? getAssets().open(name) : new FileInputStream(resource)) {
                int size;
                while ((size = source.read(buffer)) != -1) {
                    resourceDigest.update(buffer, 0, size);
                }
            }
            digest.update(resourceDigest.digest());
        }
        byte[] hash = digest.digest();
        StringBuilder hex = new StringBuilder(64);
        for (byte value : hash) {
            int b = value & 0xff;
            if (b < 16) hex.append('0');
            hex.append(Integer.toHexString(b));
        }
        return hex.toString();
    }

    private static void cleanupOldBundles(File root, String keepName) {
        File[] children = root.listFiles();
        if (children == null) return;
        for (File child : children) {
            String name = child.getName();
            if ((name.startsWith("bundle-") || name.startsWith("staging-")) && !name.equals(keepName)) {
                deleteTree(child);
            }
        }
    }

    private static void deleteTree(File target) {
        if (target == null) return;
        if (target.isDirectory() && !Files.isSymbolicLink(target.toPath())) {
            File[] children = target.listFiles();
            if (children != null) {
                for (File child : children) deleteTree(child);
            }
        }
        target.delete();
    }

    private TextView label(String text, int size, int color) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setLineSpacing(dp(3), 1);
        return view;
    }

    private Button button(String text, boolean primary, Runnable onClick) {
        Button button = new Button(this);
        GradientDrawable shape = panel(primary ? BLUE : Color.WHITE);
        GradientDrawable mask = panel(Color.WHITE);
        button.setBackground(new RippleDrawable(
            ColorStateList.valueOf(primary ? 0x44ffffff : 0x22405499), shape, mask));
        button.setText(text);
        button.setTextSize(16);
        button.setTextColor(primary ? Color.WHITE : INK);
        button.setTypeface(null, Typeface.BOLD);
        button.setAllCaps(false);
        button.setMinimumHeight(dp(52));
        button.setGravity(Gravity.CENTER);
        button.setOnClickListener(view -> onClick.run());
        buttons.add(button);
        return button;
    }

    private GradientDrawable panel(int fill) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(fill);
        shape.setCornerRadius(dp(12));
        return shape;
    }

    private void setButtonsEnabled(boolean enabled) {
        for (Button button : buttons) {
            button.setEnabled(enabled);
            button.setAlpha(enabled ? 1f : .55f);
        }
    }

    private void add(LinearLayout parent, android.view.View view, int topMargin) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(topMargin);
        parent.addView(view, params);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }
}
