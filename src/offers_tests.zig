const std = @import("std");
const sdk = @import("r4os");
const a = sdk.abi;
const o = @import("offers.zig");
const t = std.testing;
fn init() !o.Store {
    var s = o.Store.init(t.allocator, 17);
    try s.advance(.{ .identity = .{ .source = 1, .generation = 1, .tick_hz = 100 }, .instant_ns = 100 });
    return s;
}
fn begin(s: *o.Store, bytes: u64) !a.ClipboardOfferLease {
    return s.begin(.{ .provider = s.provider, .expected_revision = s.revision, .total_bytes = bytes });
}
fn copy(s: *o.Store, stage: a.ClipboardOfferLease, item: u32, format: u32, bytes: []const u8) !void {
    var r = sdk.clipboard_offer.transfer(stage, item, format, 0, bytes.len);
    try s.declare(r);
    var offset: usize = 0;
    while (offset < bytes.len) {
        r.offset = offset;
        const n = @min(bytes.len - offset, a.clipboard_offer_put_chunk);
        try s.put(r, bytes[offset..][0..n]);
        offset += n;
    }
}
test "copied offers publish atomically and snapshots never mix revisions" {
    var s = try init();
    defer s.deinit();
    try s.legacyWrite("before");
    const old = try s.acquire();
    const stage = try begin(&s, 128);
    try copy(&s, stage, 2, a.clipboard_offer_format_text_utf8, "new\xc3\xa4");
    var pixels = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 3, 2, 1, 0 };
    try copy(&s, stage, 4, a.clipboard_offer_format_xrgb32, &pixels);
    pixels[16] = 99;
    try t.expectEqualStrings("before", s.legacyText());
    const committed = try s.commit(stage);
    try t.expectEqualStrings("new\xc3\xa4", s.legacyText());
    const snapshot = try s.acquire();
    var formats: [1]a.ClipboardOfferFormat = undefined;
    var page = try s.enumerate(.{ .provider = 17, .id = snapshot.id, .capacity = 1 }, &formats);
    try t.expectEqual(@as(u32, 2), page.total);
    try t.expectEqual(@as(u32, 1), page.next);
    page = try s.enumerate(.{ .provider = 17, .id = snapshot.id, .cursor = page.next, .capacity = 1 }, &formats);
    try t.expectEqual(@as(u32, 2), page.next);
    try t.expectEqual(@as(u32, 4), formats[0].item);
    const part = try s.read(sdk.clipboard_offer.transfer(snapshot, 4, a.clipboard_offer_format_xrgb32, 16, 2));
    try t.expectEqualSlices(u8, &.{ 3, 2 }, part.bytes);
    try t.expectEqual(@as(u64, 20), part.header.total_bytes);
    try t.expectEqual(@as(u32, 0), part.header.flags);
    try s.legacyWrite("later");
    const old_read = try s.read(sdk.clipboard_offer.transfer(old, 0, a.clipboard_offer_format_text_bytes, 0, 30));
    try t.expectEqualStrings("before", old_read.bytes);
    const repeated = try s.commit(stage);
    try t.expectEqualDeep(committed, repeated);
    try t.expectEqualStrings("later", s.legacyText());
    try t.expectError(error.Closed, s.abort(stage));
    try s.release(old);
    try t.expectError(error.Closed, s.read(sdk.clipboard_offer.transfer(old, 0, 5, 0, 1)));
    try s.release(snapshot);
}
test "private stages retain exact prefix retry cancellation and revision conflict" {
    var s = try init();
    defer s.deinit();
    try s.legacyWrite("base");
    const revision = s.revision;
    const stage = try begin(&s, 4);
    var r = sdk.clipboard_offer.transfer(stage, 0, 1, 0, 4);
    try s.declare(r);
    try s.declare(r);
    try s.put(r, "ab");
    try s.put(r, "ab");
    try t.expectError(error.Invalid, s.put(r, "ax"));
    r.offset = 3;
    try t.expectError(error.Invalid, s.put(r, "d"));
    try t.expectError(error.Incomplete, s.commit(stage));
    try t.expectEqual(revision, s.revision);
    r.offset = 2;
    try s.put(r, "cd");
    try s.legacyWrite("other");
    try t.expectError(error.StaleRevision, s.commit(stage));
    try s.abort(stage);
    try t.expectError(error.Closed, s.status(stage));
    try t.expectEqualStrings("other", s.legacyText());
    const cancel = try begin(&s, 0);
    try s.abort(cancel);
    try t.expectEqualStrings("other", s.legacyText());
}
test "offer item byte stage snapshot budgets and provider epochs are bounded" {
    var s = try init();
    defer s.deinit();
    try t.expectError(error.TooLarge, begin(&s, a.clipboard_offer_max_offer_bytes + 1));
    const first = try begin(&s, 1);
    try t.expectError(error.TooLarge, s.declare(sdk.clipboard_offer.transfer(first, 8, 1, 0, 1)));
    try t.expectError(error.Unsupported, s.declare(sdk.clipboard_offer.transfer(first, 0, 99, 0, 1)));
    try t.expectError(error.TooLarge, s.declare(sdk.clipboard_offer.transfer(first, 0, 1, 0, 2)));
    for (0..16) |i| try s.declare(sdk.clipboard_offer.transfer(first, @intCast(i / 5), @intCast(i % 5 + 1), 0, 0));
    try t.expectError(error.TooLarge, s.declare(sdk.clipboard_offer.transfer(first, 7, 5, 0, 0)));
    for (0..3) |_| _ = try begin(&s, 0);
    try t.expectError(error.Capacity, begin(&s, 0));
    var snapshots: [16]a.ClipboardOfferLease = undefined;
    for (&snapshots) |*snap| snap.* = try s.acquire();
    try t.expectError(error.Capacity, s.acquire());
    var next = o.Store.init(t.allocator, 18);
    defer next.deinit();
    try t.expectError(error.ProviderChanged, next.status(first));
    try t.expectError(error.ProviderChanged, next.release(snapshots[0]));
    try s.advance(.{ .identity = .{ .source = 1, .generation = 1, .tick_hz = 100 }, .instant_ns = 100 + a.clipboard_offer_lease_ns });
    try t.expectError(error.Closed, s.status(first));
    try t.expectError(error.Closed, s.release(snapshots[0]));
    const later = try begin(&s, 0);
    try t.expect(later.id > snapshots[15].id);
}
test "standard representations validate copied payloads before publication" {
    var s = try init();
    defer s.deinit();
    try s.legacyWrite("intact");
    for ([_]struct { format: u32, bytes: []const u8 }{
        .{ .format = 1, .bytes = "\xc0\x80" },                                  .{ .format = 1, .bytes = "a\x00b" },
        .{ .format = 2, .bytes = "PNG" },                                       .{ .format = 3, .bytes = &.{ 1, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .format = 4, .bytes = &.{ 1, 0, 0, 0, 3, 0, 0, 0, '/', 'x', 'x' } },
    }) |bad| {
        const stage = try begin(&s, bad.bytes.len);
        try copy(&s, stage, 0, bad.format, bad.bytes);
        try t.expectError(error.InvalidEncoding, s.commit(stage));
        try t.expectEqualStrings("intact", s.legacyText());
        try s.abort(stage);
    }
    const files = "\x01\x00\x00\x00\x08\x00\x00\x00C:\\a.txt";
    const stage = try begin(&s, files.len);
    try copy(&s, stage, 0, 4, files);
    _ = try s.commit(stage);
    try t.expectEqualStrings("", s.legacyText());
    const snapshot = try s.acquire();
    const empty = try s.read(sdk.clipboard_offer.transfer(snapshot, 0, 4, files.len, 0));
    try t.expectEqual(@as(u32, 1), empty.header.flags);
}
test "legacy byte semantics and long UTF8 fallback remain explicit" {
    var s = try init();
    defer s.deinit();
    try s.legacyWrite("\x82\xff");
    try t.expectEqualStrings("\x82\xff", s.legacyText());
    const snapshot = try s.acquire();
    var formats: [16]a.ClipboardOfferFormat = undefined;
    const page = try s.enumerate(.{ .provider = 17, .id = snapshot.id }, &formats);
    try t.expectEqual(@as(u32, 1), page.count);
    try t.expectEqual(@as(u32, 5), formats[0].format);
    try t.expectError(error.Invalid, s.legacyWrite("a\x00"));
    try t.expectEqualStrings("\x82\xff", s.legacyText());
    const long: [5000]u8 = .{'x'} ** 5000;
    const stage = try begin(&s, long.len);
    try copy(&s, stage, 0, 1, &long);
    _ = try s.commit(stage);
    try t.expectEqualStrings("", s.legacyText());
    s.legacy_revision = std.math.maxInt(u32);
    try s.legacyClear();
    try t.expectEqual(@as(u32, 1), s.legacy_revision);
}
test "clock replacement regression and exhausted counters invalidate only leases" {
    var s = try init();
    defer s.deinit();
    try s.legacyWrite("kept");
    const first = try begin(&s, 0);
    const snapshot = try s.acquire();
    try s.advance(.{ .identity = .{ .source = 1, .generation = 2, .tick_hz = 100 }, .instant_ns = 101 });
    try t.expectError(error.Closed, s.status(first));
    try t.expectError(error.Closed, s.release(snapshot));
    try t.expectEqualStrings("kept", s.legacyText());
    const next = try begin(&s, 0);
    try s.advance(.{ .identity = .{ .source = 1, .generation = 2, .tick_hz = 100 }, .instant_ns = 100 });
    try t.expectError(error.Closed, s.status(next));
    s.next_id = std.math.maxInt(u64);
    try t.expectError(error.Capacity, s.acquire());
    s.revision = std.math.maxInt(u64);
    try t.expectError(error.Capacity, s.legacyClear());
    try t.expectEqualStrings("kept", s.legacyText());
}
test "failed allocations retain current offer and cleanup all actual owner bytes" {
    for (0..6) |failure| {
        var allocator = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = failure });
        var s = o.Store.init(allocator.allocator(), 17);
        defer s.deinit();
        s.legacyWrite("abc") catch |err| {
            try t.expectEqual(error.Capacity, err);
            try t.expectEqualStrings("", s.legacyText());
            continue;
        };
        try t.expectEqualStrings("abc", s.legacyText());
        s.legacyWrite("next") catch |err| {
            try t.expectEqual(error.Capacity, err);
            try t.expectEqualStrings("abc", s.legacyText());
        };
    }
}
test "global copied budget releases real pins and reserves old text capacity" {
    var s = try init();
    defer s.deinit();
    const bytes = try t.allocator.alloc(u8, a.clipboard_offer_max_offer_bytes);
    defer t.allocator.free(bytes);
    @memset(bytes, 'q');
    var first: a.ClipboardOfferLease = undefined;
    for (0..8) |i| {
        const stage = try begin(&s, bytes.len);
        try copy(&s, stage, 0, 1, bytes);
        const receipt = try s.commit(stage);
        const snapshot = try s.acquire();
        if (i == 0) first = snapshot;
        try s.release(receipt);
    }
    try t.expectEqual(a.clipboard_offer_payload_budget, s.used);
    const stage = try begin(&s, 1);
    try t.expectError(error.Capacity, s.declare(sdk.clipboard_offer.transfer(stage, 0, 1, 0, 1)));
    try s.legacyWrite("legacy reserve");
    try t.expectEqualStrings("legacy reserve", s.legacyText());
    try s.release(first);
    try s.declare(sdk.clipboard_offer.transfer(stage, 0, 1, 0, 1));
    try s.abort(stage);
}
