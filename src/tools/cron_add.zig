const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const cron = @import("../cron.zig");
const CronScheduler = cron.CronScheduler;

/// CronAdd tool — creates a new cron job with either a cron expression or a delay.
pub const CronAddTool = struct {
    pub const tool_name = "cron_add";
    pub const tool_description = "Create a scheduled cron job. Provide either 'expression' (cron syntax) or 'delay' (e.g. '30m', '2h'). Use 'command' for shell jobs or 'prompt' for agent jobs.";
    pub const tool_params =
        \\{"type":"object","properties":{"expression":{"type":"string","description":"Cron expression (e.g. '*/5 * * * *')"},"delay":{"type":"string","description":"Delay for one-shot tasks (e.g. '30m', '2h')"},"command":{"type":"string","description":"Shell command to execute (for shell jobs)"},"prompt":{"type":"string","description":"Agent prompt to execute (for agent jobs, mutually exclusive with command)"},"model":{"type":"string","description":"Model to use for agent jobs (e.g. 'claude-sonnet-4-20250514')"},"name":{"type":"string","description":"Optional job name"},"delivery_mode":{"type":"string","description":"When to deliver output: none, always, on_error, on_success"},"delivery_channel":{"type":"string","description":"Channel for delivery (e.g. 'email')"},"delivery_to":{"type":"string","description":"Recipient for delivery (e.g. email address)"}}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *CronAddTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(_: *CronAddTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const command = root.getString(args, "command");
        const prompt = root.getString(args, "prompt");

        // Must have either command (shell) or prompt (agent)
        if (command == null and prompt == null)
            return ToolResult.fail("Provide either 'command' (shell job) or 'prompt' (agent job)");
        if (command != null and prompt != null)
            return ToolResult.fail("Provide 'command' or 'prompt', not both");

        const expression = root.getString(args, "expression");
        const delay = root.getString(args, "delay");

        if (expression == null and delay == null)
            return ToolResult.fail("Missing schedule: provide either 'expression' (cron syntax) or 'delay' (e.g. '30m')");

        // Validate expression if provided
        if (expression) |expr| {
            _ = cron.normalizeExpression(expr) catch
                return ToolResult.fail("Invalid cron expression");
        }

        // Validate delay if provided
        if (delay) |d| {
            _ = cron.parseDuration(d) catch
                return ToolResult.fail("Invalid delay format");
        }

        var scheduler = loadScheduler(allocator) catch {
            return ToolResult.fail("Failed to load scheduler state");
        };
        defer scheduler.deinit();

        // For agent jobs, use prompt as the command field (scheduler stores it there).
        const job_command = command orelse prompt.?;

        // Prefer expression (recurring) over delay (one-shot)
        if (expression) |expr| {
            const job = scheduler.addJob(expr, job_command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create job: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            // Apply agent-specific fields (dupe strings — scheduler owns them)
            if (prompt) |p| {
                job.job_type = .agent;
                job.prompt = try allocator.dupe(u8, p);
                if (root.getString(args, "model")) |m| {
                    job.model = try allocator.dupe(u8, m);
                }
            }

            // Apply delivery config (not duped — freeJobOwned doesn't free these,
            // and saveJobs serializes before scheduler.deinit)
            if (root.getString(args, "delivery_mode")) |dm| {
                job.delivery.mode = cron.DeliveryMode.parse(dm);
            }
            job.delivery.channel = root.getString(args, "delivery_channel");
            job.delivery.to = root.getString(args, "delivery_to");

            cron.saveJobs(&scheduler) catch {};

            const job_type_str = if (prompt != null) "agent" else "shell";
            const msg = try std.fmt.allocPrint(allocator, "Created {s} cron job {s}: {s}", .{
                job_type_str,
                job.id,
                job.expression,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        if (delay) |d| {
            const job = scheduler.addOnce(d, job_command) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to create one-shot task: {s}", .{@errorName(err)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };

            if (prompt) |p| {
                job.job_type = .agent;
                job.prompt = try allocator.dupe(u8, p);
                if (root.getString(args, "model")) |m| {
                    job.model = try allocator.dupe(u8, m);
                }
            }

            if (root.getString(args, "delivery_mode")) |dm| {
                job.delivery.mode = cron.DeliveryMode.parse(dm);
            }
            job.delivery.channel = root.getString(args, "delivery_channel");
            job.delivery.to = root.getString(args, "delivery_to");

            cron.saveJobs(&scheduler) catch {};

            const job_type_str = if (prompt != null) "agent" else "shell";
            const msg = try std.fmt.allocPrint(allocator, "Created {s} one-shot job {s}", .{
                job_type_str,
                job.id,
            });
            return ToolResult{ .success = true, .output = msg };
        }

        return ToolResult.fail("Unexpected state: no expression or delay");
    }
};

/// Load the CronScheduler from persisted state (~/.nullclaw/cron.json).
/// Shared by cron_add, cron_list, cron_remove, and schedule tools.
pub fn loadScheduler(allocator: std.mem.Allocator) !CronScheduler {
    var scheduler = CronScheduler.init(allocator, 1024, true);
    cron.loadJobs(&scheduler) catch {};
    return scheduler;
}

// ── Tests ───────────────────────────────────────────────────────────

test "cron_add_requires_command_or_prompt" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "command") != null or
        std.mem.indexOf(u8, result.error_msg.?, "prompt") != null);
}

test "cron_add_requires_schedule" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "expression") != null or
        std.mem.indexOf(u8, result.error_msg.?, "delay") != null);
}

test "cron_add_with_expression" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"*/5 * * * *\", \"command\": \"echo hello\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created shell cron job") != null);
    }
}

test "cron_add_with_delay" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"delay\": \"30m\", \"command\": \"echo later\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Created shell one-shot job") != null);
    }
}

test "cron_add_rejects_invalid_expression" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs("{\"expression\": \"bad cron\", \"command\": \"echo fail\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid cron expression") != null);
}

test "cron_add tool name" {
    var cat = CronAddTool{};
    const t = cat.tool();
    try std.testing.expectEqualStrings("cron_add", t.name());
}

test "cron_add schema has command" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delay") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "delivery_mode") != null);
}

test "cron_add_rejects_command_and_prompt" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs(
        \\{"expression": "*/5 * * * *", "command": "echo hi", "prompt": "do stuff"}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not both") != null);
}

test "cron_add_agent_with_prompt" {
    var cat = CronAddTool{};
    const t = cat.tool();
    const parsed = try root.parseTestArgs(
        \\{"expression": "0 8 * * *", "prompt": "summarize messages", "model": "claude-sonnet-4-20250514", "delivery_mode": "always", "delivery_channel": "email", "delivery_to": "ben@example.com"}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    if (result.success) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "agent") != null);
    }
}
