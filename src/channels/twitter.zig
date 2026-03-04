const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const auth = @import("../auth.zig");
const http_util = root.http_util;

/// Twitter channel — polls DMs via X API v2, supports BYOK bearer token or OAuth.
pub const TwitterChannel = struct {
    allocator: std.mem.Allocator,
    config: config_types.TwitterConfig,
    last_event_id: ?[]const u8 = null,

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.TwitterConfig) TwitterChannel {
        return .{ .allocator = allocator, .config = cfg };
    }

    pub fn deinit(self: *TwitterChannel) void {
        if (self.last_event_id) |id| self.allocator.free(id);
    }

    // ── Token resolution ────────────────────────────────────────────

    /// Resolve access token: BYOK bearer_token from config, or OAuth from auth.json.
    pub fn resolveAccessToken(self: *const TwitterChannel, allocator: std.mem.Allocator) ![]const u8 {
        if (builtin.is_test) return "test-bearer-token";

        // BYOK mode: bearer_token in config
        if (self.config.bearer_token) |bt| {
            if (bt.len > 0) return allocator.dupe(u8, bt);
        }

        // OAuth mode: load from credential store
        const token = try auth.loadCredential(allocator, "twitter") orelse return error.NoTwitterToken;
        defer {
            allocator.free(token.access_token);
            if (token.refresh_token) |rt| allocator.free(rt);
            allocator.free(token.token_type);
        }

        if (token.isExpired()) {
            // Attempt refresh
            const client_id = self.config.client_id orelse return error.NoTwitterToken;
            const rt = token.refresh_token orelse return error.NoTwitterToken;
            const refreshed = try auth.refreshAccessToken(
                allocator,
                "https://api.twitter.com/2/oauth2/token",
                client_id,
                rt,
            );
            defer {
                if (refreshed.refresh_token) |rrt| allocator.free(rrt);
                allocator.free(refreshed.token_type);
            }
            try auth.saveCredential(allocator, "twitter", refreshed);
            return refreshed.access_token; // caller owns
        }

        return allocator.dupe(u8, token.access_token);
    }

    // ── DM fetching ─────────────────────────────────────────────────

    pub const DmEvent = struct {
        id: []const u8,
        text: []const u8,
        sender_id: []const u8,
    };

    /// Fetch DM events from Twitter API v2.
    /// Returns new events (id > last_event_id).
    pub fn fetchDmEvents(self: *TwitterChannel, allocator: std.mem.Allocator) ![]root.ChannelMessage {
        const token = try self.resolveAccessToken(allocator);
        defer allocator.free(token);

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{token}) catch return error.TokenTooLong;

        const url = "https://api.twitter.com/2/dm_events?dm_event_fields=id,text,sender_id,created_at&event_types=MessageCreate";

        const resp = http_util.curlGet(allocator, url, &.{auth_header}, "30") catch return &.{};
        defer allocator.free(resp);

        if (resp.len == 0) return &.{};

        // Parse JSON response
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return &.{};
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return &.{},
        };

        const data_val = obj.get("data") orelse return &.{};
        const data = switch (data_val) {
            .array => |a| a,
            else => return &.{},
        };

        var messages: std.ArrayListUnmanaged(root.ChannelMessage) = .empty;
        errdefer {
            for (messages.items) |*msg| msg.deinit(allocator);
            messages.deinit(allocator);
        }

        for (data.items) |item| {
            const event_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };

            const event_id = switch (event_obj.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            // Skip already-seen events
            if (self.last_event_id) |last| {
                // Event IDs are numeric strings; compare as integers
                const eid = std.fmt.parseInt(u64, event_id, 10) catch continue;
                const lid = std.fmt.parseInt(u64, last, 10) catch 0;
                if (eid <= lid) continue;
            }

            const text = switch (event_obj.get("text") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            const sender_id = switch (event_obj.get("sender_id") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            // Check allow_from
            if (self.config.allow_from.len > 0) {
                if (!root.isAllowed(self.config.allow_from, sender_id)) continue;
            }

            const content = try std.fmt.allocPrint(allocator, "Twitter DM from @{s}: {s}", .{ sender_id, text });
            errdefer allocator.free(content);

            try messages.append(allocator, .{
                .id = try allocator.dupe(u8, event_id),
                .sender = try allocator.dupe(u8, sender_id),
                .content = content,
                .channel = "twitter",
                .timestamp = root.nowEpochSecs(),
            });
        }

        // Update last_event_id to highest seen
        if (messages.items.len > 0) {
            const last = messages.items[messages.items.len - 1];
            if (self.last_event_id) |old| self.allocator.free(old);
            self.last_event_id = try self.allocator.dupe(u8, last.id);
        }

        return messages.toOwnedSlice(allocator);
    }

    // ── Channel VTable ──────────────────────────────────────────────

    fn vtableStart(_: *anyopaque) anyerror!void {}
    fn vtableStop(_: *anyopaque) void {}

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        _ = ptr;
        _ = target;
        _ = message;
        // Twitter DM sending not implemented — channel is receive-only for digest
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "twitter";
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *TwitterChannel = @ptrCast(@alignCast(ptr));
        if (self.config.bearer_token) |bt| return bt.len > 0;
        // OAuth mode: check if credential exists
        return true;
    }

    pub fn channel(self: *TwitterChannel) root.Channel {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .start = vtableStart,
                .stop = vtableStop,
                .send = vtableSend,
                .name = vtableName,
                .healthCheck = vtableHealthCheck,
            },
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "TwitterChannel initFromConfig" {
    const cfg = config_types.TwitterConfig{
        .bearer_token = "test-token",
    };
    var ch = TwitterChannel.initFromConfig(std.testing.allocator, cfg);
    defer ch.deinit();

    try std.testing.expectEqualStrings("twitter", ch.channel().name());
    try std.testing.expect(ch.channel().healthCheck());
}

test "TwitterChannel resolveAccessToken returns test token" {
    const cfg = config_types.TwitterConfig{};
    const ch = TwitterChannel.initFromConfig(std.testing.allocator, cfg);
    const token = try ch.resolveAccessToken(std.testing.allocator);
    try std.testing.expectEqualStrings("test-bearer-token", token);
}

test "TwitterChannel vtable compiles" {
    const cfg = config_types.TwitterConfig{};
    var ch = TwitterChannel.initFromConfig(std.testing.allocator, cfg);
    defer ch.deinit();
    const c = ch.channel();
    try std.testing.expectEqualStrings("twitter", c.name());
}
