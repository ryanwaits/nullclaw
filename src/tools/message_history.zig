//! message_history tool — query iMessage chat.db for recent conversations.
//!
//! Returns a JSON array of messages within a time window, suitable for
//! daily digest generation. Includes both sent and received messages.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const imessage_attributed = @import("../channels/imessage_attributed.zig");
const sqlite_mod = if (build_options.enable_sqlite) @import("../memory/engines/sqlite.zig") else @import("../memory/engines/sqlite_disabled.zig");
const c = sqlite_mod.c;

/// Core Data epoch offset: 2001-01-01 00:00:00 UTC
const CORE_DATA_EPOCH: i64 = 978307200;

/// Nanoseconds per second (chat.db timestamps are nanosecond Core Data).
const NS_PER_SEC: i64 = 1_000_000_000;

pub const MessageHistoryTool = struct {
    db_path: ?[]const u8 = null,

    pub const tool_name = "message_history";
    pub const tool_description = "Query iMessage history for a time range. Returns JSON array of messages with sender, text, timestamp, and chat info. Useful for daily digests.";
    pub const tool_params =
        \\{"type":"object","properties":{"hours_back":{"type":"integer","description":"How many hours back to query (required)"},"contact":{"type":"string","description":"Filter to a specific contact phone/email (optional)"},"limit":{"type":"integer","description":"Max messages to return (default 200)"}},"required":["hours_back"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MessageHistoryTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MessageHistoryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const hours_back = root.getInt(args, "hours_back") orelse
            return ToolResult.fail("Missing required 'hours_back' parameter");
        if (hours_back <= 0)
            return ToolResult.fail("'hours_back' must be positive");

        const contact = root.getString(args, "contact");
        const limit = root.getInt(args, "limit") orelse 200;
        if (limit <= 0)
            return ToolResult.fail("'limit' must be positive");

        const db_path = self.db_path orelse defaultDbPath() orelse
            return ToolResult.fail("No iMessage database path configured and default not found");

        if (builtin.is_test) {
            return ToolResult.ok("[]");
        }

        return self.queryMessages(allocator, db_path, hours_back, contact, limit);
    }

    fn queryMessages(
        _: *MessageHistoryTool,
        allocator: std.mem.Allocator,
        db_path: []const u8,
        hours_back: i64,
        contact: ?[]const u8,
        limit: i64,
    ) !ToolResult {
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);

        var db: ?*c.sqlite3 = null;
        const open_flags: c_int = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX;
        if (c.sqlite3_open_v2(db_path_z.ptr, &db, open_flags, null) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return ToolResult.fail("Failed to open iMessage database");
        }
        defer _ = c.sqlite3_close(db.?);

        // Compute Core Data nanosecond timestamp for the cutoff.
        const now_unix = std.time.timestamp();
        const cutoff_unix = now_unix - (hours_back * 3600);
        const cutoff_cd = (cutoff_unix - CORE_DATA_EPOCH) * NS_PER_SEC;

        const sql_all =
            \\SELECT m.ROWID, h.id, m.text, c.guid, m.attributedBody,
            \\       m.is_from_me, m.date
            \\FROM message m
            \\LEFT JOIN handle h ON m.handle_id = h.ROWID
            \\LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            \\LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            \\WHERE m.date > ?1
            \\  AND m.associated_message_type = 0
            \\  AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
            \\ORDER BY m.date DESC
            \\LIMIT ?2
        ;

        const sql_contact =
            \\SELECT m.ROWID, h.id, m.text, c.guid, m.attributedBody,
            \\       m.is_from_me, m.date
            \\FROM message m
            \\LEFT JOIN handle h ON m.handle_id = h.ROWID
            \\LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            \\LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            \\WHERE m.date > ?1
            \\  AND m.associated_message_type = 0
            \\  AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
            \\  AND h.id = ?3
            \\ORDER BY m.date DESC
            \\LIMIT ?2
        ;

        const sql = if (contact != null) sql_contact else sql_all;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.?, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return ToolResult.fail("Failed to prepare SQL query");
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int64(stmt, 1, cutoff_cd) != c.SQLITE_OK)
            return ToolResult.fail("Failed to bind cutoff timestamp");
        if (c.sqlite3_bind_int64(stmt, 2, limit) != c.SQLITE_OK)
            return ToolResult.fail("Failed to bind limit");

        // Contact filter string must outlive query execution.
        var ct_z: ?[:0]u8 = null;
        defer if (ct_z) |z| allocator.free(z);
        if (contact) |ct| {
            ct_z = try allocator.dupeZ(u8, ct);
            if (c.sqlite3_bind_text(stmt, 3, ct_z.?.ptr, @intCast(ct_z.?.len), null) != c.SQLITE_OK)
                return ToolResult.fail("Failed to bind contact filter");
        }

        // Build JSON array output.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.writeAll("[");

        var count: usize = 0;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) break;

            // Extract text (prefer m.text, fall back to attributedBody).
            const text = blk: {
                if (c.sqlite3_column_text(stmt, 2)) |ptr| {
                    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
                    if (len > 0) break :blk ptr[0..len];
                }
                if (c.sqlite3_column_type(stmt, 4) != c.SQLITE_NULL) {
                    const blob_ptr = c.sqlite3_column_blob(stmt, 4);
                    const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
                    if (blob_ptr != null and blob_len > 0) {
                        const blob: []const u8 = @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len];
                        if (imessage_attributed.decodeAttributedBody(blob)) |decoded| break :blk decoded;
                    }
                }
                continue;
            };

            // Sender
            const sender = if (c.sqlite3_column_text(stmt, 1)) |ptr|
                ptr[0..@as(usize, @intCast(c.sqlite3_column_bytes(stmt, 1)))]
            else
                "unknown";

            // Chat GUID
            const chat_guid = if (c.sqlite3_column_text(stmt, 3)) |ptr|
                ptr[0..@as(usize, @intCast(c.sqlite3_column_bytes(stmt, 3)))]
            else
                "";

            const is_from_me = c.sqlite3_column_int(stmt, 5) != 0;
            const date_cd = c.sqlite3_column_int64(stmt, 6);
            const date_unix = @divTrunc(date_cd, NS_PER_SEC) + CORE_DATA_EPOCH;

            // Determine if group chat.
            const is_group = if (chat_guid.len > 0)
                std.mem.startsWith(u8, chat_guid, "chat")
            else
                false;

            if (count > 0) try w.writeAll(",");

            // Write JSON object. Escape text for JSON safety.
            try w.print("{{\"sender\":\"{s}\",\"text\":\"", .{sender});
            try writeJsonEscaped(w, text);
            try w.print("\",\"timestamp_unix\":{d},\"chat_guid\":\"{s}\",\"is_group\":{s},\"is_from_me\":{s}}}", .{
                date_unix,
                chat_guid,
                if (is_group) "true" else "false",
                if (is_from_me) "true" else "false",
            });

            count += 1;
        }

        try w.writeAll("]");

        return ToolResult{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }

    fn defaultDbPath() ?[]const u8 {
        if (comptime @import("builtin").os.tag == .macos) {
            return std.posix.getenv("HOME") orelse null;
        }
        return null;
    }
};

/// Write a string with JSON-safe escaping.
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "message_history requires hours_back" {
    var mht = MessageHistoryTool{};
    const t = mht.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "hours_back") != null);
}

test "message_history rejects zero hours" {
    var mht = MessageHistoryTool{};
    const t = mht.tool();
    const parsed = try root.parseTestArgs("{\"hours_back\": 0}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "message_history rejects negative limit" {
    var mht = MessageHistoryTool{};
    const t = mht.tool();
    const parsed = try root.parseTestArgs("{\"hours_back\": 24, \"limit\": -1}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "message_history tool name" {
    var mht = MessageHistoryTool{};
    const t = mht.tool();
    try std.testing.expectEqualStrings("message_history", t.name());
}

test "message_history schema has hours_back" {
    var mht = MessageHistoryTool{};
    const t = mht.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "hours_back") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "contact") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "limit") != null);
}

test "json escape handles special chars" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeJsonEscaped(w, "hello \"world\"\nnewline");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline", buf.items);
}
