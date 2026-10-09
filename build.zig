const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    // On macOS, a target without a version builds for macOS 13+ (not just
    // the Mac building it); pass this target to every executable you add.
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const android = target.result.abi == .android;
    const version = std.mem.trimStart(u8, b.option([]const u8, "app-version", "Package version") orelse b.graph.environ_map.get("HOLLERSHARE_VERSION") orelse "1.0.2", "v");
    _ = std.SemanticVersion.parse(version) catch @panic("Package version must be semantic version, e.g. 0.1.0");
    // Oriel's built-in modules and plugins. Switch on what the app uses:
    // anything left off is neither compiled nor linked.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .tray = true,
        .menu = false,
        .store = true, // dataDir: where settings.json lives
        .dialog = true,
        .native_ui = b.option(bool, "native_ui", "Use the native renderer") orelse true,
        .notification = true,
        .updater = true,
        .sql = false,
        .fs_watch = false,
        .media_server = false,
        .global_shortcut = false,
        .input = false,
        .clipboard = true,
    });

    // Frontend in frontend/ (embeds frontend/ as-is).
    // zig build          production build
    // zig build run      run it
    // zig build check    type-check src/ without building
    // zig build package  installers: deb/rpm/AppImage (Linux), setup.exe (Windows), .app/.dmg (macOS)
    const config = b.addOptions();
    config.addOption([]const u8, "version", version);
    config.addOption(bool, "play_store", b.option(bool, "play-store", "Use Google Play for Android updates") orelse false);
    const application = oriel.addApp(b, dep, .{
        .name = "hollershare",
        .imports = &.{
            .{ .name = "hollershare_config", .module = config.createModule() },
            .{ .name = "tray_icon", .module = b.createModule(.{ .root_source_file = b.path("assets/brand/tray-icon.zig") }) },
        },
        .root_source_file = b.path("src/main.zig"),
        .icon = b.path("assets/brand/hollershare-icon.png"), // High-resolution PNG (1024x1024 recommended)
        .frontend = .{
            // A static page: embedded as-is, no npm and no dev server.
            .dir = "frontend",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .permissions = .{
            .notifications = "Notify you when files arrive",
            // Quick Share: Bluetooth LE finds and wakes nearby phones (the
            // "Nearby devices" prompt; location up to Android 11).
            .bluetooth = "Find nearby phones and computers to share files with",
            // mDNS discovery on the LAN (Android: the Wi-Fi multicast lock).
            .local_network = "Find and reach devices on your network to share files with",
        },
        .package = .{
            .id = "dev.hollershare.App",
            .name = "HollerShare",
            // .publisher = "Your Name <you@example.com>", // default: from the app id
            .summary = "Share files with computers and Android Quick Share",
            .version = version,
        },
        // The isolation pattern: every call from the frontend to Zig goes
        // through isolation/hook.js first, in a frame the page can't reach.
        // .isolation = .{ .hook = b.path("isolation/hook.js") },
    });
    // Gradle extracts the matching symbols before stripping the packaged JNI
    // libraries. Preserve both Oriel and its helper executable until then.
    if (android) {
        for (b.getInstallStep().dependencies.items) |step| {
            if (step.cast(std.Build.Step.InstallArtifact)) |install| {
                install.artifact.root_module.strip = false;
            }
        }
    }
    // Cargo resolves the host Rust toolchain. Cross compilation requires a
    // matching Rust target and target libraries; this build supports the host.
    const rust_target = b.option([]const u8, "rust-target", "Rust target triple (required for desktop cross compilation)");
    const cargo = if (android) b.addSystemCommand(&.{ "cargo", "ndk", "--platform", "29", "--target", if (target.result.cpu.arch == .aarch64) "arm64-v8a" else "x86_64", "build" }) else b.addSystemCommand(&.{ "cargo", "build" });
    cargo.addArgs(&.{ "--locked", "--release", "--package", "hollershare-quickshare", "--target-dir", b.pathFromRoot("target") });
    if (android) cargo.addArg("--no-default-features");
    if (!android) if (rust_target) |triple| cargo.addArgs(&.{ "--target", triple });
    const triple = if (android) (if (target.result.cpu.arch == .aarch64) "aarch64-linux-android" else "x86_64-linux-android") else rust_target;
    const library_name = if (target.result.os.tag == .windows and target.result.abi == .msvc) "hollershare_quickshare.lib" else "libhollershare_quickshare.a";
    const library_path = if (triple) |t| b.fmt("target/{s}/release/{s}", .{ t, library_name }) else b.fmt("target/release/{s}", .{library_name});
    application.exe.root_module.addObjectFile(b.path(library_path));
    application.exe.step.dependOn(&cargo.step);
    if (target.result.os.tag == .linux and !android) {
        application.exe.root_module.addCSourceFile(.{ .file = b.path("src/desktop_linux.c"), .flags = &.{"-std=c11"} });
        application.exe.root_module.linkSystemLibrary("gtk4", .{});
        application.exe.root_module.linkSystemLibrary("dbus-1", .{});
        application.exe.root_module.linkSystemLibrary("pthread", .{});
        application.exe.root_module.linkSystemLibrary("dl", .{});
        application.exe.root_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "ws2_32", "userenv", "bcrypt", "ntdll", "iphlpapi", "psapi" }) |library| application.exe.root_module.linkSystemLibrary(library, .{});
    }
    if (target.result.os.tag == .macos) application.exe.root_module.linkFramework("CoreBluetooth", .{});
    if (android) {
        // HollerShare's Kotlin (the BLE beacon, share sheet handler) and AndroidManifest,
        // copied into the Gradle project that `zig build android-project` writes:
        const sources = b.addUpdateSourceFiles();
        sources.addCopyFileToSource(b.path("src/android/QuickShareBeacon.kt"), "android/app/src/main/java/dev/hollershare/QuickShareBeacon.kt");
        sources.addCopyFileToSource(b.path("src/android/ShareActivity.kt"), "android/app/src/main/java/dev/hollershare/ShareActivity.kt");
        sources.addCopyFileToSource(b.path("src/android/AndroidManifest.xml"), "android/app/src/main/AndroidManifest.xml");
        // Adaptive icons fill Android's launcher mask rather than being shrunk
        // into its legacy white tile. Android 13+ also gets a themed icon.
        const icons = b.addUpdateSourceFiles();
        for ([_][]const u8{
            "drawable/hollershare_foreground.xml",
            "drawable/hollershare_monochrome.xml",
            "values/hollershare_icon_colors.xml",
            "mipmap-anydpi-v26/ic_launcher.xml",
            "mipmap-anydpi-v33/ic_launcher.xml",
        }) |resource| {
            icons.addCopyFileToSource(b.path(b.fmt("src/android/res/{s}", .{resource})), b.fmt("android/app/src/main/res/{s}", .{resource}));
        }
        sources.step.dependOn(&icons.step);
        if (b.top_level_steps.get("android-project")) |project| project.step.dependOn(&icons.step);
        b.getInstallStep().dependOn(&sources.step);
        if (b.top_level_steps.get("android-dev")) |dev| dev.step.dependOn(&sources.step);
    }
    const verifier = b.addExecutable(.{
        .name = "verify-updates",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/verify-updates.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "manifest", .module = b.createModule(.{ .root_source_file = dep.path("src/modules/update_manifest.zig") }) }},
        }),
    });
    const verify = b.addRunArtifact(verifier);
    if (b.args) |args| verify.addArgs(args);
    b.step("verify-updates", "Verify signed release manifests and update payloads").dependOn(&verify.step);
    const tests = b.addSystemCommand(&.{ "cargo", "test", "--locked", "--package", "hollershare-quickshare" });
    const test_step = b.step("test", "Test the Quick Share bridge and the settings");
    test_step.dependOn(&tests.step);
    const settings_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/settings.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(settings_tests).step);
}
