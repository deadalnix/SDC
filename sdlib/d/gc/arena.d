module d.gc.arena;

import d.gc.allocclass;
import d.gc.emap;
import d.gc.extent;
import d.gc.hpd;
import d.gc.sizeclass;
import d.gc.spec;
import d.gc.util;

shared Arena gArena;

struct Arena {
private:
	import d.gc.base;
	Base base;

	import d.gc.region;
	shared(RegionAllocator)* regionAllocator;

	import d.sync.mutex;
	Mutex mutex;

	import d.gc.heap;
	Heap!(Extent, unusedExtentCmp) unusedExtents;
	Heap!(HugePageDescriptor, unusedHPDCmp) unusedHPDs;

	ulong filter;

	enum PageCount = HugePageDescriptor.PageCount;
	enum HeapCount = getAllocClass(PageCount);
	static assert(HeapCount <= 64, "Too many heaps to fit in the filter!");

	Heap!(HugePageDescriptor, epochHPDCmp)[HeapCount] heaps;

	import d.gc.bin;
	Bin[ClassCount.Small] bins;

public:
	enum size_t MaxSmallAllocSize = SizeClass.Small;
	enum size_t MaxLargeAllocSize = uint.max * PageSize;

	/**
	 * Small allocation facilities.
	 */
	void* allocSmall(shared(ExtentMap)* emap, size_t size) shared {
		// TODO: in contracts
		assert(size > 0 && size <= MaxSmallAllocSize);

		auto sizeClass = getSizeClass(size);
		assert(sizeClass < ClassCount.Small);

		return bins[sizeClass].alloc(&this, emap, sizeClass);
	}

	/**
	 * Large allocation facilities.
	 */
	void* allocLarge(shared(ExtentMap)* emap, size_t size,
	                 bool zero = false) shared {
		if (size <= MaxSmallAllocSize || size > MaxLargeAllocSize) {
			return null;
		}

		auto computedPageCount = alignUp(size, PageSize) / PageSize;
		uint pages = computedPageCount & uint.max;

		assert(pages == computedPageCount, "Unexpected page count!");

		auto e = allocPages(pages);
		if (e is null) {
			return null;
		}

		emap.remap(e);
		return e.addr;
	}

	/**
	 * Deallocation facility.
	 */
	void free(shared(ExtentMap)* emap, PageDescriptor pd, void* ptr) shared {
		assert(pd.extent !is null, "Extent is null!");
		assert(pd.extent.contains(ptr), "Invalid ptr!");
		assert(pd.extent.arena is &this, "Invalid arena!");

		import sdc.intrinsics;
		if (unlikely(!pd.isSlab()) || bins[pd.sizeClass].free(&this, ptr, pd)) {
			emap.clear(pd.extent);
			freePages(pd.extent);
		}
	}

package:
	Extent* allocSlab(shared(ExtentMap)* emap, ubyte sizeClass) shared {
		auto e = allocPages(binInfos[sizeClass].needPages, true, sizeClass);
		if (e !is null) {
			emap.remap(e, true, sizeClass);
		}

		return e;
	}

	void freeSlab(shared(ExtentMap)* emap, Extent* e) shared {
		assert(e.isSlab(), "Expected a slab!");

		emap.clear(e);
		freePages(e);
	}

private:
	Extent* allocPages(uint pages, bool is_slab, ubyte sizeClass) shared {
		assert(pages > 0 && pages <= PageCount, "Invalid page count!");
		auto mask = ulong.max << getAllocClass(pages);

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Arena*) &this)
			.allocPagesImpl(pages, mask, is_slab, sizeClass);
	}

	Extent* allocPages(uint pages) shared {
		import sdc.intrinsics;
		if (unlikely(pages > PageCount)) {
			return allocHuge(pages);
		}

		return allocPages(pages, false, ubyte(0));
	}

	Extent* allocHuge(uint pages) shared {
		assert(pages > PageCount, "Invalid page count!");

		uint extraPages = (pages - 1) / PageCount;
		pages = modUp(pages, PageCount);

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Arena*) &this).allocHugeImpl(pages, extraPages);
	}

	void freePages(Extent* e) shared {
		assert(isAligned(e.addr, PageSize), "Invalid extent addr!");
		assert(isAligned(e.size, PageSize), "Invalid extent size!");

		uint n = 0;
		if (!e.isHuge()) {
			assert(e.hpd.address is alignDown(e.addr, HugePageSize),
			       "Invalid hpd!");

			n = ((cast(size_t) e.addr) / PageSize) % PageCount;
		}

		auto computedPageCount = modUp(e.size / PageSize, PageCount);
		uint pages = computedPageCount & uint.max;

		assert(pages == computedPageCount, "Unexpected page count!");

		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(Arena*) &this).freePagesImpl(e, n, pages);
	}

private:
	Extent* allocPagesImpl(uint pages, ulong mask, bool is_slab,
	                       ubyte sizeClass) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto e = getOrAllocateExtent();
		if (e is null) {
			return null;
		}

		auto hpd = extractHPD(pages, mask);
		if (hpd is null) {
			unusedExtents.insert(e);
			return null;
		}

		auto n = hpd.reserve(pages);
		if (!hpd.full) {
			registerHPD(hpd);
		}

		auto addr = hpd.address + n * PageSize;
		auto size = pages * PageSize;

		return e.at(addr, size, hpd, is_slab, sizeClass);
	}

	HugePageDescriptor* extractHPD(uint pages, ulong mask) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto acfilter = filter & mask;
		if (acfilter == 0) {
			return allocateHPD();
		}

		import sdc.intrinsics;
		auto index = countTrailingZeros(acfilter);
		auto hpd = heaps[index].pop();
		filter &= ~(ulong(heaps[index].empty) << index);

		return hpd;
	}

	Extent* allocHugeImpl(uint pages, uint extraPages) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto e = getOrAllocateExtent();
		if (e is null) {
			return null;
		}

		auto hpd = allocateHPD(extraPages);
		if (hpd is null) {
			unusedExtents.insert(e);
			return null;
		}

		auto n = hpd.reserve(pages);
		assert(n == 0, "Unexpected page allocated!");

		if (!hpd.full) {
			registerHPD(hpd);
		}

		auto leadSize = extraPages * HugePageSize;
		auto addr = hpd.address - leadSize;
		auto size = leadSize + pages * PageSize;

		return e.at(addr, size, hpd);
	}

	auto getOrAllocateExtent() {
		assert(mutex.isHeld(), "Mutex not held!");

		auto e = unusedExtents.pop();
		if (e !is null) {
			return e;
		}

		auto slot = base.allocSlot();
		if (slot.address is null) {
			return null;
		}

		return Extent.fromSlot(&this, slot);
	}

	HugePageDescriptor* allocateHPD(uint extraPages = 0) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto hpd = unusedHPDs.pop();
		if (hpd is null) {
			static assert(HugePageDescriptor.sizeof <= MetadataSlotSize,
			              "Unexpected HugePageDescriptor size!");

			auto slot = base.allocSlot();
			if (slot.address is null) {
				return null;
			}

			hpd = HugePageDescriptor.fromSlot(slot);
		}

		if (regionAllocator.acquire(hpd, extraPages)) {
			return hpd;
		}

		unusedHPDs.insert(hpd);
		return null;
	}

	void freePagesImpl(Extent* e, uint n, uint pages) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(pages > 0 && pages <= PageCount, "Invalid number of pages!");
		assert(n <= PageCount - pages, "Invalid index!");

		auto hpd = e.hpd;
		if (!hpd.full) {
			auto index = getFreeSpaceClass(hpd.longestFreeRange);
			heaps[index].remove(hpd);
			filter &= ~(ulong(heaps[index].empty) << index);
		}

		hpd.release(n, pages);
		if (hpd.empty) {
			releaseHPD(e, hpd);
		} else {
			// If the extent is huge, we need to release the concerned region.
			if (e.isHuge()) {
				uint count = (e.size / HugePageSize) & uint.max;
				regionAllocator.release(e.addr, count);
			}

			registerHPD(hpd);
		}

		unusedExtents.insert(e);
	}

	void registerHPD(HugePageDescriptor* hpd) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(!hpd.full, "HPD is full!");
		assert(!hpd.empty, "HPD is empty!");

		auto index = getFreeSpaceClass(hpd.longestFreeRange);
		heaps[index].insert(hpd);
		filter |= ulong(1) << index;
	}

	void releaseHPD(Extent* e, HugePageDescriptor* hpd) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(hpd.empty, "HPD is not empty!");
		assert(e.hpd is hpd, "Invalid HPD!");

		auto ptr = alignDown(e.addr, HugePageSize);
		uint pages = (alignUp(e.size, HugePageSize) / HugePageSize) & uint.max;
		regionAllocator.release(ptr, pages);

		unusedHPDs.insert(hpd);
	}
}

unittest allocLarge {
	import d.gc.arena;
	shared Arena arena;

	auto base = &arena.base;
	scope(exit) arena.base.clear();

	import d.gc.emap;
	static shared ExtentMap emap;
	emap.tree.base = base;

	import d.gc.region;
	shared RegionAllocator regionAllocator;
	regionAllocator.base = base;

	arena.regionAllocator = &regionAllocator;

	enum MinLargeAlloc = Arena.MaxSmallAllocSize + 1;
	assert(arena.allocLarge(&emap, 0) is null);
	assert(arena.allocLarge(&emap, MinLargeAlloc - 1) is null);
	assert(arena.allocLarge(&emap, Arena.MaxLargeAllocSize + 1) is null);
	assert(arena.allocLarge(&emap, size_t.max) is null);

	auto ptr0 = arena.allocLarge(&emap, 4 * PageSize);
	assert(ptr0 !is null);
	auto pd0 = emap.lookup(ptr0);
	assert(pd0.extent.addr is ptr0);
	assert(pd0.extent.size == 4 * PageSize);

	auto ptr1 = arena.allocLarge(&emap, 12 * PageSize);
	assert(ptr1 !is null);
	assert(ptr1 is ptr0 + 4 * PageSize);
	auto pd1 = emap.lookup(ptr1);
	assert(pd1.extent.addr is ptr1);
	assert(pd1.extent.size == 12 * PageSize);

	arena.free(&emap, pd0, ptr0);
	auto pdf = emap.lookup(ptr0);
	assert(pdf.extent is null);

	// Do not reuse the free slot is there is no room.
	auto ptr2 = arena.allocLarge(&emap, 5 * PageSize);
	assert(ptr2 !is null);
	assert(ptr2 is ptr1 + 12 * PageSize);
	auto pd2 = emap.lookup(ptr2);
	assert(pd2.extent.addr is ptr2);
	assert(pd2.extent.size == 5 * PageSize);

	// But do reuse that free slot if there isn't.
	auto ptr3 = arena.allocLarge(&emap, 4 * PageSize);
	assert(ptr3 !is null);
	assert(ptr3 is ptr0);
	auto pd3 = emap.lookup(ptr3);
	assert(pd3.extent.addr is ptr3);
	assert(pd3.extent.size == 4 * PageSize);

	// Free everything.
	arena.free(&emap, pd1, ptr1);
	arena.free(&emap, pd2, ptr2);
	arena.free(&emap, pd3, ptr3);
}

unittest allocPages {
	import d.gc.arena;
	shared Arena arena;

	auto base = &arena.base;
	scope(exit) arena.base.clear();

	import d.gc.region;
	shared RegionAllocator regionAllocator;
	regionAllocator.base = base;

	arena.regionAllocator = &regionAllocator;

	auto e0 = arena.allocPages(1);
	assert(e0 !is null);
	assert(e0.size == PageSize);

	auto e1 = arena.allocPages(2);
	assert(e1 !is null);
	assert(e1.size == 2 * PageSize);
	assert(e1.addr is e0.addr + e0.size);

	auto e0Addr = e0.addr;
	arena.freePages(e0);

	// Do not reuse the free slot is there is no room.
	auto e2 = arena.allocPages(3);
	assert(e2 !is null);
	assert(e2.size == 3 * PageSize);
	assert(e2.addr is e1.addr + e1.size);

	// But do reuse that free slot if there isn't.
	auto e3 = arena.allocPages(1);
	assert(e3 !is null);
	assert(e3.size == PageSize);
	assert(e3.addr is e0Addr);

	// Free everything.
	arena.freePages(e1);
	arena.freePages(e2);
	arena.freePages(e3);
}

unittest allocHuge {
	import d.gc.arena;
	shared Arena arena;

	auto base = &arena.base;
	scope(exit) arena.base.clear();

	import d.gc.region;
	shared RegionAllocator regionAllocator;
	regionAllocator.base = base;

	arena.regionAllocator = &regionAllocator;

	enum uint PageCount = Arena.PageCount;
	enum uint AllocSize = PageCount + 1;

	// Allocate a huge extent.
	auto e0 = arena.allocPages(AllocSize);
	assert(e0 !is null);
	assert(e0.size == AllocSize * PageSize);

	// Free the huge extent.
	auto e0Addr = e0.addr;
	arena.freePages(e0);

	// Reallocating the same run will yield the same memory back.
	e0 = arena.allocPages(AllocSize);
	assert(e0 !is null);
	assert(e0.addr is e0Addr);
	assert(e0.size == AllocSize * PageSize);

	// Allocate one page on the borrowed huge page.
	auto e1 = arena.allocPages(1);
	assert(e1 !is null);
	assert(e1.size == PageSize);
	assert(e1.addr is e0.addr + e0.size);

	// Now, freeing the huge extent will leave a page behind.
	arena.freePages(e0);

	// Allocating another huge extent will use a new range.
	auto e2 = arena.allocPages(AllocSize);
	assert(e2 !is null);
	assert(e2.addr is alignUp(e1.addr, HugePageSize));
	assert(e2.size == AllocSize * PageSize);

	// Allocating new small extents fill the borrowed page.
	auto e3 = arena.allocPages(1);
	assert(e3 !is null);
	assert(e3.addr is alignDown(e1.addr, HugePageSize));
	assert(e3.size == PageSize);

	// But allocating just the right size will reuse the region.
	auto e4 = arena.allocPages(PageCount);
	assert(e4 !is null);
	assert(e4.addr is e0Addr);
	assert(e4.size == PageCount * PageSize);

	// Free everything.
	arena.freePages(e1);
	arena.freePages(e2);
	arena.freePages(e3);
	arena.freePages(e4);
}
