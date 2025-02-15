module dmd.gc;

import d.gc.tcache;
import d.gc.spec;
import d.gc.slab;
import d.gc.emap;

extern(C):

void __sd_gc_init() {
	import d.gc.thread;
	createProcess();
}

// Some of the bits from druntime.
enum BlkAttr : uint {
	FINALIZE = 0b0000_0001,
	NO_SCAN = 0b0000_0010,
	APPENDABLE = 0b0000_1000
}

// ptr: the pointer to query
// base: => the true base address of the block
// size: => the full usable size of the block
// pd: => the page descriptor (used internally later)
// flags: => what the flags of the block are
//
bool __sd_gc_fetch_alloc_info(void* ptr, void** base, size_t* size,
                              PageDescriptor* pd, BlkAttr* flags) {
	*pd = threadCache.maybeGetPageDescriptor(ptr);
	auto e = pd.extent;
	*flags = cast(BlkAttr) 0;
	if (e is null) {
		return false;
	}

	if (!pd.containsPointers) {
		*flags |= BlkAttr.NO_SCAN;
	}

	if (pd.isSlab()) {
		auto si = SlabAllocInfo(*pd, ptr);
		*base = cast(void*) si.address;

		if (si.hasMetadata) {
			*flags |= BlkAttr.APPENDABLE;
			if (si.finalizer) {
				*flags |= BlkAttr.FINALIZE;
			}
		}

		*size = si.slotCapacity;
	} else {
		// Large blocks are always appendable.
		*flags |= BlkAttr.APPENDABLE;

		if (e.finalizer) {
			*flags |= BlkAttr.FINALIZE;
		}

		auto e = pd.extent;
		*base = e.address;

		*size = e.size;
	}

	return true;
}

bool __sd_gc_shrink_array_used(void* ptr, size_t newUsed, size_t existingUsed) {
	assert(newUsed <= existingUsed);
	auto pd = threadCache.maybeGetPageDescriptor(ptr);
	auto e = pd.extent;
	if (e is null) {
		return false;
	}

	if (pd.isSlab()) {
		auto si = SlabAllocInfo(pd, ptr);
		if (!threadCache.validateCapacity(ptr[0 .. existingUsed + 1],
		                                  si.address, si.usedCapacity)) {
			return false;
		}

		auto offset = ptr - si.address;
		return si.setUsedCapacity(newUsed + offset + 1);
	}

	// Large allocation.
	if (!threadCache.validateCapacity(ptr[0 .. existingUsed + 1], e.address,
	                                  e.usedCapacity)) {
		return false;
	}

	auto offset = ptr - e.address;
	e.setUsedCapacity(newUsed + offset + 1);
	return true;
}

bool __sd_gc_extend_array_used(void* ptr, size_t newUsed, size_t existingUsed) {
	assert(newUsed >= existingUsed);
	return
		threadCache.extend(ptr[0 .. existingUsed + 1], newUsed - existingUsed);
}

bool __sd_gc_reserve_array_capacity(void* ptr, size_t request,
                                    size_t existingUsed) {
	assert(request >= existingUsed);
	return
		threadCache.reserve(ptr[0 .. existingUsed + 1], request - existingUsed);
}

void[] __sd_gc_get_allocation_slice(const void* ptr) {
	return threadCache.getAllocationSlice(ptr);
}

size_t __sd_gc_get_array_capacity(void[] slice) {
	auto capacity = threadCache.getCapacity(slice.ptr[0 .. slice.length + 1]);
	if (capacity == 0) {
		return 0;
	}

	return capacity - 1;
}

void* __sd_gc_alloc_from_druntime(size_t size, uint flags, void* finalizer) {
	bool containsPointers = (flags & BlkAttr.NO_SCAN) == 0;
	if ((flags & BlkAttr.APPENDABLE) != 0 || finalizer) {
		// Add a byte to prevent cross-allocation pointers.
		return threadCache
			.allocAppendable(size + 1, containsPointers, false, finalizer);
	}

	return threadCache.alloc(size, containsPointers, false);
}

void __sd_gc_set_scanning_thread_count(uint nThreads) {
	import d.gc.collector;
	gCollectorState.setScanningThreads(nThreads);
}
