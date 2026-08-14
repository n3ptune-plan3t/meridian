const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @cImport({
    @cInclude("wayland-client.h");
});

const log = std.log.scoped(.shm);

const PAGE_SIZE = std.mem.page_size;
const STRIDE_ALIGNMENT = 256;

pub const ShmPool = struct {
    fd: i32,
    data: []align(PAGE_SIZE) u8,
    pool: ?*c.wl_shm_pool,
    buffers: [3]Buffer,
    current_buffer: u2,
    width: u32,
    height: u32,
    stride: u32,
    pool_size: u32,

    const Buffer = struct {
        wl_buffer: ?*c.wl_buffer,
        busy: bool,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !ShmPool {
        _ = allocator;

        const stride = alignStride(width * 4);
        const buffer_size = stride * height;
        const pool_size = buffer_size * 3;

        const fd = posix.memfd_create("meridian-shm", 0) catch |err| {
            log.err("failed to create memfd: {}", .{err});
            return error.MemfdCreateFailed;
        };
        errdefer posix.close(fd);

        posix.ftruncate(fd, @intCast(pool_size)) catch |err| {
            log.err("failed to truncate memfd: {}", .{err});
            return error.FtruncateFailed;
        };

        const mmap_data = posix.mmap(
            null,
            @intCast(pool_size),
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.err("failed to mmap: {}", .{err});
            return error.MmapFailed;
        };

        return .{
            .fd = fd,
            .data = @alignCast(mmap_data),
            .pool = null,
            .buffers = [_]Buffer{.{ .wl_buffer = null, .busy = false }} ** 3,
            .current_buffer = 0,
            .width = width,
            .height = height,
            .stride = stride,
            .pool_size = pool_size,
        };
    }

    fn alignStride(size: u32) u32 {
        const remainder = size % STRIDE_ALIGNMENT;
        if (remainder == 0) return size;
        return size + (STRIDE_ALIGNMENT - remainder);
    }

    pub fn createWlPool(self: *ShmPool, shm: ?*c.wl_shm) !*c.wl_shm_pool {
        const pool = c.wl_shm_create_pool(shm, self.fd, @intCast(self.pool_size)) orelse {
            log.err("failed to create wayland shm pool", .{});
            return error.CreatePoolFailed;
        };
        self.pool = pool;
        return pool;
    }

    pub fn acquireBuffer(self: *ShmPool) ?*Buffer {
        for (&self.buffers) |*buf| {
            if (!buf.busy) {
                buf.busy = true;
                return buf;
            }
        }
        return null;
    }

    pub fn releaseBuffer(self: *ShmPool, wl_buffer: *c.wl_buffer) void {
        for (&self.buffers) |*buf| {
            if (buf.wl_buffer == wl_buffer) {
                buf.busy = false;
                break;
            }
        }
    }

    pub fn getBufferOffset(self: *ShmPool, index: u2) u32 {
        return @as(u32, @intCast(index)) * self.stride * self.height;
    }

    pub fn getCanvas(self: *ShmPool) []u32 {
        const offset = self.getBufferOffset(self.current_buffer);
        const start = offset;
        const end = offset + self.stride * self.height;
        const bytes = self.data[start..end];
        return std.mem.bytesAsSlice(u32, bytes);
    }

    pub fn swapBuffers(self: *ShmPool) void {
        self.current_buffer = @intCast((@as(u2, self.current_buffer) + 1) % 3);
    }

    pub fn getCurrentWlBuffer(self: *ShmPool) ?*c.wl_buffer {
        return self.buffers[self.current_buffer].wl_buffer;
    }

    pub fn resize(self: *ShmPool, width: u32, height: u32) !void {
        const stride = alignStride(width * 4);
        const new_buffer_size = stride * height;
        const new_pool_size = new_buffer_size * 3;

        if (new_pool_size <= self.pool_size) {
            self.width = width;
            self.height = height;
            self.stride = stride;
            return;
        }

        posix.munmap(self.data);
        posix.close(self.fd);

        const fd = posix.memfd_create("meridian-shm", 0) catch |err| {
            log.err("failed to create memfd: {}", .{err});
            return error.MemfdCreateFailed;
        };
        errdefer posix.close(fd);

        posix.ftruncate(fd, @intCast(new_pool_size)) catch |err| {
            log.err("failed to truncate memfd: {}", .{err});
            return error.FtruncateFailed;
        };

        const mmap_data = posix.mmap(
            null,
            @intCast(new_pool_size),
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.err("failed to mmap: {}", .{err});
            return error.MmapFailed;
        };

        self.fd = fd;
        self.data = @alignCast(mmap_data);
        self.width = width;
        self.height = height;
        self.stride = stride;
        self.pool_size = new_pool_size;
    }

    pub fn deinit(self: *ShmPool) void {
        for (&self.buffers) |*buf| {
            if (buf.wl_buffer) |wl_buf| {
                c.wl_buffer_destroy(wl_buf);
            }
        }
        if (self.pool) |pool| {
            c.wl_shm_pool_destroy(pool);
        }
        posix.munmap(self.data);
        posix.close(self.fd);
    }
};
