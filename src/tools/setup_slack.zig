const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const http_util = @import("../http_util.zig");
const config_mutator = @import("../config_mutator.zig");

/// SetupSlack tool — validate a Slack bot token, resolve channel, and write config.
pub const SetupSlackTool = struct {
    pub const tool_name = "setup_slack";
    pub const tool_description = "Configure Slack integration: validates bot token, resolves channel name to ID, and writes config. Requires restart to activate.";
    pub const tool_params =
        \\{"type":"object","properties":{"bot_token":{"type":"string","description":"Slack bot token (starts with xoxb-)"},"channel":{"type":"string","description":"Slack channel ID (C...) or channel name (#general)"}},"required":["bot_token","channel"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SetupSlackTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *SetupSlackTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const bot_token = root.getString(args, "bot_token") orelse
            return ToolResult.fail("Missing 'bot_token' parameter");
        const channel = root.getString(args, "channel") orelse
            return ToolResult.fail("Missing 'channel' parameter");

        // Validate token format
        if (!std.mem.startsWith(u8, bot_token, "xoxb-"))
            return ToolResult.fail("Invalid bot token — must start with 'xoxb-'");

        // Validate token via auth.test
        var team_name: []const u8 = "unknown";
        if (builtin.is_test) {
            team_name = "test-workspace";
        } else {
            const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
            defer allocator.free(auth_header);

            const resp = http_util.curlGet(allocator, "https://slack.com/api/auth.test", &.{auth_header}, "10") catch
                return ToolResult.fail("Failed to reach Slack API");
            defer allocator.free(resp);

            // Parse response for "ok" field
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

        // Resolve channel name to ID if it starts with #
        var channel_id: []const u8 = channel;
        var channel_id_owned: ?[]const u8 = null;
        defer if (channel_id_owned) |c| allocator.free(c);

        if (std.mem.startsWith(u8, channel, "#")) {
            const name = channel[1..];
            if (builtin.is_test) {
                channel_id = "C_TEST_123";
            } else {
                const list_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
                defer allocator.free(list_header);

                const list_url = try std.fmt.allocPrint(allocator, "https://slack.com/api/conversations.list?types=public_channel&limit=200", .{});
                defer allocator.free(list_url);

                const list_resp = http_util.curlGet(allocator, list_url, &.{list_header}, "15") catch
                    return ToolResult.fail("Failed to list Slack channels");
                defer allocator.free(list_resp);

                const list_parsed = std.json.parseFromSlice(std.json.Value, allocator, list_resp, .{}) catch
                    return ToolResult.fail("Invalid response from Slack channels API");
                defer list_parsed.deinit();

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
        }

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
        try w.print("Slack configured for team '{s}', channel {s}. Restart required to activate.", .{ team_name, channel_id });

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
