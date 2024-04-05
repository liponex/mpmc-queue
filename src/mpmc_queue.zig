const std = @import("std");

pub const cache_line_size: usize = 64;

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            data: T align(cache_line_size) = undefined,
            turn: usize = 0,

            pub fn loadTurn(slot: *const Slot) usize {
                return @atomicLoad(usize, &slot.turn, .acquire);
            }

            pub fn storeTurn(slot: *Slot, value: usize) void {
                @atomicStore(usize, &slot.turn, value, .release);
            }
        };

        const NoSlots: []Slot = &[0]Slot{};

        // zig fmt: off
        // Aligned to avoid false sharing
        _head  :  usize align(cache_line_size) = 0,
        _tail  :  usize align(cache_line_size) = 0,
        _slots : []Slot align(cache_line_size) = NoSlots,
        // zig fmt: on

        pub fn init(allocator: std.mem.Allocator, _capacity: usize) !Self {
            // Allocate an extra slot to avoid false sharing on the last slot
            const slots = try allocator.alloc(Slot, _capacity + 1);
            std.debug.assert(@intFromPtr(slots.ptr) % cache_line_size == 0);
            std.debug.assert(@intFromPtr(slots.ptr) % @alignOf(T) == 0);

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

        pub fn capacity(self: *const Self) usize {
            return self._slots.len;
        }

        pub fn empty(self: *const Self) bool {
            return self.size() == 0;
        }

        pub fn size(self: *const Self) usize {
            const head = self.loadHead(.monotonic);
            const tail = self.loadTail(.monotonic);
            return if (head > tail) head - tail else 0;
        }

        /// Enqueue `value`, blocking while queue is full.
        pub fn push(self: *Self, value: T) void {
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
        pub fn tryPush(self: *Self, value: T) bool {
            var head = self.loadHead(.acquire);
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
                    head = self.loadHead(.acquire);
                    if (head == prev_head) {
                        return false;
                    }
                }
            }
        }

        /// Dequeue one element, blocking while queue is empty.
        pub fn pop(self: *Self) T {
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
        pub fn tryPop(self: *Self) ?T {
            var tail = self.loadTail(.acquire);
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
                    tail = self.loadTail(.acquire);
                    if (tail == prev_tail) {
                        return null;
                    }
                }
            }
        }

        const Order = std.builtin.AtomicOrder;

        inline fn bumpHead(self: *Self) usize {
            return @atomicRmw(usize, &self._head, .Add, 1, .monotonic);
        }

        inline fn bumpHeadIfEql(self: *Self, n: usize) bool {
            return null == @cmpxchgStrong(usize, &self._head, n, n + 1, .monotonic, .monotonic);
        }

        inline fn loadHead(self: *const Self, comptime order: Order) usize {
            return @atomicLoad(usize, &self._head, order);
        }

        inline fn bumpTail(self: *Self) usize {
            return @atomicRmw(usize, &self._tail, .Add, 1, .monotonic);
        }

        inline fn bumpTailIfEql(self: *Self, n: usize) bool {
            return null == @cmpxchgStrong(usize, &self._tail, n, n + 1, .monotonic, .monotonic);
        }

        inline fn loadTail(self: *const Self, comptime order: Order) usize {
            return @atomicLoad(usize, &self._tail, order);
        }

        inline fn nthSlot(self: *Self, n: usize) *Slot {
            return &self._slots[(n % self._slots.len)];
        }

        inline fn nthTurn(self: *const Self, n: usize) usize {
            return (n / self._slots.len) * 2;
        }
    };
}

//--------------------------------- T E S T S -------------------------------
test "Queue basics" {
    const Data = struct {
        a: [56]u8,
    };
    const Slot = Queue(Data).Slot;

    const expectEqual = std.testing.expectEqual;

    try expectEqual(cache_line_size, @alignOf(Slot));
    try expectEqual(true, @sizeOf(Slot) % cache_line_size == 0);

    const allocator = std.testing.allocator;

    var queue = try Queue(usize).init(allocator, 4);
    defer queue.deinit(allocator);

    try expectEqual(@as(usize, 4), queue.capacity());
    try expectEqual(@as(usize, 0), queue.size());
    try expectEqual(true, queue.empty());

    queue.push(@as(usize, 0));
    try expectEqual(@as(usize, 1), queue.size());
    try expectEqual(false, queue.empty());

    queue.push(@as(usize, 1));
    try expectEqual(@as(usize, 2), queue.size());
    try expectEqual(false, queue.empty());

    queue.push(@as(usize, 2));
    try expectEqual(@as(usize, 3), queue.size());
    try expectEqual(false, queue.empty());

    queue.push(@as(usize, 3));
    try expectEqual(@as(usize, 4), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(false, queue.tryPush(4));
    try expectEqual(@as(usize, 4), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 0), queue.pop());
    try expectEqual(@as(usize, 3), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 1), queue.pop());
    try expectEqual(@as(usize, 2), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 2), queue.pop());
    try expectEqual(@as(usize, 1), queue.size());
    try expectEqual(false, queue.empty());

    try expectEqual(@as(usize, 3), queue.pop());
    try expectEqual(@as(usize, 0), queue.size());
    try expectEqual(true, queue.empty());
}

test "Queue(usize) multiple consumers" {
    const allocator = std.testing.allocator;

    const JobQueue = Queue(usize);
    var queue = try JobQueue.init(allocator, 4);
    defer queue.deinit(allocator);

    const Context = struct {
        queue: *JobQueue,
    };
    var context = Context{ .queue = &queue };

    const JobThread = struct {
        pub fn main(ctx: *Context) void {
            while (true) {
                const job = ctx.queue.pop();
                if (job == @as(usize, 0)) break;
                std.time.sleep(10);
            }
        }
    };

    const threads = [4]std.Thread{
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
        try std.Thread.spawn(.{}, JobThread.main, .{&context}),
    };

    queue.push(@as(usize, 1));
    queue.push(@as(usize, 2));
    queue.push(@as(usize, 3));
    queue.push(@as(usize, 4));

    std.time.sleep(100);

    queue.push(@as(usize, 0));
    queue.push(@as(usize, 0));
    queue.push(@as(usize, 0));
    queue.push(@as(usize, 0));

    for (threads) |thread| {
        thread.join();
    }
}

test "Queue(Job) multiple consumers" {
    const Job = struct {
        const Self = @This();

        a: [56]u8 = undefined,

        pub fn init(id: u8) Self {
            var self = Self{};
            self.a[0] = id;
            return self;
        }
    };

    const JobQueue = Queue(Job);

    const allocator = std.testing.allocator;
    var queue = try JobQueue.init(allocator, 4);
    defer queue.deinit(allocator);

    const JobThread = struct {
        const Self = @This();
        const Thread = std.Thread;
        const SpawnConfig = Thread.SpawnConfig;
        const SpawnError = Thread.SpawnError;

        index: usize,
        queue: *JobQueue,

        pub fn init(index: usize, _queue: *JobQueue) Self {
            return Self{ .index = index, .queue = _queue };
        }

        pub fn spawn(config: SpawnConfig, index: usize, _queue: *JobQueue) !Thread {
            return Thread.spawn(config, Self.main, .{Self.init(index, _queue)});
        }

        pub fn main(self: Self) void {
            while (true) {
                const job = self.queue.pop();
                if (job.a[0] == @as(u8, 0)) break;
                std.time.sleep(1);
            }
        }
    };

    const threads = [4]std.Thread{
        try JobThread.spawn(.{}, 1, &queue),
        try JobThread.spawn(.{}, 2, &queue),
        try JobThread.spawn(.{}, 3, &queue),
        try JobThread.spawn(.{}, 4, &queue),
    };

    queue.push(Job.init(1));
    queue.push(Job.init(2));
    queue.push(Job.init(3));
    queue.push(Job.init(4));

    std.time.sleep(100);

    queue.push(Job.init(0));
    queue.push(Job.init(0));
    queue.push(Job.init(0));
    queue.push(Job.init(0));

    for (threads) |thread| {
        thread.join();
    }
}
