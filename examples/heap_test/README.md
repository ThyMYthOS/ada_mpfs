# heap_test

The heap of the `embedded` runtime of `crates/mpfs_rts`: the TLSF allocator (`Tlsf_Core`) behind `malloc`, `free`,
`realloc` and `calloc` (`MPFS_Heap`), over the memory from `__heap_start` to `__heap_end` of the linker script, with
the heap lock (`MPFS_Heap_Lock`: no interrupt on the hart during an operation of the allocator). See "Heap" in
`crates/mpfs_rts/README.md`.

| Check | What it proves |
|---|---|
| the heap is at least 512 KiB and is the distance of the two linker symbols | the arena is the range of the linker script (about 1.8 MB in the LIM) |
| at the first raise the free bytes of the heap shrink | libgcc's unwinder calls `malloc` by name and gets its memory from this heap, not from newlib's |
| `Acquire` masks `mstatus.MIE`, also nested; `Release` restores it, the outer one last; `malloc` leaves it as it was | the lock interface and its body for one hart |
| blocks of 1 to 100 bytes are 16-byte aligned and inside the heap; freeing them gives the heap back | alignment and the accounting of the free bytes |
| `malloc (0)`, `malloc (2**32)`, `malloc (size_t'Last)` and `calloc` of a product that wraps return no block; `free (null)` does nothing | the refusals of `Heap_Guard` and of the allocator, and no change of the heap by them |
| `calloc` returns zeros in a block that was used before; `realloc` of null, to less (same block), to more (content kept) and to 0 | the interface |
| `new` and `Unchecked_Deallocation` use this heap and give the memory back | `System.Memory` over `malloc` and `free` |
| 20 000 random allocations, releases and reallocations of blocks of 1 to 4000 bytes with a checked content | no block is overwritten by another, `Invariants_Hold` (the chain of blocks: ascending, contiguous, no two free neighbours) holds every 500 operations, and after freeing all the heap is as large as before |
| a block of 90 % of the heap can be had after that | everything coalesced again |
| 2000 blocks of 256 bytes, every second one freed, the next 1000 fill the holes, then all freed | fragmentation: the holes are used, the heap is whole again |
| blocks of 4 KiB until `malloc` returns null (about 440), `new` of 1 MiB raises `Storage_Error`, then all back | the limit: nothing is left when it fails, and all of it returns |
| `Heap_Hammer`, a task of the highest priority that wakes every millisecond and allocates and frees 16 blocks while the environment task runs the random operations | the timer interrupt can come at any instruction of the environment task, and the lock keeps the two out of each other's way: no block is disturbed, no request is refused, the chain is intact |

The image reports as `heap_test_e51` and `heap_test_u54` (hart 1); the rows are in `tests/qemu/tests.list`.
`console.expected` makes the host assert the `ok:` lines. The tables of the test (`Heap_Slots`) are library-level
objects: the environment task has 16 KiB of stack, and 2000 addresses are 16 000 bytes.

    ./x build heap_test --hart e51      # bin-e51/heap_test.elf
    ./x build heap_test --hart u54      # bin-u54/
    ./x test qemu tests heap_test_e51 heap_test_u54

The allocator itself is tested on the host (`tests/host/rts_heap`, the same sources compiled natively) and its size
arithmetic is proved (`tests/prove/tlsf`).
