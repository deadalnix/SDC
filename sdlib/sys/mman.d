import sys.mman;

import sys.posix.types;

extern(C):

enum Prot {
	// Page can be read.
	Read = 0x1,
	// Page can be written.
	Write = 0x2,
	// Page can be executed.
	Exec = 0x4,
	// Page may be used for atomic ops.
	Sem = 0x8,

	// Page can not be accessed.
	None = 0x0,
	// mprotect flag: extend change to start of growsdown vma
	GrowsDown = 0x01000000,
	// mprotect flag: extend change to end of growsup vma
	GrowsUp = 0x02000000,
}

enum Map {
	/* compatibility flags */
	File = 0,

	/* 0x01 - 0x03 are defined in linux/mman.h */
	// Share changes.
	Shared = 0x01,
	// Changes are private.
	Private = 0x02,
	// Share changes and validate extension flags.
	SharedValidate = 0x03,
	// Zero memory under memory pressure.
	Droppable = 0x08,

	// Mask for type of mapping.
	Type = 0x0f,
	// Interpret addr exactly.
	Fixed = 0x10,
	// Don't use a file.
	Anonymous = 0x20,

	/* X64 specific flags. */
	// Only give out 32bit addresses.
	_32Bits = 0x40,
	// Only map above 4GB.
	Above4G = 0x80,

	/* 0x0100 - 0x4000 flags are defined in asm-generic/mman.h */
	// Stack-like segment.
	GrowsDown = 0x0100,
	// ETXTBSY
	DenyWrite = 0x0800,
	// Mark it as an executable.
	Executable = 0x1000,
	// Pages are locked.
	Locked = 0x2000,
	// Don't check for reservations.
	NoReserve = 0x4000,

	// Populate (prefault) pagetables.
	Populate = 0x008000,
	// Do not block on IO.
	NonBlock = 0x010000,
	// Give out an address that is best suited for process/thread stacks.
	Stack = 0x020000,
	// Create a huge page mapping.
	HugeTLB = 0x040000,
	// Perform synchronous page faults for the mapping.
	Sync = 0x080000,
	// Map.Fixed which doesn't unmap underlying mapping.
	FixedNoreplace = 0x100000,

	// For anonymous mmap, memory could be uninitialized.
	Uninitialized = 0x4000000,
}

enum MLock {
	// Lock pages in range after they are faulted in, do not prefault.
	OnFault = 0x01,
}

enum MS {
	// Sync memory asynchronously.
	Async = 1,
	// Invalidate the caches.
	Invalidate = 2,
	// Synchronous memory sync.
	Sync = 4,
}

enum Madv {
	// No further special treatment.
	Normal = 0,
	// Expect random page references.
	Random = 1,
	// Expect sequential page references.
	Sequential = 2,
	// Will need these pages.
	Willneed = 3,
	// Don't need these pages.
	DontNeed = 4,

	// Free pages only if memory pressure.
	Free = 8,
	// Remove these pages & resources.
	Remove = 9,
	// Don't inherit across fork.
	DontFork = 10,
	// Do inherit across fork.
	DoFork = 11,
	// Poison a page for testing.
	HwPoison = 100,
	// Soft offline page for testing.
	SoftOnline = 101,

	// KSM may merge identical pages.
	Mergeable = 12,
	// KSM may not merge identical pages.
	Unmergeable = 13,

	// Worth backing with hugepages.
	HugePage = 14,
	// Not worth backing with hugepages.
	NoHugePage = 15,

	// Explicity exclude from the core dump, overrides the coredump filter bits.
	DontDump = 16,
	// Clear the DontDump flag.
	DoDump = 17,

	// Zero memory on fork, child only.
	WipeOnFork = 18,
	// Undo WipeOnFork.
	KeeponFork = 19,

	// Deactivate these pages.
	Cold = 20,
	// Reclaim these pages.
	PageOut = 21,

	// Populate (prefault) page tables readable.
	PopulateRead = 22,
	// Populate (prefault) page tables writable.
	PopulateWrite = 23,

	// Like DontNeed, but drop locked pages too.
	DontNeedLocked = 24,

	// Synchronous hugepage collapse.
	Collapse = 25,
}

enum PKey {
	DisableAccess = 0x1,
	DisableWrite = 0x2,
	AccessMask = PKey.DisableAccess | PKey.DisableWrite,
}

enum MCL {
	// Lock all current mappings.
	Current = 1,
	// Lock all future mappings.
	Future = 2,
	// Lock all pages that are faulted in.
	OnFault = 4,
}

void* mmap(void* __addr, size_t __len, int __prot, int __flags, int __fd,
           off_t __offset);

void* mmap64(void* __addr, size_t __len, int __prot, int __flags, int __fd,
             off64_t __offset);

int munmap(void* __addr, size_t __len);

int mprotect(void* __addr, size_t __len, int __prot);

int msync(void* __addr, size_t __len, int __flags);

int madvise(void* __addr, size_t __len, int __advice);

int posix_madvise(void* __addr, size_t __len, int __advice);

int mlock(const void* __addr, size_t __len);
int munlock(const void* __addr, size_t __len);

int mlockall(int __flags);
int munlockall();

void* mremap(void* __addr, size_t __old_len, size_t __new_len, int __flags,
             ...);

int remap_file_pages(void* __start, size_t __size, int __prot, size_t __pgoff,
                     int __flags);

int shm_open(const char* __name, int __oflag, mode_t __mode);
int shm_unlink(const char* __name);

// iovec extensions.
/+
__ssize_t process_madvise(int __pid_fd, const iovec* __iov, size_t __count,
                          int __advice, uint __flags)
int process_mrelease(int pidfd, uint flags);
// +/
