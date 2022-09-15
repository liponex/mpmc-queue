const std = @import("std");

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

pub const cache_line_size: usize = 64;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/// based on https://github.com/rigtorp/MPMCQueue
pub fn MPMCQueueUnmanaged(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            data: T align(cache_line_size) = undefined,
            turn: usize = 0,

            pub fn loadTurn(slot: *const Slot) usize {
                return @atomicLoad(usize, &slot.turn, .Acquire);
            }

            pub fn storeTurn(slot: *Slot, value: usize) void {
                @atomicStore(usize, &slot.turn, value, .Release);
            }
        };

        const NoSlots: []Slot = &[0]Slot{};

        _slots: []Slot = NoSlots,

        // Aligned to avoid false sharing between _head and _tail
        _head: usize align(cache_line_size) = 0,
        _tail: usize align(cache_line_size) = 0,

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        pub fn init(allocator: std.mem.Allocator, _capacity: usize) !Self {
            // Allocate an extra slot to avoid false sharing on the last slot
            const slots = try allocator.alloc(Slot, _capacity + 1);
            std.debug.assert(@ptrToInt(slots.ptr) % cache_line_size == 0);
            std.debug.assert(@ptrToInt(slots.ptr) % @alignOf(T) == 0);

            for (slots) |*slot| {
                slot.* = .{};
            }

            var self = Self{};
            self._slots.ptr = slots.ptr;
            self._slots.len = _capacity;
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self._slots.ptr != NoSlots.ptr);
            var slots = self._slots;
            slots.len = self._slots.len + 1; // free extra slot
            allocator.free(slots);
            self.* = .{};
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        pub fn capacity(self: *const Self) usize {
            return self._slots.len;
        }

        pub fn empty(self: *const Self) bool {
            return self.size() == 0;
        }

        pub fn size(self: *const Self) usize {
            const head = self.loadHead(.Monotonic);
            const tail = self.loadTail(.Monotonic);
            return if (head > tail) head - tail else 0;
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Enqueue `value`, blocking while queue is full.
        pub fn enqueue(self: *Self, value: T) void {
            const head = self.bumpHead();
            const slot = self.nthSlot(head);
            const turn = self.nthTurn(head);
            while (turn != slot.loadTurn()) {
                // await our turn to enqueue
            }
            slot.data = value;
            slot.storeTurn(turn + 1);
        }

        /// Enqueue `value` if queue is not full,
        /// return `true` if enqueued, `false` otherwise.
        pub fn enqueueIfNotFull(self: *Self, value: T) bool {
            var head = self.loadHead(.Acquire);
            while (true) {
                const slot = self.nthSlot(head);
                const turn = self.nthTurn(head);
                if (turn == slot.loadTurn()) {
                    if (self.bumpHeadIfEql(head)) {
                        slot.data = value;
                        slot.storeTurn(turn + 1);
                        return true;
                    }
                } else {
                    const prev_head = head;
                    head = self.loadHead(.Acquire);
                    if (head == prev_head) {
                        return false;
                    }
                }
            }
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        /// Dequeue one element, blocking while queue is empty.
        pub fn dequeue(self: *Self) T {
            const tail = self.bumpTail();
            const slot = self.nthSlot(tail);
            const turn = self.nthTurn(tail) + 1;
            while (turn != slot.loadTurn()) {
                // await our turn to dequeue
            }
            const value = slot.data;
            slot.data = undefined;
            slot.storeTurn(turn + 1);
            return value;
        }

        /// Dequeue one element if queue is not empty,
        /// return value if dequeued, `null` otherwise.
        pub fn dequeueIfNotEmpty(self: *Self) ?T {
            var tail = self.loadTail(.Acquire);
            while (true) {
                const slot = self.nthSlot(tail);
                const turn = self.nthTurn(tail) + 1;
                if (turn == slot.loadTurn()) {
                    if (self.bumpTailIfEql(tail)) {
                        const result = slot.data;
                        slot.data = undefined;
                        slot.storeTurn(turn + 1);
                        return result;
                    }
                } else {
                    const prev_tail = tail;
                    tail = self.loadTail(.Acquire);
                    if (tail == prev_tail) {
                        return null;
                    }
                }
            }
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        const Order = std.builtin.AtomicOrder;

        inline fn bumpHead(self: *Self) usize {
            return @atomicRmw(usize, &self._head, .Add, 1, .Monotonic);
        }

        inline fn bumpHeadIfEql(self: *Self, n: usize) bool {
            return null == @cmpxchgStrong(usize, &self._head, n, n + 1, .Monotonic, .Monotonic);
        }

        inline fn loadHead(self: *const Self, comptime order: Order) usize {
            return @atomicLoad(usize, &self._head, order);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        inline fn bumpTail(self: *Self) usize {
            return @atomicRmw(usize, &self._tail, .Add, 1, .Monotonic);
        }

        inline fn bumpTailIfEql(self: *Self, n: usize) bool {
            return null == @cmpxchgStrong(usize, &self._tail, n, n + 1, .Monotonic, .Monotonic);
        }

        inline fn loadTail(self: *const Self, comptime order: Order) usize {
            return @atomicLoad(usize, &self._tail, order);
        }

        // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

        inline fn nthSlot(self: *Self, n: usize) *Slot {
            return &self._slots[(n % self._slots.len)];
        }

        inline fn nthTurn(self: *const Self, n: usize) usize {
            return (n / self._slots.len) * 2;
        }
    };
}

////////////////////////////////// T E S T S ///////////////////////////////////

test "MPMCQueue basics" {
    const Data = struct {
        a: [56]u8,
    };
    const Slot = MPMCQueueUnmanaged(Data).Slot;

    const expectEqual = std.testing.expectEqual;

    try expectEqual(cache_line_size, @alignOf(Slot));
    try expectEqual(true, @sizeOf(Slot) % cache_line_size == 0);

    std.debug.print("\n", .{});
    std.debug.print("@sizeOf(Data):{}\n", .{ @sizeOf(Data) });
    std.debug.print("@sizeOf(Slot):{}\n", .{ @sizeOf(Slot) });

    var allocator = std.testing.allocator;

    var queue = try MPMCQueueUnmanaged(usize).init(allocator, 4);
    defer queue.deinit(allocator);

    try expectEqual(@as(usize, 4), queue.capacity());
    try expectEqual(@as(usize, 0), queue.size());
    try expectEqual(true, queue.empty());

    queue.enqueue(@as(usize, 0));
    try expectEqual(@as(usize, 1), queue.size());
    try expectEqual(false, queue.empty());

    queue.enqueue(@as(usize, 1));
    try expectEqual(@as(usize, 2), queue.size());
    try expectEqual(false, queue.empty());

    queue.enqueue(@as(usize, 2));
    try expectEqual(@as(usize, 3), queue.size());
    try expectEqual(false, queue.empty());

    queue.enqueue(@as(usize, 3));
    try expectEqual(@as(usize, 4), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(false, queue.enqueueIfNotFull(4));
    try expectEqual(@as(usize, 4), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 0), queue.dequeue());
    try expectEqual(@as(usize, 3), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 1), queue.dequeue());
    try expectEqual(@as(usize, 2), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 2), queue.dequeue());
    try expectEqual(@as(usize, 1), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 3), queue.dequeue());
    try expectEqual(@as(usize, 0), queue.size());
    try expectEqual(true, queue.empty());
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "MPMCQueueUnmanaged(usize) multiple consumers" {
    std.debug.print("\n", .{});

    var allocator = std.testing.allocator;

    const JobQueue = MPMCQueueUnmanaged(usize);
    var queue = try JobQueue.init(allocator, 4);
    defer queue.deinit(allocator);

    const Context = struct {
        queue: *JobQueue,
    };
    var context = Context { .queue = &queue };

    const JobThread = struct {
        pub fn main(ctx: *Context) void {
            const tid = std.Thread.getCurrentId();

            while (true)
            {
                const job = ctx.queue.dequeue();
                std.debug.print("thread {} job {}\n", .{ tid, job });

                if (job == @as(usize, 0)) break;

                std.time.sleep(10);
            }

            std.debug.print("thread {} EXIT\n", .{ tid });
        }
    };

    const threads = [4]std.Thread{
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
    };

    queue.enqueue(@as(usize, 1));
    queue.enqueue(@as(usize, 2));
    queue.enqueue(@as(usize, 3));
    queue.enqueue(@as(usize, 4));

    std.time.sleep(100);

    queue.enqueue(@as(usize, 0));
    queue.enqueue(@as(usize, 0));
    queue.enqueue(@as(usize, 0));
    queue.enqueue(@as(usize, 0));

    for (threads) |thread| {
        thread.join();
    }

    std.debug.print("DONE\n", .{});
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

test "MPMCQueueUnmanaged(Job) multiple consumers" {
    std.debug.print("\n", .{});

    const Job = struct {
        const Self = @This();
        a: [56]u8 = undefined,

        pub fn init(id: u8) Self {
            var self = Self{};
            self.a[0] = id;
            return self;
        }
    };

    const JobQueue = MPMCQueueUnmanaged(Job);

    var allocator = std.testing.allocator;
    var queue = try JobQueue.init(allocator, 4);
    defer queue.deinit(allocator);

    const JobThread = struct {
        index: usize,
        queue: *JobQueue,

        pub fn main(self: @This()) void {
            std.debug.print("JobThread {} START\n", .{ self.index });

            while (true)
            {
                const job = self.queue.dequeue();
                std.debug.print("JobThread {} run job {}\n", .{ self.index, job.a[0] });

                if (job.a[0] == @as(u8, 0)) break;

                std.time.sleep(1);
            }

            std.debug.print("JobThread {} EXIT\n", .{ self.index });
        }
    };

    const threads = [4]std.Thread{
        try std.Thread.spawn(.{}, JobThread.main, .{ JobThread{.index = 0, .queue = &queue} }),
        try std.Thread.spawn(.{}, JobThread.main, .{ JobThread{.index = 1, .queue = &queue} }),
        try std.Thread.spawn(.{}, JobThread.main, .{ JobThread{.index = 2, .queue = &queue} }),
        try std.Thread.spawn(.{}, JobThread.main, .{ JobThread{.index = 3, .queue = &queue} }),
    };

    queue.enqueue(Job.init(1));
    queue.enqueue(Job.init(2));
    queue.enqueue(Job.init(3));
    queue.enqueue(Job.init(4));

    std.time.sleep(100);

    queue.enqueue(Job.init(0));
    queue.enqueue(Job.init(0));
    queue.enqueue(Job.init(0));
    queue.enqueue(Job.init(0));

    for (threads) |thread| {
        thread.join();
    }

    std.debug.print("DONE\n", .{});
}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
