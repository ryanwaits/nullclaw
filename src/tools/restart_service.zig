const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// RestartService tool — restart a managed service via brew services.
pub const RestartServiceTool = struct {
    pub const tool_name = "restart_service";
    pub const tool_description = "Restart a managed service. Currently only supports 'daybrief'. Use after config changes that require restart.";
    pub const tool_params =
        \\{"type":"object","properties":{"service":{"type":"string","description":"Service name to restart (only 'daybrief' allowed)"}},"required":["service"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *RestartServiceTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *RestartServiceTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const service = root.getString(args, "service") orelse
            return ToolResult.fail("Missing 'service' parameter");

        if (!std.mem.eql(u8, service, "daybrief"))
            return ToolResult.fail("Only 'daybrief' service can be restarted");

        if (builtin.is_test) {
            return ToolResult.ok("Service daybrief restarted.");
        }

        // Shell out to brew services restart
        var child = std.process.Child.init(
            &.{ "brew", "services", "restart", "daybrief" },
            allocator,
        );
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();
        const stderr = if (child.stderr) |f| f.readToEndAlloc(allocator, 4096) catch "" else "";
        defer if (stderr.len > 0) allocator.free(stderr);
        if (child.stdout) |f| {
            const stdout = f.readToEndAlloc(allocator, 4096) catch "";
            if (stdout.len > 0) allocator.free(stdout);
        }
        const term = child.wait() catch
            return ToolResult.fail("Failed to wait for brew services");

        switch (term) {
            .Exited => |code| if (code != 0) {
                const msg = try std.fmt.allocPrint(allocator, "brew services restart failed (exit {d}): {s}", .{ code, stderr });
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
            else => return ToolResult.fail("brew services restart terminated abnormally"),
        }

        return ToolResult.ok("Service daybrief restarted.");
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "restart_service tool name" {
    var t = RestartServiceTool{};
    const tool_inst = t.tool();
    try std.testing.expectEqualStrings("restart_service", tool_inst.name());
}

test "restart_service params schema" {
    var t = RestartServiceTool{};
    const tool_inst = t.tool();
    const schema = tool_inst.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "service") != null);
}

test "restart_service missing service" {
    var t = RestartServiceTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "service") != null);
}

test "restart_service invalid service" {
    var t = RestartServiceTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"service\":\"postgres\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "daybrief") != null);
}

test "restart_service mock success" {
    var t = RestartServiceTool{};
    const tool_inst = t.tool();
    const parsed = try root.parseTestArgs("{\"service\":\"daybrief\"}");
    defer parsed.deinit();
    const result = try tool_inst.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Service daybrief restarted.", result.output);
}
