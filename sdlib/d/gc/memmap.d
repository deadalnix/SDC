module d.gc.memmap;

import d.gc.spec;
import d.gc.util;

import sys.mman;

void* pages_map(void* addr, size_t size, size_t alignment) {
	assert(alignment >= PageSize && isPow2(alignment), "Invalid alignment!");
	assert(isAligned(addr, alignment), "Invalid addr!");
	assert(size > 0 && isAligned(size, PageSize), "Invalid size!");

	/**
	 * Note from jemalloc:
	 *
	 * Ideally, there would be a way to specify alignment to mmap() (like
	 * NetBSD has), but in the absence of such a feature, we have to work
	 * hard to efficiently create aligned mappings.  The reliable, but
	 * slow method is to create a mapping that is over-sized, then trim the
	 * excess.  However, that always results in one or two calls to
	 * os_pages_unmap(), and it can leave holes in the process's virtual
	 * memory map if memory grows downward.
	 *
	 * Optimistically try mapping precisely the right amount before falling
	 * back to the slow method, with the expectation that the optimistic
	 * approach works most of the time.
	 */
	auto ret = os_pages_map(addr, size, alignment);
	if (ret is null || ret is addr) {
		return ret;
	}

	assert(addr is null);
	if (isAligned(ret, alignment)) {
		return ret;
	}

	// We do not have a properly aligned mapping. Let's fix this.
	pages_unmap(ret, size);

	auto asize = size + alignment - PageSize;
	if (asize < size) {
		// size_t wrapped around!
		return null;
	}

	ret = os_pages_map(null, asize, alignment);
	if (ret is null) {
		return null;
	}

	auto leadSize = alignUpOffset(ret, alignment);
	if (leadSize > 0) {
		pages_unmap(ret, leadSize);
	}

	assert(asize >= size + leadSize);
	auto trailSize = asize - leadSize - size;
	if (trailSize) {
		pages_unmap(ret + leadSize + size, trailSize);
	}

	return ret + leadSize;
}

void pages_unmap(void* addr, size_t size) {
	auto ret = munmap(addr, size);
	assert(ret == 0, "munmap failed!");
}

void pages_purge(void* addr, size_t size) {
	auto ret = madvise(addr, size, Madv.DontNeed);
	assert(ret == 0, "madvise failed!");
}

void pages_purge_lazy(void* addr, size_t size) {
	auto ret = madvise(addr, size, Madv.Free);
	assert(ret == 0, "madvise failed!");
}

void pages_zero(void* addr, size_t size) {
	if (size >= PurgePageThresoldSize) {
		pages_purge(addr, size);
	} else {
		memset(addr, 0, size);
	}
}

void page_hugify(void* addr, size_t size) {
	auto ret = madvise(addr, size, Madv.HugePage);
	assert(ret == 0, "madvise failed!");
}

void page_dehugify(void* addr, size_t size) {
	auto ret = madvise(addr, size, Madv.NoHugePage);
	assert(ret == 0, "madvise failed!");
}

private:

enum PagesFDTag = -1;
enum MMapFlags = Map.Private | Map.Anonymous;

void* os_pages_map(void* addr, size_t size, size_t alignment) {
	assert(alignment >= PageSize && isPow2(alignment), "Invalid alignment!");
	assert(isAligned(addr, alignment), "Invalid addr!");
	assert(size > 0 && isAligned(size, PageSize), "Invalid size!");

	auto ret =
		mmap(addr, size, Prot.Read | Prot.Write, MMapFlags, PagesFDTag, 0);
	assert(ret !is null);

	auto MAP_FAILED = cast(void*) -1L;
	if (ret is MAP_FAILED) {
		return null;
	}

	if (addr is null || ret is addr) {
		return ret;
	}

	// We mapped, but not where expected.
	pages_unmap(ret, size);
	return null;
}

unittest pages_map {
	auto ptr = pages_map(null, PageSize, PageSize);
	assert(ptr !is null);
	pages_unmap(ptr, PageSize);
}

unittest pages_map_align {
	struct Alloc {
		void* ptr;
		size_t length;
	}

	size_t i = 0;
	Alloc[32] allocs;
	for (size_t s = PageSize; s <= 1024 * 1024 * 1024; s <<= 1) {
		for (size_t a = PageSize; a <= s && a <= BlockSize; a <<= 1) {
			i = (i + 1) % allocs.length;
			if (allocs[i].ptr !is null) {
				pages_unmap(allocs[i].ptr, allocs[i].length);
			}

			auto ptr = pages_map(null, s, a);
			assert(isAligned(ptr, a));

			allocs[i].ptr = ptr;
			allocs[i].length = s;
		}
	}

	foreach (i; 0 .. allocs.length) {
		pages_unmap(allocs[i].ptr, allocs[i].length);
	}
}
