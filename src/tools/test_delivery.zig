const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const http_util = @import("../http_util.zig");
const config_mutator = @import("../config_mutator.zig");

/// TestDelivery tool — send a test message via a configured channel.
pub const TestDeliveryTool = struct {
    pub const tool_name = "test_delivery";
    pub const tool_description = "Send a test message via a configured delivery channel (e.g. Slack) to verify setup.";
    pub const tool_params =
        \\{"type":"object","properties":{"channel":{"type":"string","description":"Delivery channel: 'slack'"},"target":{"type":"string","description":"Channel ID or recipient (e.g. C...)"},"message":{"type":"string","description":"Test message text"}},"required":["channel"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TestDeliveryTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *TestDeliveryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const channel = root.getString(args, "channel") orelse
            return ToolResult.fail("Missing 'channel' parameter");
        const message = root.getString(args, "message") orelse "Hello from daybrief! This is a test message.";

        if (!std.mem.eql(u8, channel, "slack"))
            return ToolResult.fail("Unsupported channel — currently only 'slack' is supported");

        if (builtin.is_test) {
            return ToolResult.ok("Test message sent to Slack (mock)");
        }

        // Load bot_token from config
        const config_json = config_mutator.getPathValueJson(allocator, "channels.slack") catch
            return ToolResult.fail("Slack not configured — run setup_slack first");
        defer allocator.free(config_json);

        // Parse the JSON array to extract bot_token and channel_id
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{}) catch
            return ToolResult.fail("Invalid Slack config format");
        defer parsed.deinit();

        if (parsed.value != .array or parsed.value.array.items.len == 0)
            return ToolResult.fail("Slack config is empty — run setup_slack first");

        const first = parsed.value.array.items[0];
        if (first != .object)
            return ToolResult.fail("Invalid Slack config entry");

        const bot_token = blk: {
            const v = first.object.get("bot_token") orelse
                return ToolResult.fail("No bot_token in Slack config");
            if (v != .string) return ToolResult.fail("Invalid bot_token in Slack config");
            break :blk v.string;
        };

        // Use explicit target or fall back to config channel_id
        const target = root.getString(args, "target") orelse blk: {
            const v = first.object.get("channel_id") orelse
                return ToolResult.fail("No target specified and no channel_id in config");
            if (v != .string) return ToolResult.fail("Invalid channel_id in config");
            break :blk v.string;
        };

        // Send message via Slack API
        const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bot_token});
        defer allocator.free(auth_header);

        const body = try std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"{s}\",\"text\":\"{s}\"}}",
            .{ target, message },
        );
        defer allocator.free(body);

        const resp = http_util.curlPost(
            allocator,
            "https://slack.com/api/chat.postMessage",
            body,
            &.{ auth_header, "Content-Type: application/json" },
        ) catch
            return ToolResult.fail("Failed to send Slack message");
        defer allocator.free(resp);

        // Check response
        const resp_parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch
            return ToolResult.fail("Invalid response from Slack API");
        defer resp_parsed.deinit();

        const ok_val = resp_parsed.value.object.get("ok") orelse
            return ToolResult.fail("Unexpected Slack API response");
        if (ok_val != .bool or !ok_val.bool) {
            const err_msg = blk: {
                const e = resp_parsed.value.object.get("error") orelse break :blk "unknown error";
                if (e != .string) break :blk "unknown error";
                break :blk e.string;
            };
            const msg = try std.fmt.allocPrint(allocator, "Slack API error: {s}", .{err_msg});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        }

        const success_msg = try std.fmt.allocPrint(allocator, "Test message sent to {s}", .{target});
        return ToolResult{ .success = true, .output = success_msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "test_delivery tool name" {
    var t = TestDeliveryTool{};
    const tool_inst = t.tool();
    try std.testing.expectEqualStrings("test_delivery", tool_inst.name());
}

test "test_delivery params schema" {
    var t = TestDeliveryTool{};
    const tool_inst = t.tool();
    const schema = tool_inst.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "channel") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "message") != null);
}

test "test_delivery missing channel" {
    var t = TestDeliveryTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "channel") != null);
}

test "test_delivery unsupported channel" {
    var t = TestDeliveryTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"channel\":\"discord\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Unsupported") != null);
}

test "test_delivery slack mock success" {
    var t = TestDeliveryTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"channel\":\"slack\",\"target\":\"C123\",\"message\":\"hello\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Test message sent to Slack (mock)", result.output);
}
