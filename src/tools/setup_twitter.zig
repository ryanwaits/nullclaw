const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const http_util = @import("../http_util.zig");
const config_mutator = @import("../config_mutator.zig");

/// SetupTwitter tool — validate a Twitter/X bearer token and write config.
pub const SetupTwitterTool = struct {
    pub const tool_name = "setup_twitter";
    pub const tool_description = "Configure Twitter/X integration: validates bearer token and writes config. Requires restart to activate.";
    pub const tool_params =
        \\{"type":"object","properties":{"bearer_token":{"type":"string","description":"Twitter/X API bearer token"}},"required":["bearer_token"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SetupTwitterTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *SetupTwitterTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const bearer_token = root.getString(args, "bearer_token") orelse
            return ToolResult.fail("Missing 'bearer_token' parameter");

        if (bearer_token.len == 0)
            return ToolResult.fail("Bearer token cannot be empty");

        // Validate token via /2/users/me
        var username: []const u8 = "unknown";
        if (builtin.is_test) {
            username = "testuser";
        } else {
            const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bearer_token});
            defer allocator.free(auth_header);

            const resp = http_util.curlGet(allocator, "https://api.twitter.com/2/users/me", &.{auth_header}, "10") catch
                return ToolResult.fail("Failed to reach Twitter API");
            defer allocator.free(resp);

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
                return ToolResult.fail("Invalid response from Twitter API");
            defer parsed.deinit();

            // Check for errors
            if (parsed.value.object.get("errors")) |_|
                return ToolResult.fail("Twitter token validation failed — check your bearer token");

            // Extract username from data.username
            const data = parsed.value.object.get("data") orelse
                return ToolResult.fail("Unexpected Twitter API response — no data field");
            if (data != .object)
                return ToolResult.fail("Unexpected Twitter API response format");

            if (data.object.get("username")) |u| {
                if (u == .string) username = try allocator.dupe(u8, u.string);
            }
        }
        const username_owned = if (!builtin.is_test and !std.mem.eql(u8, username, "unknown"))
            username
        else
            null;
        defer if (username_owned) |u| allocator.free(u);

        // Write config
        const config_value = try std.fmt.allocPrint(
            allocator,
            "[{{\"bearer_token\":\"{s}\"}}]",
            .{bearer_token},
        );
        defer allocator.free(config_value);

        if (!builtin.is_test) {
            var result = config_mutator.mutateDefaultConfig(allocator, .set, "channels.twitter", config_value, .{ .apply = true }) catch
                return ToolResult.fail("Failed to write Twitter config");
            config_mutator.freeMutationResult(allocator, &result);
        }

        // Build success message
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("Twitter configured for @{s}. Restart required to activate.", .{username});

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "setup_twitter tool name" {
    var t = SetupTwitterTool{};
    const tool_inst = t.tool();
    try std.testing.expectEqualStrings("setup_twitter", tool_inst.name());
}

test "setup_twitter params schema" {
    var t = SetupTwitterTool{};
    const tool_inst = t.tool();
    const schema = tool_inst.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "bearer_token") != null);
}

test "setup_twitter missing token" {
    var t = SetupTwitterTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "bearer_token") != null);
}

test "setup_twitter empty token" {
    var t = SetupTwitterTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bearer_token\":\"\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "empty") != null);
}

test "setup_twitter success" {
    var t = SetupTwitterTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"bearer_token\":\"AAAA_test_token\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Twitter configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@testuser") != null);
}
