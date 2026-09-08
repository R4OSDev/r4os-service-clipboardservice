const r4os = @import("r4os");

const service_name = "CLIPSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";

const clipboard_buffer_size: usize = @as(usize, r4os.clipboard.max_text_bytes) + 1;
const info_payload_size: usize = 16;

const ClipboardState = struct {
    text: [clipboard_buffer_size]u8 = .{0} ** clipboard_buffer_size,
    len: usize = 0,
    revision: u32 = 0,
    requests: u32 = 0,
    writes: u32 = 0,
    reads: u32 = 0,
    infos: u32 = 0,
    clears: u32 = 0,
    bad_ops: u32 = 0,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = r4_app.system();
    if (hasArg(ctx.argsRaw(), selftest_arg)) return runSelfTest(&ctx);
    if (hasArg(ctx.argsRaw(), ping_arg)) return runPing(&ctx);
    return runService(&ctx);
}

fn runService(ctx: *const r4os.r4sys.Context) i32 {
    if (!ctx.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < 100 and handle == 0) : (waited += 1) {
        const rc = ctx.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            ctx.write("CLIPSVC endpoint handle=");
            ctx.printU64(@intCast(handle));
            ctx.println("");
            break;
        }
        ctx.sleepTicks(1);
    }
    if (handle == 0) {
        ctx.println("CLIPSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state: ClipboardState = .{};
    var service_loop = r4os.ServiceLoop.init(ctx.*, handle, .{});
    while (true) {
        switch (service_loop.wait(null)) {
            .requests => |pending| {
                const rc = service_loop.drain(pending, handleRequest, .{ ctx, handle, &state });
                if (rc >= 0) continue;
                _ = ctx.serviceEndpointUnregister(handle);
                return rc;
            },
            .idle, .deadline => {},
            .stop => break,
            .failure => |raw| {
                _ = ctx.serviceEndpointUnregister(handle);
                return raw;
            },
        }
    }

    service_loop.report(service_name);
    _ = ctx.serviceEndpointUnregister(handle);
    ctx.println("CLIPSVC stopped cleanly");
    return 0;
}

fn handleRequest(ctx: *const r4os.r4sys.Context, handle: u32, state: *ClipboardState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const got = ctx.serviceEndpointRecv(handle, &header, payload[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    const payload_len: usize = @intCast(got);
    return switch (header.op) {
        r4os.abi.clipboard_service_op_write => handleWrite(ctx, handle, header.request_id, state, payload[0..payload_len]),
        r4os.abi.clipboard_service_op_read => handleRead(ctx, handle, header.request_id, state),
        r4os.abi.clipboard_service_op_info => handleInfo(ctx, handle, header.request_id, state),
        r4os.abi.clipboard_service_op_clear => handleClear(ctx, handle, header.request_id, state),
        r4os.abi.clipboard_service_op_revision => handleRevision(ctx, handle, header.request_id, state),
        else => {
            state.bad_ops +%= 1;
            return r4os.app_services.replyIfPending(ctx.*, handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
}

fn handleWrite(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ClipboardState, payload: []const u8) i32 {
    if (payload.len > @as(usize, r4os.clipboard.max_text_bytes)) {
        return r4os.app_services.replyIfPending(ctx.*, handle, request_id, r4os.abi.clipboard_error_too_large, "");
    }
    var i: usize = 0;
    while (i < payload.len) : (i += 1) {
        if (payload[i] == 0) return r4os.app_services.replyIfPending(ctx.*, handle, request_id, r4os.abi.clipboard_error_invalid, "");
    }
    if (payload.len > 0) @memcpy(state.text[0..payload.len], payload);
    state.text[payload.len] = 0;
    if (payload.len + 1 < state.text.len) @memset(state.text[payload.len + 1 ..], 0);
    state.len = payload.len;
    bumpRevision(state);
    state.writes +%= 1;
    return r4os.app_services.replyIfPending(ctx.*, handle, request_id, @intCast(payload.len), "");
}

fn handleRead(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ClipboardState) i32 {
    state.reads +%= 1;
    return r4os.app_services.replyIfPending(ctx.*, handle, request_id, @intCast(state.len), state.text[0..state.len]);
}

fn handleInfo(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ClipboardState) i32 {
    state.infos +%= 1;
    var payload: [info_payload_size]u8 = .{0} ** info_payload_size;
    writeInfoPayload(payload[0..], state);
    return r4os.app_services.replyIfPending(ctx.*, handle, request_id, r4os.abi.service_api_result_ok, payload[0..]);
}

fn handleClear(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ClipboardState) i32 {
    clearState(state);
    bumpRevision(state);
    state.clears +%= 1;
    return r4os.app_services.replyIfPending(ctx.*, handle, request_id, r4os.abi.service_api_result_ok, "");
}

fn handleRevision(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *ClipboardState) i32 {
    var payload: [4]u8 = .{0} ** 4;
    writeLe32(payload[0..], state.revision);
    return r4os.app_services.replyIfPending(ctx.*, handle, request_id, r4os.abi.service_api_result_ok, payload[0..]);
}

fn runPing(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("CLIPSVC ping");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(ctx, &handle)) {
        ctx.println("CLIPSVC ping failed");
        return 1;
    }
    var info = r4os.abi.ClipboardInfo{};
    const ok = callInfo(ctx, handle, &info);
    _ = ctx.serviceClose(handle);
    if (!ok or info.capacity != r4os.clipboard.max_text_bytes) {
        ctx.println("CLIPSVC ping failed");
        return 1;
    }
    ctx.println("CLIPSVC ping: OK");
    return 0;
}

fn runSelfTest(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("CLIPSVC selftest");
    if (!ctx.hasFn("service_start")) return fail(ctx, "manager-api");
    if (!ctx.hasFn("service_call")) return fail(ctx, "service-api");

    var handle: u32 = 0;
    if (!ensureRunningAndOpen(ctx, &handle)) return fail(ctx, "open");
    defer _ = ctx.serviceClose(handle);

    if (callClear(ctx, handle) != r4os.abi.service_api_result_ok) return fail(ctx, "clear");
    var info = r4os.abi.ClipboardInfo{};
    if (!callInfo(ctx, handle, &info)) return fail(ctx, "info");
    if (info.capacity != r4os.clipboard.max_text_bytes or info.length != 0) return fail(ctx, "clear-info");
    const clear_revision = info.revision;

    const sample = "CLIPSVC text\r\nline";
    if (callWrite(ctx, handle, sample) != @as(i32, @intCast(sample.len))) return fail(ctx, "write");
    if (!callInfo(ctx, handle, &info)) return fail(ctx, "info-after-write");
    if (info.length != @as(u32, @intCast(sample.len)) or info.revision == clear_revision or (info.flags & r4os.abi.clipboard_flag_has_text) == 0) return fail(ctx, "bad-info-after-write");

    var read_buf: [64]u8 = .{0} ** 64;
    const read_len = callRead(ctx, handle, read_buf[0..]);
    if (read_len != @as(i32, @intCast(sample.len)) or !bytesEq(read_buf[0..sample.len], sample)) return fail(ctx, "read");

    var small: [4]u8 = .{0} ** 4;
    if (callRead(ctx, handle, small[0..]) != r4os.abi.service_api_result_buffer_too_small) return fail(ctx, "small-buffer");

    const with_zero = [_]u8{ 'A', 0, 'B' };
    if (callWrite(ctx, handle, with_zero[0..]) != r4os.abi.clipboard_error_invalid) return fail(ctx, "nul");

    const too_large: [clipboard_buffer_size]u8 = .{'X'} ** clipboard_buffer_size;
    if (callWrite(ctx, handle, too_large[0..]) != r4os.abi.clipboard_error_too_large) return fail(ctx, "too-large");

    var response_header: r4os.abi.ServiceMessageHeader = .{};
    var response: [8]u8 = .{0} ** 8;
    const bad_op = ctx.serviceCall(handle, 999, "", &response_header, response[0..], 120);
    if (bad_op < 0 or response_header.status != r4os.abi.service_api_result_bad_op) return fail(ctx, "bad-op");

    if (callClear(ctx, handle) != r4os.abi.service_api_result_ok) return fail(ctx, "final-clear");
    if (!callInfo(ctx, handle, &info) or info.length != 0) return fail(ctx, "final-info");

    ctx.println("CLIPSVC selftest: OK");
    return 0;
}

fn ensureRunningAndOpen(ctx: *const r4os.r4sys.Context, out_handle: *u32) bool {
    var info: r4os.abi.ServiceInfo = .{};
    const status = ctx.serviceStatus(service_name, &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = ctx.serviceStart(service_name, &info);
        if (start != r4os.abi.service_api_result_ok) return false;
    }
    return waitOpen(ctx, out_handle, 160);
}

fn waitOpen(ctx: *const r4os.r4sys.Context, out_handle: *u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var info: r4os.abi.ServiceInfo = .{};
        const rc = ctx.serviceOpen(service_name, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            out_handle.* = info.handle;
            return true;
        }
        ctx.sleepTicks(1);
    }
    return false;
}

fn callWrite(ctx: *const r4os.r4sys.Context, handle: u32, data: []const u8) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [1]u8 = .{0};
    const got = ctx.serviceCall(handle, r4os.abi.clipboard_service_op_write, data, &header, response[0..], 120);
    if (got < 0) return got;
    return header.status;
}

fn callRead(ctx: *const r4os.r4sys.Context, handle: u32, out: []u8) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = ctx.serviceCall(handle, r4os.abi.clipboard_service_op_read, "", &header, out, 120);
    if (got < 0) return got;
    if (header.status < 0) return header.status;
    return got;
}

fn callInfo(ctx: *const r4os.r4sys.Context, handle: u32, out: *r4os.abi.ClipboardInfo) bool {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [info_payload_size]u8 = .{0} ** info_payload_size;
    const got = ctx.serviceCall(handle, r4os.abi.clipboard_service_op_info, "", &header, response[0..], 120);
    if (got != @as(i32, @intCast(info_payload_size)) or header.status != r4os.abi.service_api_result_ok) return false;
    out.* = parseInfoPayload(response[0..]);
    return true;
}

fn callClear(ctx: *const r4os.r4sys.Context, handle: u32) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [1]u8 = .{0};
    const got = ctx.serviceCall(handle, r4os.abi.clipboard_service_op_clear, "", &header, response[0..], 120);
    if (got < 0) return got;
    return header.status;
}

fn writeInfoPayload(out: []u8, state: *const ClipboardState) void {
    writeLe32(out[0..4], r4os.clipboard.max_text_bytes);
    writeLe32(out[4..8], @intCast(state.len));
    writeLe32(out[8..12], state.revision);
    writeLe32(out[12..16], r4os.abi.clipboard_flag_text | (if (state.len > 0) r4os.abi.clipboard_flag_has_text else 0));
}

fn parseInfoPayload(data: []const u8) r4os.abi.ClipboardInfo {
    return .{
        .capacity = readLe32(data[0..4]),
        .length = readLe32(data[4..8]),
        .revision = readLe32(data[8..12]),
        .flags = readLe32(data[12..16]),
    };
}

fn clearState(state: *ClipboardState) void {
    @memset(state.text[0..], 0);
    state.len = 0;
}

fn bumpRevision(state: *ClipboardState) void {
    state.revision +%= 1;
    if (state.revision == 0) state.revision = 1;
}

fn fail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("CLIPSVC selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn bytesEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn writeLe32(out: []u8, value: u32) void {
    out[0] = @intCast(value & 0xFF);
    out[1] = @intCast((value >> 8) & 0xFF);
    out[2] = @intCast((value >> 16) & 0xFF);
    out[3] = @intCast((value >> 24) & 0xFF);
}

fn readLe32(data: []const u8) u32 {
    return @as(u32, data[0]) |
        (@as(u32, data[1]) << 8) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 24);
}
