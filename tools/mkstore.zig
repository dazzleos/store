//! Makes the store's catalogue: one apps.json listing the apps of
//! dazzleos' app repositories, each as one of its builds publishes it (a
//! "build-<commit>" release, whose files stay as they are), signed with
//! the store's key, the one Dazzle's own builds trust.
//!
//! Each app keeps its files where its build published them: its entry
//! says so with "base" (the release's download URL), and Settings
//! downloads its archive, icon and screenshot from there. Its archive's
//! size and SHA-256 are checked against its own catalogue before it is
//! signed.
//!
//! Usage:
//!     mkstore list <store.zon>
//!         Each app's repository and the build it names ("-" for the
//!         newest), a line each.
//!     mkstore make [--key=<64-hex-seed or file>] [--previous=<apps.json>] <apps.json> <version> (<repository> <tag> <dir>)...
//!         The catalogue, from each build's files, downloaded into <dir>
//!         (its apps.json and archives). The key is DAZZLE_SIGNING_KEY's
//!         if no --key is given. A repository whose tag is "-" (its
//!         build could not be got) keeps its apps as the previous
//!         catalogue (the one published) lists them, if from a build.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

/// store.zon.
pub const Store = struct {
    apps: []const Entry,

    pub const Entry = struct {
        /// On GitHub, "<owner>/<name>".
        repository: []const u8,
        /// A release's tag, to hold the app at that build; the newest
        /// build if empty.
        build: []const u8 = "",
    };
};

/// An app, as its repository's catalogue (Dazzle's tools/mkcatalogue.zig)
/// lists it.
pub const App = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    version: []const u8 = "",
    time: u64 = 0,
    icon: []const u8,
    about: []const u8 = "",
    screenshot: []const u8 = "",
    file: []const u8,
    size: u64,
    sha256: []const u8,
    signature: []const u8 = "",
    language: []const u8 = "",
};

pub const Catalogue = struct {
    version: []const u8 = "",
    time: u64 = 0,
    apps: []const App,
};

/// An app as the store lists it: with where its files are.
pub const StoreApp = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    version: []const u8,
    time: u64,
    icon: []const u8,
    about: []const u8,
    screenshot: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
    signature: []const u8,
    language: []const u8,
    base: []const u8,
};

pub const StoreCatalogue = struct {
    version: []const u8,
    time: u64,
    apps: []const StoreApp,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "list")) {
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], arena, .limited(1 << 20));
        const store = try parseStore(arena, try arena.dupeSentinel(u8, text, 0), args[2]);
        var out: std.Io.Writer.Allocating = .init(arena);
        for (store.apps) |e| try out.writer.print("{s} {s}\n", .{ e.repository, if (e.build.len > 0) e.build else "-" });
        try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "make")) {
        var i: usize = 2;
        var key_arg: ?[]const u8 = null;
        var previous: []const StoreApp = &.{};
        while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
            if (std.mem.startsWith(u8, args[i], "--key=")) {
                key_arg = args[i]["--key=".len..];
            } else if (std.mem.startsWith(u8, args[i], "--previous=")) {
                const json = try std.Io.Dir.cwd().readFileAlloc(init.io, args[i]["--previous=".len..], arena, .limited(4 << 20));
                previous = (try std.json.parseFromSliceLeaky(StoreCatalogue, arena, json, .{ .ignore_unknown_fields = true })).apps;
            } else usage();
        }
        if (args.len < i + 2 or (args.len - (i + 2)) % 3 != 0) usage();
        const key = key_arg orelse std.process.Environ.getPosix(init.minimal.environ, "DAZZLE_SIGNING_KEY") orelse
            "";
        if (key.len == 0) fail("no signing key: give --key or DAZZLE_SIGNING_KEY", .{});
        const kp = Ed25519.KeyPair.generateDeterministic(try readSeed(init.io, arena, key)) catch unreachable;
        const out_path = args[i];
        const version = args[i + 1];
        var apps: std.ArrayList(StoreApp) = .empty;
        var j = i + 2;
        while (j < args.len) : (j += 3) {
            const repository = args[j];
            const tag = args[j + 1];
            const dir = args[j + 2];
            if (std.mem.eql(u8, tag, "-")) {
                for (previous) |app| if (fromBuild(app, repository)) try apps.append(arena, app);
                continue;
            }
            const base = try std.fmt.allocPrint(arena, "https://github.com/{s}/releases/download/{s}", .{ repository, tag });
            const json = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(arena, &.{ dir, "apps.json" }), arena, .limited(1 << 20));
            const catalogue = try std.json.parseFromSliceLeaky(Catalogue, arena, json, .{ .ignore_unknown_fields = true });
            for (catalogue.apps) |app| {
                if (!plainName(app.file)) fail("{s}: {s}'s file \"{s}\" is not a plain name", .{ repository, app.name, app.file });
                const archive = try std.Io.Dir.cwd().readFileAlloc(init.io, try std.fs.path.join(arena, &.{ dir, app.file }), arena, .limited(256 << 20));
                const entry = list(arena, kp, app, base, archive) catch |err|
                    fail("{s}: {s}: {s}", .{ repository, app.name, @errorName(err) });
                try apps.append(arena, entry);
            }
        }
        const json = combine(arena, version, apps.items) catch |err| fail("{s}", .{@errorName(err)});
        const file = try std.Io.Dir.cwd().createFile(init.io, out_path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, json);
        return;
    }
    usage();
}

fn usage() noreturn {
    std.debug.print(
        \\usage: mkstore list <store.zon>
        \\       mkstore make [--key=<64-hex-seed or file>] [--previous=<apps.json>] <apps.json> <version> (<repository> <tag> <dir>)...
        \\
    , .{});
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("mkstore: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn parseStore(arena: std.mem.Allocator, source: [:0]const u8, path: []const u8) !Store {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Store, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(path);
        return err;
    };
}

/// The seed: 64 hex digits, or a file of them.
fn readSeed(io: std.Io, arena: std.mem.Allocator, key: []const u8) ![32]u8 {
    const trimmed = std.mem.trim(u8, key, " \t\r\n");
    const hex = if (trimmed.len == 64 and isHex(trimmed))
        trimmed
    else
        std.mem.trim(u8, try std.Io.Dir.cwd().readFileAlloc(io, trimmed, arena, .limited(4096)), " \t\r\n");
    return parseSeed(hex);
}

pub fn parseSeed(hex: []const u8) ![32]u8 {
    if (hex.len != 64 or !isHex(hex)) return error.InvalidSigningKey;
    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, hex);
    return seed;
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A file's name with no directory in it, as it is downloaded by.
pub fn plainName(name: []const u8) bool {
    return name.len > 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\?#%") == null;
}

/// `app`, as the store lists it: its archive checked against what its own
/// catalogue says, and signed with `kp`; its files at `base`.
pub fn list(arena: std.mem.Allocator, kp: Ed25519.KeyPair, app: App, base: []const u8, archive: []const u8) !StoreApp {
    if (archive.len != app.size) return error.SizeMismatch;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    const sha256 = try std.fmt.allocPrint(arena, "{x}", .{&digest});
    if (!std.ascii.eqlIgnoreCase(sha256, app.sha256)) return error.Sha256Mismatch;
    for ([_][]const u8{ app.icon, app.screenshot }) |name| {
        if (name.len > 0 and !plainName(name)) return error.NotAPlainName;
    }
    const sig = (try kp.sign(archive, null)).toBytes();
    return .{
        .name = app.name,
        .title = app.title,
        .description = app.description,
        .version = app.version,
        .time = app.time,
        .icon = app.icon,
        .about = app.about,
        .screenshot = app.screenshot,
        .file = app.file,
        .size = app.size,
        .sha256 = sha256,
        .signature = try std.fmt.allocPrint(arena, "{x}", .{&sig}),
        .language = app.language,
        .base = base,
    };
}

/// Whether the store lists `app` from one of `repository`'s builds (not
/// its "latest" release, whose files change).
pub fn fromBuild(app: StoreApp, repository: []const u8) bool {
    var buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "https://github.com/{s}/releases/download/build-", .{repository}) catch return false;
    return std.mem.startsWith(u8, app.base, prefix) and std.mem.indexOfScalar(u8, app.base[prefix.len..], '/') == null;
}

/// The catalogue of `apps`, sorted by name; its time the newest app's.
pub fn combine(arena: std.mem.Allocator, version: []const u8, apps: []StoreApp) ![]u8 {
    std.mem.sort(StoreApp, apps, {}, struct {
        fn lessThan(_: void, a: StoreApp, b: StoreApp) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    var time: u64 = 0;
    for (apps, 0..) |a, k| {
        if (k > 0 and std.mem.eql(u8, apps[k - 1].name, a.name)) return error.DuplicateApp;
        time = @max(time, a.time);
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(StoreCatalogue{ .version = version, .time = time, .apps = apps }, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

const test_seed: [32]u8 = "dazzle-signing-key-seed-00000001".*;

fn testApp(name: []const u8, archive: []const u8, buf: *[64]u8) App {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    _ = std.fmt.bufPrint(buf, "{x}", .{&digest}) catch unreachable;
    return .{ .name = name, .title = "T", .description = "D", .version = "abc1234", .time = 5, .icon = "x.png", .file = "x.tar.xz", .size = archive.len, .sha256 = buf, .signature = "00" };
}

test "the store.zon lists repositories, each with the build it is held at, if any" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const store = try parseStore(arena.allocator(),
        \\.{ .apps = .{ .{ .repository = "dazzleos/files" }, .{ .repository = "dazzleos/motu", .build = "build-abc1234" } } }
    , "store.zon");
    try std.testing.expectEqual(@as(usize, 2), store.apps.len);
    try std.testing.expectEqualStrings("", store.apps[0].build);
    try std.testing.expectEqualStrings("build-abc1234", store.apps[1].build);
}

test "an app is signed with the store's key, and keeps where its files are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed);
    var buf: [64]u8 = undefined;
    const entry = try list(a, kp, testApp("dazzle-files", "archive", &buf), "https://github.com/dazzleos/files/releases/download/build-abc1234", "archive");
    try std.testing.expectEqualStrings("https://github.com/dazzleos/files/releases/download/build-abc1234", entry.base);
    var sig: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sig, entry.signature);
    try Ed25519.Signature.fromBytes(sig).verify("archive", kp.public_key);
}

test "an archive that is not what its catalogue says is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed);
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.SizeMismatch, list(a, kp, testApp("x", "archive", &buf), "b", "archives"));
    try std.testing.expectError(error.Sha256Mismatch, list(a, kp, testApp("x", "archive", &buf), "b", "archivf"));
    var bad = testApp("x", "archive", &buf);
    bad.icon = "../x.png";
    try std.testing.expectError(error.NotAPlainName, list(a, kp, bad, "b", "archive"));
}

test "the catalogue: apps by name, as Dazzle reads it, and no app twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed);
    var buf: [64]u8 = undefined;
    var apps = [_]StoreApp{
        try list(a, kp, testApp("dazzle-motu", "m", &buf), "b1", "m"),
        try list(a, kp, testApp("dazzle-files", "f", &buf), "b2", "f"),
    };
    apps[0].time = 9;
    const json = try combine(a, "1234567", &apps);
    const back = try std.json.parseFromSliceLeaky(StoreCatalogue, a, json, .{});
    try std.testing.expectEqualStrings("dazzle-files", back.apps[0].name);
    try std.testing.expectEqual(@as(u64, 9), back.time);
    var twice = [_]StoreApp{ apps[0], apps[0] };
    try std.testing.expectError(error.DuplicateApp, combine(a, "1234567", &twice));
}

test "an app is kept from the previous catalogue only if listed from its repository's build" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kp = try Ed25519.KeyPair.generateDeterministic(test_seed);
    var buf: [64]u8 = undefined;
    const app = try list(a, kp, testApp("dazzle-files", "f", &buf), "https://github.com/dazzleos/files/releases/download/build-abc1234", "f");
    try std.testing.expect(fromBuild(app, "dazzleos/files"));
    try std.testing.expect(!fromBuild(app, "dazzleos/file"));
    try std.testing.expect(!fromBuild(app, "dazzleos/camera"));
    var latest = app;
    latest.base = "https://github.com/dazzleos/files/releases/download/latest";
    try std.testing.expect(!fromBuild(latest, "dazzleos/files"));
}

test "a plain file name" {
    try std.testing.expect(plainName("dazzle-files.tar.xz"));
    try std.testing.expect(!plainName("../x"));
    try std.testing.expect(!plainName(".."));
    try std.testing.expect(!plainName(""));
    try std.testing.expect(!plainName("a?b"));
}
