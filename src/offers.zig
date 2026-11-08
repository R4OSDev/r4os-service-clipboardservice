//! The single CLIPSVC loop owns copied immutable offers and all leases.
//! No callbacks, caller pointers, worker registry or kernel format conversion.
const std = @import("std");
const sdk = @import("r4os");
const a = sdk.abi;
const clock = sdk.time_contract.checked;
pub const Error = error{ Invalid, TooLarge, Capacity, StaleRevision, ProviderChanged, Closed, Unsupported, InvalidEncoding, Incomplete, NotFound };
pub fn code(err: Error) i32 {
    return switch (err) {
        error.Invalid => a.clipboard_offer_error_invalid,
        error.TooLarge => a.clipboard_offer_error_too_large,
        error.Capacity => a.clipboard_offer_error_capacity,
        error.StaleRevision => a.clipboard_offer_error_stale_revision,
        error.ProviderChanged => a.clipboard_offer_error_provider_changed,
        error.Closed => a.clipboard_offer_error_closed,
        error.Unsupported => a.clipboard_offer_error_unsupported,
        error.InvalidEncoding => a.clipboard_offer_error_invalid_encoding,
        error.Incomplete => a.clipboard_offer_error_incomplete,
        error.NotFound => a.clipboard_offer_error_not_found,
    };
}
const Data = struct { format: a.ClipboardOfferFormat, bytes: []u8, written: usize = 0 };
const Offer = struct {
    refs: usize = 1,
    count: usize = 0,
    data: [a.clipboard_offer_max_formats]Data = undefined,
    text_index: ?usize = null,
};
const Stage = struct { lease: a.ClipboardOfferLease = .{}, limit: u64 = 0, bytes: u64 = 0, offer: ?*Offer = null };
const Snapshot = struct { lease: a.ClipboardOfferLease = .{}, offer: ?*Offer = null };
pub const Read = struct { header: a.ClipboardOfferChunk, bytes: []const u8 };
pub const Store = struct {
    allocator: std.mem.Allocator,
    provider: u64,
    revision: u64 = 0,
    legacy_revision: u32 = 0,
    used: u64 = 0,
    next_id: u64 = 1,
    current: ?*Offer = null,
    stages: [a.clipboard_offer_max_stages]Stage = .{Stage{}} ** a.clipboard_offer_max_stages,
    snapshots: [a.clipboard_offer_max_snapshots]Snapshot = .{Snapshot{}} ** a.clipboard_offer_max_snapshots,
    sample: ?clock.ClockSample = null,

    pub fn init(allocator: std.mem.Allocator, provider: u64) Store {
        std.debug.assert(provider != 0);
        return .{ .allocator = allocator, .provider = provider };
    }
    pub fn deinit(self: *Store) void {
        self.invalidateLeases();
        self.drop(self.current);
        self.current = null;
        std.debug.assert(self.used == 0);
    }
    fn drop(self: *Store, value: ?*Offer) void {
        const offer = value orelse return;
        offer.refs -= 1;
        if (offer.refs != 0) return;
        for (offer.data[0..offer.count]) |d| {
            self.used -= d.bytes.len;
            self.allocator.free(d.bytes);
        }
        self.allocator.destroy(offer);
    }
    pub fn invalidateLeases(self: *Store) void {
        for (&self.stages) |*s| {
            self.drop(s.offer);
            s.* = .{};
        }
        for (&self.snapshots) |*s| {
            self.drop(s.offer);
            s.* = .{};
        }
        self.sample = null;
    }
    pub fn advance(self: *Store, sample: clock.ClockSample) Error!void {
        sample.validate() catch {
            self.invalidateLeases();
            return error.Unsupported;
        };
        if (self.sample) |previous| {
            if (!std.meta.eql(previous.identity, sample.identity) or sample.instant_ns < previous.instant_ns)
                self.invalidateLeases();
        }
        self.sample = sample;
        for (&self.stages) |*s| if (s.lease.id != 0 and sample.instant_ns >= s.lease.expires_ns) {
            self.drop(s.offer);
            s.* = .{};
        };
        for (&self.snapshots) |*s| if (s.lease.id != 0 and sample.instant_ns >= s.lease.expires_ns) {
            self.drop(s.offer);
            s.* = .{};
        };
    }
    fn lease(self: *Store, state: u32) Error!a.ClipboardOfferLease {
        const now = self.sample orelse return error.Unsupported;
        const expires = std.math.add(u64, now.instant_ns, a.clipboard_offer_lease_ns) catch return error.Capacity;
        if (self.next_id == std.math.maxInt(u64)) return error.Capacity;
        const id = self.next_id;
        self.next_id += 1;
        return .{ .provider = self.provider, .id = id, .revision = self.revision, .expires_ns = expires, .state = state };
    }
    fn check(self: *const Store, provider: u64) Error!void {
        if (provider != self.provider) return error.ProviderChanged;
    }
    fn stage(self: *Store, token: a.ClipboardOfferLease) Error!*Stage {
        try self.check(token.provider);
        for (&self.stages) |*s| if (token.id != 0 and s.lease.id == token.id) return s;
        return error.Closed;
    }
    fn snapshot(self: *Store, provider: u64, id: u64) Error!*Snapshot {
        try self.check(provider);
        for (&self.snapshots) |*s| if (id != 0 and s.lease.id == id) return s;
        return error.Closed;
    }
    pub fn info(self: *const Store) a.ClipboardOfferInfo {
        return .{ .provider = self.provider, .revision = self.revision };
    }
    pub fn begin(self: *Store, request: a.ClipboardOfferBegin) Error!a.ClipboardOfferLease {
        try self.check(request.provider);
        if (request.expected_revision != self.revision) return error.StaleRevision;
        if (request.total_bytes > a.clipboard_offer_max_offer_bytes) return error.TooLarge;
        for (&self.stages) |*s| if (s.lease.id == 0) {
            const token = try self.lease(a.clipboard_offer_state_writing);
            const offer = self.allocator.create(Offer) catch return error.Capacity;
            offer.* = .{};
            s.* = .{ .lease = token, .limit = request.total_bytes, .offer = offer };
            return token;
        };
        return error.Capacity;
    }
    pub fn declare(self: *Store, request: a.ClipboardOfferTransfer) Error!void {
        const s = try self.stage(.{ .provider = request.provider, .id = request.id });
        const offer = s.offer orelse return error.Closed;
        if (request.offset != 0) return error.Invalid;
        if (request.item >= a.clipboard_offer_max_items) return error.TooLarge;
        if (request.format < a.clipboard_offer_format_text_utf8 or request.format > a.clipboard_offer_format_text_bytes) return error.Unsupported;
        for (offer.data[0..offer.count]) |d| if (d.format.item == request.item and d.format.format == request.format) {
            if (d.format.total_bytes == request.total_bytes) return;
            return error.Invalid;
        };
        if (offer.count == offer.data.len or request.total_bytes > s.limit - s.bytes) return error.TooLarge;
        if (request.format == a.clipboard_offer_format_text_bytes and request.total_bytes > a.clipboard_max_text_bytes) return error.TooLarge;
        if (self.used + request.total_bytes > a.clipboard_offer_payload_budget) return error.Capacity;
        const data = self.allocator.alloc(u8, @intCast(request.total_bytes)) catch return error.Capacity;
        offer.data[offer.count] = .{ .format = .{ .item = request.item, .format = request.format, .total_bytes = request.total_bytes }, .bytes = data };
        offer.count += 1;
        self.used += request.total_bytes;
        s.bytes += request.total_bytes;
    }
    fn find(offer: *Offer, item: u32, format: u32) Error!*Data {
        for (offer.data[0..offer.count]) |*d| if (d.format.item == item and d.format.format == format) return d;
        return error.NotFound;
    }
    pub fn put(self: *Store, request: a.ClipboardOfferTransfer, bytes: []const u8) Error!void {
        if (bytes.len > a.clipboard_offer_put_chunk) return error.TooLarge;
        const s = try self.stage(.{ .provider = request.provider, .id = request.id });
        const offer = s.offer orelse return error.Closed;
        const d = try find(offer, request.item, request.format);
        if (request.total_bytes != d.bytes.len or request.offset > d.written) return error.Invalid;
        const offset: usize = @intCast(request.offset);
        if (bytes.len > d.bytes.len - offset) return error.TooLarge;
        if (offset < d.written) {
            if (bytes.len <= d.written - offset and std.mem.eql(u8, d.bytes[offset..][0..bytes.len], bytes)) return;
            return error.Invalid;
        }
        @memcpy(d.bytes[offset..][0..bytes.len], bytes);
        d.written += bytes.len;
    }
    fn bump(self: *Store) Error!void {
        if (self.revision == std.math.maxInt(u64)) return error.Capacity;
        self.revision += 1;
        self.legacy_revision +%= 1;
        if (self.legacy_revision == 0) self.legacy_revision = 1;
    }
    fn publish(self: *Store, offer: ?*Offer) Error!void {
        try self.bump();
        const previous = self.current;
        self.current = offer;
        self.drop(previous);
    }
    pub fn commit(self: *Store, token: a.ClipboardOfferLease) Error!a.ClipboardOfferLease {
        const s = try self.stage(token);
        if (s.lease.state == a.clipboard_offer_state_committed) return s.lease;
        const offer = s.offer orelse return error.Closed;
        if (s.lease.revision != self.revision) return error.StaleRevision;
        for (offer.data[0..offer.count]) |d| {
            if (d.written != d.bytes.len) return error.Incomplete;
            try validate(d.format.format, d.bytes);
        }
        chooseText(offer);
        try self.publish(offer);
        s.offer = null;
        s.lease.revision = self.revision;
        s.lease.state = a.clipboard_offer_state_committed;
        return s.lease;
    }
    pub fn status(self: *Store, token: a.ClipboardOfferLease) Error!a.ClipboardOfferLease {
        return (try self.stage(token)).lease;
    }
    pub fn abort(self: *Store, token: a.ClipboardOfferLease) Error!void {
        const s = try self.stage(token);
        if (s.lease.state != a.clipboard_offer_state_writing) return error.Closed;
        self.drop(s.offer);
        s.* = .{};
    }
    pub fn acquire(self: *Store) Error!a.ClipboardOfferLease {
        for (&self.snapshots) |*s| if (s.lease.id == 0) {
            const token = try self.lease(a.clipboard_offer_state_snapshot);
            if (self.current) |o| o.refs += 1;
            s.* = .{ .lease = token, .offer = self.current };
            return token;
        };
        return error.Capacity;
    }
    pub fn release(self: *Store, token: a.ClipboardOfferLease) Error!void {
        try self.check(token.provider);
        for (&self.snapshots) |*s| if (token.id != 0 and s.lease.id == token.id) {
            self.drop(s.offer);
            s.* = .{};
            return;
        };
        for (&self.stages) |*s| if (token.id != 0 and s.lease.id == token.id and s.lease.state == a.clipboard_offer_state_committed) {
            s.* = .{};
            return;
        };
        return error.Closed;
    }
    pub fn enumerate(self: *Store, request: a.ClipboardOfferEnumerate, out: []a.ClipboardOfferFormat) Error!a.ClipboardOfferPage {
        const s = try self.snapshot(request.provider, request.id);
        const count: usize = if (s.offer) |o| o.count else 0;
        if (request.capacity == 0 or request.capacity > a.clipboard_offer_max_formats or out.len < request.capacity or request.cursor > count) return error.Invalid;
        const n = @min(request.capacity, count - request.cursor);
        if (s.offer) |o| for (0..n) |i| {
            out[i] = o.data[request.cursor + i].format;
        };
        return .{ .provider = self.provider, .id = request.id, .revision = s.lease.revision, .next = @intCast(request.cursor + n), .count = @intCast(n), .total = @intCast(count) };
    }
    pub fn read(self: *Store, request: a.ClipboardOfferTransfer) Error!Read {
        const s = try self.snapshot(request.provider, request.id);
        const offer = s.offer orelse return error.NotFound;
        const d = try find(offer, request.item, request.format);
        if (request.offset > d.bytes.len or request.total_bytes > a.clipboard_offer_read_chunk) return error.Invalid;
        const n: usize = @intCast(@min(request.total_bytes, d.bytes.len - request.offset));
        const offset: usize = @intCast(request.offset);
        return .{ .header = .{ .provider = self.provider, .id = request.id, .revision = s.lease.revision, .offset = request.offset, .total_bytes = d.bytes.len, .bytes = @intCast(n), .flags = if (offset + n == d.bytes.len) a.clipboard_offer_flag_eof else 0 }, .bytes = d.bytes[offset..][0..n] };
    }
    pub fn legacyText(self: *const Store) []const u8 {
        const offer = self.current orelse return "";
        return if (offer.text_index) |i| offer.data[i].bytes else "";
    }
    pub fn legacyWrite(self: *Store, bytes: []const u8) Error!void {
        if (bytes.len > a.clipboard_max_text_bytes) return error.TooLarge;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.Invalid;
        const offer = self.allocator.create(Offer) catch return error.Capacity;
        offer.* = .{};
        errdefer self.drop(offer);
        const formats: usize = if (std.unicode.utf8ValidateSlice(bytes)) 2 else 1;
        // Typed stages cannot consume the small reserve for an old text write.
        // At most16 snapshots plus4 stages/current can retain old text copies.
        const reserve: u64 = 256 * 1024;
        if (self.used + bytes.len * formats > a.clipboard_offer_payload_budget + reserve) return error.Capacity;
        for (0..formats) |i| {
            const copy = self.allocator.dupe(u8, bytes) catch return error.Capacity;
            offer.data[i] = .{ .format = .{ .item = 0, .format = if (i == 0) a.clipboard_offer_format_text_bytes else a.clipboard_offer_format_text_utf8, .total_bytes = bytes.len }, .bytes = copy, .written = bytes.len };
            offer.count += 1;
            self.used += bytes.len;
        }
        chooseText(offer);
        try self.publish(offer);
    }
    pub fn legacyClear(self: *Store) Error!void {
        try self.publish(null);
    }
};
fn chooseText(offer: *Offer) void {
    var best: u32 = std.math.maxInt(u32);
    for (offer.data[0..offer.count], 0..) |d, i| {
        if (d.format.format != a.clipboard_offer_format_text_utf8 and d.format.format != a.clipboard_offer_format_text_bytes or d.bytes.len > a.clipboard_max_text_bytes) continue;
        const rank = d.format.item * 2 + @intFromBool(d.format.format == a.clipboard_offer_format_text_bytes);
        if (rank < best) {
            best = rank;
            offer.text_index = i;
        }
    }
}
fn le32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn text(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, 0) == null;
}
fn validate(format: u32, bytes: []const u8) Error!void {
    switch (format) {
        a.clipboard_offer_format_text_utf8 => if (!text(bytes)) return error.InvalidEncoding,
        a.clipboard_offer_format_text_bytes => if (bytes.len > a.clipboard_max_text_bytes or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidEncoding,
        a.clipboard_offer_format_png => {
            if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or std.mem.readInt(u32, bytes[8..12], .big) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidEncoding;
            const width = std.mem.readInt(u32, bytes[16..20], .big);
            const height = std.mem.readInt(u32, bytes[20..24], .big);
            if (width == 0 or height == 0 or width > 4096 or height > 4096 or bytes[24] != 8 or (bytes[25] != 0 and bytes[25] != 2 and bytes[25] != 3 and bytes[25] != 4 and bytes[25] != 6) or bytes[26] != 0 or bytes[27] != 0 or bytes[28] > 1) return error.InvalidEncoding;
        },
        a.clipboard_offer_format_xrgb32 => {
            if (bytes.len < 16) return error.InvalidEncoding;
            const width = le32(bytes);
            const height = le32(bytes[4..]);
            const stride = le32(bytes[8..]);
            if (width == 0 or height == 0 or width > 4096 or height > 4096 or stride != width * 4 or le32(bytes[12..]) != 0 or @as(u64, height) * stride + 16 != bytes.len) return error.InvalidEncoding;
        },
        a.clipboard_offer_format_file_list => {
            if (bytes.len < 4) return error.InvalidEncoding;
            const count = le32(bytes);
            if (count == 0 or count > 128) return error.InvalidEncoding;
            var offset: usize = 4;
            for (0..count) |_| {
                if (bytes.len - offset < 4) return error.InvalidEncoding;
                const n = le32(bytes[offset..]);
                offset += 4;
                if (n < 3 or n > 1023 or n > bytes.len - offset) return error.InvalidEncoding;
                const path = bytes[offset..][0..n];
                if (!text(path) or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\' or std.mem.indexOfScalar(u8, path, '\r') != null or std.mem.indexOfScalar(u8, path, '\n') != null) return error.InvalidEncoding;
                offset += n;
            }
            if (offset != bytes.len) return error.InvalidEncoding;
        },
        else => return error.Unsupported,
    }
}
