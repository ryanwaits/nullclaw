const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const http_util = @import("../http_util.zig");
const config_mutator = @import("../config_mutator.zig");

/// SetupSlack tool — validate a Slack bot token, resolve channel or DM target, and write config.
pub const SetupSlackTool = struct {
    pub const tool_name = "setup_slack";
    pub const tool_description = "Configure Slack integration: validates bot token, resolves channel name or @username to ID, opens DM if needed, and writes config. Requires restart to activate.";
    pub const tool_params =
        \\{"type":"object","properties":{"bot_token":{"type":"string","description":"Slack bot token (starts with xoxb-)"},"channel":{"type":"string","description":"Channel name (#general), channel ID (C...), @username for DM, or 'dm' for DM to installing user"}},"required":["bot_token","channel"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SetupSlackTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Resolve @username to a Slack user ID via users.list
    fn resolveUsername(allocator: std.mem.Allocator, bot_token: []const u8, username: []const u8) !?[]const u8 {
        if (builtin.is_test) return try allocator.dupe(u8, "U_TEST_USER");

        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
        defer allocator.free(auth_header);

        const url = try std.fmt.allocPrint(allocator, "https://slack.com/api/users.list?limit=200", .{});
        defer allocator.free(url);

        const resp = http_util.curlGet(allocator, url, &.{auth_header}, "15") catch return null;
        defer allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return null;
        defer parsed.deinit();

        const ok_val = parsed.value.object.get("ok") orelse return null;
        if (ok_val != .bool or !ok_val.bool) return null;

        const members = blk: {
            const m = parsed.value.object.get("members") orelse return null;
            if (m != .array) return null;
            break :blk m.array;
        };

        for (members.items) |member| {
            if (member != .object) continue;
            const name = member.object.get("name") orelse continue;
            if (name != .string) continue;
            if (std.mem.eql(u8, name.string, username)) {
                const id = member.object.get("id") orelse continue;
                if (id != .string) continue;
                return try allocator.dupe(u8, id.string);
            }
            // Also check display_name and real_name
            if (member.object.get("profile")) |profile| {
                if (profile == .object) {
                    if (profile.object.get("display_name")) |dn| {
                        if (dn == .string and std.ascii.eqlIgnoreCase(dn.string, username)) {
                            const id = member.object.get("id") orelse continue;
                            if (id != .string) continue;
                            return try allocator.dupe(u8, id.string);
                        }
                    }
                    if (profile.object.get("real_name")) |rn| {
                        if (rn == .string and std.ascii.eqlIgnoreCase(rn.string, username)) {
                            const id = member.object.get("id") orelse continue;
                            if (id != .string) continue;
                            return try allocator.dupe(u8, id.string);
                        }
                    }
                }
            }
        }
        return null;
    }

    /// Open a DM channel with a user via conversations.open
    fn openDmChannel(allocator: std.mem.Allocator, bot_token: []const u8, user_id: []const u8) !?[]const u8 {
        if (builtin.is_test) return try allocator.dupe(u8, "D_TEST_DM");

        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
        defer allocator.free(auth_header);

        const body = try std.fmt.allocPrint(allocator, "{{\"users\":\"{s}\"}}", .{user_id});
        defer allocator.free(body);

        const resp = http_util.curlPost(allocator, "https://slack.com/api/conversations.open", body, &.{ auth_header, "Content-Type: application/json" }) catch return null;
        defer allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return null;
        defer parsed.deinit();

        const ok_val = parsed.value.object.get("ok") orelse return null;
        if (ok_val != .bool or !ok_val.bool) return null;

        const ch = parsed.value.object.get("channel") orelse return null;
        if (ch != .object) return null;
        const ch_id = ch.object.get("id") orelse return null;
        if (ch_id != .string) return null;

        return try allocator.dupe(u8, ch_id.string);
    }

    /// Get the user ID of the bot's installer via auth.test
    fn getAuthUserId(allocator: std.mem.Allocator, bot_token: []const u8) !?[]const u8 {
        if (builtin.is_test) return try allocator.dupe(u8, "U_TEST_SELF");

        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
        defer allocator.free(auth_header);

        const resp = http_util.curlGet(allocator, "https://slack.com/api/auth.test", &.{auth_header}, "10") catch return null;
        defer allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return null;
        defer parsed.deinit();

        const ok_val = parsed.value.object.get("ok") orelse return null;
        if (ok_val != .bool or !ok_val.bool) return null;

        const user_id = parsed.value.object.get("user_id") orelse return null;
        if (user_id != .string) return null;

        return try allocator.dupe(u8, user_id.string);
    }

    pub fn execute(_: *SetupSlackTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const bot_token = root.getString(args, "bot_token") orelse
            return ToolResult.fail("Missing 'bot_token' parameter");
        const channel = root.getString(args, "channel") orelse
            return ToolResult.fail("Missing 'channel' parameter");

        // Validate token format
        if (!std.mem.startsWith(u8, bot_token, "xoxb-"))
            return ToolResult.fail("Invalid bot token — must start with 'xoxb-'");

        // Validate token via auth.test and get team name
        var team_name: []const u8 = "unknown";
        if (builtin.is_test) {
            team_name = "test-workspace";
        } else {
            const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
            defer allocator.free(auth_header);

            const resp = http_util.curlGet(allocator, "https://slack.com/api/auth.test", &.{auth_header}, "10") catch
                return ToolResult.fail("Failed to reach Slack API");
            defer allocator.free(resp);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
                return ToolResult.fail("Invalid response from Slack API");
            defer parsed.deinit();

            const ok_val = parsed.value.object.get("ok") orelse
                return ToolResult.fail("Unexpected Slack API response");
            if (ok_val != .bool or !ok_val.bool)
                return ToolResult.fail("Slack token validation failed — check your bot token");

            if (parsed.value.object.get("team")) |t| {
                if (t == .string) team_name = try allocator.dupe(u8, t.string);
            }
        }
        const team_owned = if (!builtin.is_test and !std.mem.eql(u8, team_name, "unknown"))
            team_name
        else
            null;
        defer if (team_owned) |t| allocator.free(t);

        // Resolve channel/DM target
        var channel_id: []const u8 = channel;
        var channel_id_owned: ?[]const u8 = null;
        defer if (channel_id_owned) |c| allocator.free(c);

        var target_desc: []const u8 = channel;
        var target_desc_owned: ?[]const u8 = null;
        defer if (target_desc_owned) |d| allocator.free(d);

        if (std.mem.startsWith(u8, channel, "#")) {
            // Resolve #channel-name to channel ID
            const name = channel[1..];
            if (builtin.is_test) {
                channel_id = "C_TEST_123";
            } else {
                const list_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
                defer allocator.free(list_header);

                const list_url = try std.fmt.allocPrint(allocator, "https://slack.com/api/conversations.list?types=public_channel&limit=200", .{});
                defer allocator.free(list_url);

                const list_resp = http_util.curlGet(allocator, list_url, &.{list_header}, "15") catch
                    return ToolResult.fail("Failed to list Slack channels — ensure bot has channels:read scope");
                defer allocator.free(list_resp);

                const list_parsed = std.json.parseFromSlice(std.json.Value, allocator, list_resp, .{}) catch
                    return ToolResult.fail("Invalid response from Slack channels API");
                defer list_parsed.deinit();

                // Check for scope error
                if (list_parsed.value.object.get("ok")) |ok| {
                    if (ok == .bool and !ok.bool) {
                        if (list_parsed.value.object.get("error")) |err| {
                            if (err == .string and std.mem.eql(u8, err.string, "missing_scope")) {
                                return ToolResult.fail("Bot is missing 'channels:read' scope — reinstall the Slack app with updated permissions");
                            }
                        }
                        return ToolResult.fail("Failed to list channels — check bot permissions");
                    }
                }

                const channels = blk: {
                    const ch = list_parsed.value.object.get("channels") orelse
                        return ToolResult.fail("No channels in Slack response");
                    if (ch != .array) return ToolResult.fail("Unexpected channels format");
                    break :blk ch.array;
                };

                var found = false;
                for (channels.items) |ch| {
                    if (ch != .object) continue;
                    const ch_name = ch.object.get("name") orelse continue;
                    if (ch_name != .string) continue;
                    if (std.mem.eql(u8, ch_name.string, name)) {
                        const ch_id = ch.object.get("id") orelse continue;
                        if (ch_id != .string) continue;
                        channel_id_owned = try allocator.dupe(u8, ch_id.string);
                        channel_id = channel_id_owned.?;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    const msg = try std.fmt.allocPrint(allocator, "Channel #{s} not found (checked 200 public channels)", .{name});
                    return ToolResult{ .success = false, .output = "", .error_msg = msg };
                }
            }
        } else if (std.mem.startsWith(u8, channel, "@")) {
            // Resolve @username to user ID, then open DM
            const username = channel[1..];
            const user_id = try resolveUsername(allocator, bot_token, username) orelse {
                const msg = try std.fmt.allocPrint(allocator, "User @{s} not found — ensure bot has users:read scope", .{username});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            defer allocator.free(user_id);

            const dm_channel = try openDmChannel(allocator, bot_token, user_id) orelse
                return ToolResult.fail("Failed to open DM channel — ensure bot has im:write scope");

            channel_id_owned = dm_channel;
            channel_id = channel_id_owned.?;
            target_desc_owned = try std.fmt.allocPrint(allocator, "DM to @{s} ({s})", .{ username, user_id });
            target_desc = target_desc_owned.?;
        } else if (std.ascii.eqlIgnoreCase(channel, "dm") or std.ascii.eqlIgnoreCase(channel, "dm me") or std.ascii.eqlIgnoreCase(channel, "me")) {
            // DM to the installing user
            const user_id = try getAuthUserId(allocator, bot_token) orelse
                return ToolResult.fail("Failed to get installer user ID from auth.test");
            defer allocator.free(user_id);

            const dm_channel = try openDmChannel(allocator, bot_token, user_id) orelse
                return ToolResult.fail("Failed to open DM channel — ensure bot has im:write scope");

            channel_id_owned = dm_channel;
            channel_id = channel_id_owned.?;
            target_desc_owned = try std.fmt.allocPrint(allocator, "DM to installer ({s})", .{user_id});
            target_desc = target_desc_owned.?;
        } else if (std.mem.startsWith(u8, channel, "U")) {
            // Raw user ID — open DM
            const dm_channel = try openDmChannel(allocator, bot_token, channel) orelse
                return ToolResult.fail("Failed to open DM channel — ensure bot has im:write scope");

            channel_id_owned = dm_channel;
            channel_id = channel_id_owned.?;
            target_desc_owned = try std.fmt.allocPrint(allocator, "DM to user {s}", .{channel});
            target_desc = target_desc_owned.?;
        }
        // else: assume it's a raw channel ID (C... or D...) and use as-is

        // Write config via config_mutator
        const config_value = try std.fmt.allocPrint(
            allocator,
            "[{{\"bot_token\":\"{s}\",\"channel_id\":\"{s}\",\"mode\":\"http\"}}]",
            .{ bot_token, channel_id },
        );
        defer allocator.free(config_value);

        if (!builtin.is_test) {
            var result = config_mutator.mutateDefaultConfig(allocator, .set, "channels.slack", config_value, .{ .apply = true }) catch
                return ToolResult.fail("Failed to write Slack config");
            config_mutator.freeMutationResult(allocator, &result);
        }

        // Build success message
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("Slack configured for team '{s}', target: {s} (channel_id: {s}). Restart required to activate.", .{ team_name, target_desc, channel_id });

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "setup_slack tool name" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    try std.testing.expectEqualStrings("setup_slack", tool_inst.name());
}

test "setup_slack params schema" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const schema = tool_inst.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "bot_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "channel") != null);
}

test "setup_slack missing bot_token" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "bot_token") != null);
}

test "setup_slack missing channel" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bot_token\":\"xoxb-test\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "channel") != null);
}

test "setup_slack invalid token prefix" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bot_token\":\"bad-token\",\"channel\":\"C123\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "xoxb-") != null);
}

test "setup_slack success with channel ID" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bot_token\":\"xoxb-test-token\",\"channel\":\"C123ABC\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Slack configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "C123ABC") != null);
}

test "setup_slack success with channel name" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bot_token\":\"xoxb-test-token\",\"channel\":\"#general\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Slack configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "C_TEST_123") != null);
}

test "setup_slack success with @username" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bot_token\":\"xoxb-test-token\",\"channel\":\"@ryan\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Slack configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "D_TEST_DM") != null);
}

test "setup_slack success with dm shortcut" {
    var t = SetupSlackTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bot_token\":\"xoxb-test-token\",\"channel\":\"dm\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Slack configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "D_TEST_DM") != null);
}
