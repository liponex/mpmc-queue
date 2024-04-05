# Multi-producer Multi-consumer Queue

Zig implementation of a multi-producer multi-consumer concurrent queue

---

Original project in C++ by [@rigtorp](https://github.com/rigtorp): [link](https://github.com/rigtorp/MPMCQueue)
Original project by [@garettbass](https://github.com/garettbass): [link](https://github.com/garettbass/mpmc_queue)

---

# How to use it

<details> <summary>Fetch dependency</summary>

To fetch main branch use this command:
```bash
zig fetch --save=mpmc_queue git+https://github.com/liponex/mpmc-queue.git#main
```
</details>

<details> <summary>build.zig</summary>

Add dependency:
```zig
const mpmc_queue = b.dependency("mpmc_queue", .{
    .target = target,
    .optimize = optimize,
});
```

Add import and install artifact
```zig
compile.root_module.addImport("mpmc_queue", mpmc_queue.module("queue"));
const mpmc_queue_artifact = b.addStaticLibrary(.{
    .name = "mpmc_queue",
    .root_source_file = spsc_queue.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

b.installArtifact(mpmc_queue_artifact);
```
Where `compile` might be lib or exe

If you have more compilation targets (e.g. tests), you can add:
```zig
unit_tests.root_module.addImport("mpmc_queue", mpmc_queue.module("queue"));
```
Where `unit_tests` is a value of `b.addTest`
</details>

<details> <summary>Usage example</summary>

Import dependency:
```zig
const std = @import("std");
const mpmc = @import("mpmc_queue");
```

Producer thread function
```zig
fn producer(queue: *mpmc.Queue(u8)) void {
    for (0..255) |i| {
        queue.push(i);
    }
}
```

Consumer thread function
```zig
fn consumer(queue: *mpmc.Queue(u8)) void {
    for (0..255) {
        std.log.info("{d}", .{queue.pop()});
    }
}
```

Initializing
```zig
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var queue = try mpmc.Queue(u8).init(allocator, 256);
    defer queue.deinit(allocator);
    const producer_thread = try std.Thread.spawn(
        .{.allocator = allocator},
        producer,
        .{ &queue });
    producer_thread.detach();
    
    const consumer_thread = try std.Thread.spawn(
        .{.allocator = allocator},
        consumer,
        .{ &queue });
    consumer_thread.join();
}
```
</details>