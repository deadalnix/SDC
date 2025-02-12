module d.gc.page;

import d.gc.allocclass;
import d.gc.arena;
import d.gc.block;
import d.gc.emap;
import d.gc.extent;
import d.gc.size;
import d.gc.spec;
import d.gc.util;

import sdc.intrinsics;

enum ShouldZeroFreeSlabs = true;

struct PageFiller {
private:
	@property
	shared(Arena)* arena() shared {
		auto a = cast(Arena*) null;
		auto offset = cast(size_t) &(a.filler);

		auto base = cast(size_t) &this;
		return cast(shared(Arena)*) (base - offset);
	}

	import d.sync.mutex;
	shared Mutex mutex;

	/**
	 * We separate dense from sparse allocations.
	 * 
	 * Dense allocations are slabs which contains a lot of elements.
	 * In practice, these slabs tends to be long lived, because it
	 * is unlikely that all of their slots get freed at the same time.
	 * In addition, all slabs that require spacial care, such as slabs
	 * that cannot do inline marking, are dense, so segregating them
	 * allows to iterate over all of them efficiently.
	 * 
	 * The second set of heaps is used for sparse allocations.
	 * Sparse allocation are slabs with few elements, and large
	 * allocations.
	 */
	enum HeapCount = getAllocClass(PagesInBlock - 1);
	static assert(HeapCount <= 32, "Too many heaps to fit in the filter!");

	uint denseFilter;
	uint sparseFilter;

	PriorityBlockHeap[8] denseHeaps;
	PriorityBlockHeap[HeapCount] sparseHeaps;

	AllBlockRing denseBlocks;
	AllBlockRing sparseBlocks;

	import d.sync.atomic;
	shared Atomic!size_t usedPageCount;

	import d.gc.ring;
	Ring!BlockDescriptor fullBlocks;

	UnusedExtentHeap unusedExtents;
	UnusedBlockHeap unusedBlockDescriptors;

	OutlinedBitmap* outlinedBitmaps;

	import d.gc.base;
	shared Base base;

	import d.gc.region;
	shared(RegionAllocator)* regionAllocator;

public:
	/**
	 * Slabs facilities.
	 */
	Extent* allocSlab(ref CachedExtentMap emap, ubyte sizeClass) shared {
		import d.gc.slab;
		auto neededPages = binInfos[sizeClass].npages;

		auto ec = ExtentClass.slab(sizeClass);
		auto e = allocSmallRun(neededPages, neededPages - 1, ec);
		if (unlikely(e is null)) {
			return null;
		}

		if (likely(emap.remap(e, ec))) {
			return e;
		}

		// We failed to map the extent, unwind!
		freePages(e);
		return null;
	}

	/**
	 * Large allocation facilities.
	 */
	void* allocLarge(ref CachedExtentMap emap, uint pages, bool zero) shared {
		bool dirty;
		auto e = allocPages(pages, dirty);
		if (unlikely(e is null)) {
			return null;
		}

		if (!likely(emap.remap(e))) {
			// We failed to map the extent, unwind!
			freePages(e);
			return null;
		}

		if (zero && dirty) {
			import d.gc.memmap;
			pages_zero(e.address, e.size);
		}

		return e.address;
	}

	bool growLarge(ref CachedExtentMap emap, Extent* e, uint pages) shared {
		assert(e !is null, "Extent is null!");
		assert(e.isLarge(), "Expected a large extent!");
		assert(pages > e.npages, "Invalid page count!");

		auto n = e.blockIndex;
		uint currentPages = e.npages;

		uint start = n + currentPages - 1;
		uint stop = n + pages - 1;
		uint delta = pages - currentPages;

		if ((start ^ stop) < PagesInBlock) {
			assert(delta < PagesInBlock, "Invalid delta!");

			// We cannot hugify an extant that isn't block aligned.
			import d.gc.size;
			if (n != 0 && isHugePageCount(pages)) {
				return false;
			}

			uint index = (n + currentPages) % PagesInBlock;
			if (!growAlloc(e, index, delta)) {
				return false;
			}
		} else {
			// We cannot hugify an extent that isn't block aligned.
			if (n != 0) {
				return false;
			}

			uint currentBlocks = ((currentPages - 1) / PagesInBlock) + 1;
			uint newBlocks = ((pages - 1) / PagesInBlock) + 1;
			assert(newBlocks > currentBlocks, "Invalid block count!");

			auto extraBlocks = newBlocks - currentBlocks;
			if (!growHuge(e, extraBlocks, pages, delta)) {
				return false;
			}
		}

		auto pd = PageDescriptor(e, ExtentClass.large());
		auto endPtr = e.address + currentPages * PageSize;
		if (likely(emap.map(endPtr, delta, pd.next(currentPages)))) {
			return true;
		}

		// We failed to map the new pages, unwind!
		bool success = shrinkLarge(emap, e, currentPages);
		assert(success,
		       "Failed to shrink back the extent to its original size!");

		return false;
	}

	bool shrinkLarge(ref CachedExtentMap emap, Extent* e, uint pages) shared {
		assert(e !is null, "Extent is null!");
		assert(e.isLarge(), "Expected a large extent!");
		assert(pages > 0 && pages < e.npages, "Invalid page count!");

		auto n = e.blockIndex;
		uint currentPages = e.npages;

		uint start = n + pages - 1;
		uint stop = n + currentPages - 1;

		if ((start ^ stop) >= PagesInBlock) {
			// We check that the old size and the new size
			// terminate in the same block.
			return false;
		}

		uint delta = currentPages - pages;
		assert(delta < PagesInBlock, "Invalid delta!");

		emap.clear(e.address + pages * PageSize, delta);

		uint index = (n + pages) % PagesInBlock;
		shrinkAlloc(e, index, delta);

		return true;
	}

	/**
	 * Allocate and free Pages.
	 */
	Extent* allocPages(uint pages, ref bool dirty) shared {
		if (unlikely(pages > MaxPagesInLargeAlloc)) {
			return allocHuge(pages);
		}

		auto allocClass = getAllocClass(pages);
		return allocRun(pages, allocClass, ExtentClass.large(), dirty);
	}

	Extent* allocSmallRun(uint pages, uint allocClass, ExtentClass ec) shared {
		bool dirty;
		return allocRun(pages, allocClass, ec, dirty);
	}

	Extent* allocRun(uint pages, uint allocClass, ExtentClass ec,
	                 ref bool dirty) shared {
		assert(0 < pages && pages <= MaxPagesInLargeAlloc,
		       "Invalid page count!");
		assert(allocClass == getAllocClass(pages), "Invalid allocClass!");

		auto mask = uint.max << allocClass;

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this).allocRunImpl(pages, mask, ec, dirty);
	}

	Extent* allocHuge(uint pages) shared {
		assert(pages > MaxPagesInLargeAlloc, "Invalid page count!");

		uint extraBlocks = (pages - 1) / PagesInBlock;
		pages = modUp(pages, PagesInBlock);

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this).allocHugeImpl(pages, extraBlocks);
	}

	void freeExtent(ref CachedExtentMap emap, Extent* e) shared {
		emap.clear(e);
		freePages(e);
	}

	void freePages(Extent* e) shared {
		assert(isAligned(e.address, PageSize), "Invalid extent address!");
		assert(e.arenaIndex == arena.index, "Invalid arena!");

		uint n = e.blockIndex;
		uint pages = modUp(e.npages, PagesInBlock);

		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PageFiller*) &this).freePagesImpl(e, n, pages);
	}

	/**
	 * GC facilities.
	 */
	void prepareGCCycle(ref CachedExtentMap emap) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PageFiller*) &this).prepareGCCycleImpl(emap);
	}

	void collect(ref CachedExtentMap emap, ubyte gcCycle) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PageFiller*) &this)
			.collectImpl(emap, gcCycle, arena.containsPointers);
	}

	/**
	 * Usage stats.
	 */
	@property
	size_t usedPages() shared {
		return usedPageCount.load();
	}

private:
	/**
	 * Allocate and free pages, private implementation.
	 */
	Extent* allocRunImpl(uint pages, uint mask, ExtentClass ec,
	                     ref bool dirty) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto e = getOrAllocateExtent();
		if (unlikely(e is null)) {
			return null;
		}

		auto block = extractBlock(pages, mask, ec.dense);
		if (unlikely(block is null)) {
			unusedExtents.insert(e);
			return null;
		}

		auto n = block.reserve(pages, dirty);
		registerBlock(block);

		usedPageCount.fetchAdd(pages);

		auto ptr = block.address + n * PageSize;
		return e.at(ptr, pages, block, ec);
	}

	Extent* allocHugeImpl(uint pages, uint extraBlocks) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(pages <= PagesInBlock, "Invalid page count!");

		auto e = getOrAllocateExtent();
		if (unlikely(e is null)) {
			return null;
		}

		auto block = acquireSparseBlock(extraBlocks);
		if (unlikely(block is null)) {
			unusedExtents.insert(e);
			return null;
		}

		bool dirty;
		auto n = block.reserve(pages, dirty);
		registerBlock(block);

		assert(n == 0, "Unexpected page allocated!");
		assert(!dirty, "Huge allocations shouldn't be dirty!");

		auto npages = pages + extraBlocks * PagesInBlock;
		usedPageCount.fetchAdd(npages);

		auto leadSize = extraBlocks * BlockSize;
		auto ptr = block.address - leadSize;
		return e.at(ptr, npages, block);
	}

	void freePagesImpl(Extent* e, uint n, uint pages) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(pages > 0 && pages <= PagesInBlock, "Invalid number of pages!");
		assert(n <= PagesInBlock - pages, "Invalid index!");

		auto block = e.block;
		unregisterBlock(block);

		block.release(n, pages);
		if (block.empty) {
			releaseBlock(e, block);
		} else {
			// If the extent is larger than a block,
			// we need to release the extra region.
			if (e.npages > PagesInBlock) {
				mutex.unlock();
				scope(exit) mutex.lock();

				regionAllocator.release(e.address, e.npages / PagesInBlock);
			}

			registerBlock(block);
		}

		usedPageCount.fetchSub(e.npages);
		unusedExtents.insert(e);
	}

	/**
	 * Large allocation resizing facilities, private implementation.
	 */
	bool growAlloc(Extent* e, uint index, uint delta) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this).growAllocImpl(e, index, delta);
	}

	bool growAllocImpl(Extent* e, uint index, uint delta) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(delta > 0 && delta < PagesInBlock, "Invalid delta!");
		assert(index > 0 && index <= PagesInBlock - delta, "Invalid index!");

		auto block = e.block;
		unregisterBlock(block);
		scope(success) registerBlock(block);

		if (!block.growAt(index, delta)) {
			return false;
		}

		usedPageCount.fetchAdd(delta);
		e.growBy(delta);

		return true;
	}

	bool growHuge(Extent* e, uint extraBlocks, uint pages, uint delta) shared {
		pages = modUp(pages, PagesInBlock);

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this)
			.growHugeImpl(e, extraBlocks, pages, delta);
	}

	bool growHugeImpl(Extent* e, uint extraBlocks, uint pages, uint delta) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(extraBlocks > 0, "Invalid extraBlocks!");
		assert(pages > 0 && pages <= PagesInBlock, "Invalid pages!");
		assert(delta > 0, "Invalid delta!");

		auto block = e.block;
		assert(!block.dense, "Large must be sparse!");

		if (block.allocCount > 1) {
			// There are allocations after this one in the block.
			return false;
		}

		auto address = block.address;
		if (!regionAllocator.acquireAt(address + BlockSize, extraBlocks)) {
			return false;
		}

		unregisterBlock(block);
		sparseBlocks.remove(block);

		block.at(address + extraBlocks * BlockSize, false);
		sparseBlocks.insert(block);

		bool dirty;
		auto n = block.reserve(pages, dirty);
		registerBlock(block);

		assert(n == 0, "Unexpected page allocated!");
		assert(!dirty, "Huge allocations shouldn't be dirty!");

		usedPageCount.fetchAdd(delta);
		e.growBy(delta);

		return true;
	}

	void shrinkAlloc(Extent* e, uint index, uint delta) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PageFiller*) &this).shrinkAllocImpl(e, index, delta);
	}

	void shrinkAllocImpl(Extent* e, uint index, uint delta) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(delta > 0 && delta < PagesInBlock, "Invalid delta!");
		assert(index > 0 && index <= PagesInBlock - delta, "Invalid index!");

		auto block = e.block;
		unregisterBlock(block);
		scope(success) registerBlock(block);

		block.clear(index, delta);
		assert(!block.empty);

		usedPageCount.fetchSub(delta);
		e.shrinkBy(delta);
	}

	/**
	 * BlockDescriptor management.
	 */
	bool refillBlockDescriptors() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (!unusedBlockDescriptors.empty) {
			return true;
		}

		auto page = base.allocMetadataPage();
		if (page.address is null) {
			return false;
		}

		unusedBlockDescriptors = BlockDescriptor.fromPage(page);
		return true;
	}

	BlockDescriptor* getOrAllocateBlockDescriptor() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (!refillBlockDescriptors()) {
			return null;
		}

		return unusedBlockDescriptors.pop();
	}

	/**
	 * Heaps management.
	 */
	auto getFilterPtr(bool dense) {
		return dense ? &denseFilter : &sparseFilter;
	}

	auto getHeaps(bool dense) {
		return dense ? denseHeaps.ptr : sparseHeaps.ptr;
	}

	BlockDescriptor* extractBlock(uint pages, uint mask, bool dense) {
		assert(mutex.isHeld(), "Mutex not held!");

		return dense
			? extractBlockImpl!true(pages, mask)
			: extractBlockImpl!false(pages, mask);
	}

	BlockDescriptor* extractBlockImpl(bool Dense)(uint pages, uint mask) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto filter = getFilterPtr(Dense);
		auto acfilter = *filter & mask;
		if (acfilter == 0) {
			return acquireBlock!Dense();
		}

		auto index = countTrailingZeros(acfilter);
		auto heaps = getHeaps(Dense);

		auto block = heaps[index].pop();
		*filter &= ~(uint(heaps[index].empty) << index);

		assert(block !is null);
		assert(block.dense == Dense);
		return block;
	}

	static uint cappedIndex(BlockDescriptor* block) {
		auto index = block.freeRangeClass;
		if (block.sparse) {
			return index;
		}

		return min!uint(index, 7);
	}

	void unregisterBlock(BlockDescriptor* block) {
		assert(mutex.isHeld(), "Mutex not held!");

		if (block.full) {
			fullBlocks.remove(block);
			return;
		}

		auto index = cappedIndex(block);
		auto filter = getFilterPtr(block.dense);
		auto heaps = getHeaps(block.dense);

		heaps[index].remove(block);
		*filter &= ~(ulong(heaps[index].empty) << index);
	}

	void registerBlock(BlockDescriptor* block) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(!block.empty, "Block is empty!");

		if (block.full) {
			fullBlocks.insert(block);
			return;
		}

		auto index = cappedIndex(block);
		auto filter = getFilterPtr(block.dense);
		auto heaps = getHeaps(block.dense);

		heaps[index].insert(block);
		*filter |= 1 << index;
	}

	auto getAllBlocks(bool dense) {
		return dense ? &denseBlocks : &sparseBlocks;
	}

	BlockDescriptor* acquireDenseBlock() {
		assert(mutex.isHeld(), "Mutex not held!");

		return acquireBlock!true(0);
	}

	BlockDescriptor* acquireSparseBlock(uint extraBlocks = 0) {
		assert(mutex.isHeld(), "Mutex not held!");

		return acquireBlock!false(extraBlocks);
	}

	BlockDescriptor* acquireBlock(bool Dense)(uint extraBlocks = 0) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(!Dense || extraBlocks == 0, "Huge allocations cannot be dense!");

		if (!refillBlockDescriptors()) {
			return null;
		}

		void* address;
		if (!regionAllocator.acquire(address, extraBlocks)) {
			return null;
		}

		auto block = unusedBlockDescriptors.pop();
		assert(block !is null);

		block.at(address, Dense);
		getAllBlocks(Dense).insert(block);
		return block;
	}

	void releaseBlock(Extent* e, BlockDescriptor* block) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(block.empty, "Block is not empty!");
		assert(e.block is block, "Invalid Block!");

		// We do not manage this block anymore.
		getAllBlocks(block.dense).remove(block);
		unusedBlockDescriptors.insert(block);

		mutex.unlock();
		scope(exit) mutex.lock();

		auto nblocks = alignUp(e.npages, PagesInBlock) / PagesInBlock;
		assert(nblocks <= uint.max);

		auto ptr = alignDown(e.address, BlockSize);
		regionAllocator.release(ptr, nblocks & uint.max);
	}

	/**
	 * Extent and BlockDescriptior allocation.
	 */
	auto getOrAllocateExtent() {
		assert(mutex.isHeld(), "Mutex not held!");

		auto e = unusedExtents.pop();
		if (e !is null) {
			return e;
		}

		{
			mutex.unlock();
			scope(success) mutex.lock();

			auto slot = base.allocSlot();
			if (slot.address is null) {
				goto Exit;
			}

			auto sharedThis = cast(shared(PageFiller)*) &this;
			e = Extent.fromSlot(sharedThis.arena.index, slot);
		}

		unusedExtents.insert(e);

	Exit:
		return unusedExtents.pop();
	}

	/**
	 * GC facilities.
	 */
	struct OutlinedBitmap {
		OutlinedBitmap* next;
		Extent* extent;

		@property
		ulong[] bitmaps() {
			/**
			 * Bitmaps are stored on a page. The OutlinedBitmap lives at
			 * the start of the page, and the bitmaps nimble come next.
			 */
			enum NimbleCount =
				(PageSize - OutlinedBitmap.sizeof) / ulong.sizeof;

			auto ptr = cast(ulong*) (&this + 1);
			return ptr[0 .. NimbleCount];
		}
	}

	ulong[] allocGCBitmap() {
		assert(mutex.isHeld(), "Mutex not held!");

		// Allocate one page.
		bool dirty;
		auto e = allocRunImpl(1, uint.max, ExtentClass.large(), dirty);
		if (unlikely(e is null)) {
			return [];
		}

		if (dirty) {
			import d.gc.memmap;
			pages_zero(e.address, e.size);
		}

		auto ob = cast(OutlinedBitmap*) e.address;
		ob.next = outlinedBitmaps;
		ob.extent = e;

		outlinedBitmaps = ob;
		return ob.bitmaps;
	}

	void prepareGCCycleImpl(ref CachedExtentMap emap) {
		assert(mutex.isHeld(), "Mutex not held!");

		ulong[] bitmaps;

		for (auto r = denseBlocks.range; !r.empty; r.popFront()) {
			auto block = r.front;
			auto bem = emap.blockLookup(block.address);

			uint i = 0;
			while (i < PagesInBlock) {
				i = block.nextAllocatedPage(i);
				if (i >= PagesInBlock) {
					break;
				}

				auto pd = bem.lookup(i);
				auto e = pd.extent;
				assert(e !is null);

				auto ec = pd.extentClass;
				auto sc = ec.sizeClass;

				/**
				 * Because we might not be touching the first half of the Extent,
				 * we make sure we don't take a miss and use binInfos instead.
				 */
				import d.gc.slab;
				i += binInfos[sc].npages;

				import d.gc.sizeclass;
				if (ec.supportsInlineMarking) {
					import d.gc.bitmap;
					auto bmp = cast(Bitmap!128*) &e.slabMetadataMarks;
					bmp.clear();
					continue;
				}

				auto nslots = binInfos[sc].nslots;
				auto nimble = alignUp(nslots, 64) / 64;
				if (bitmaps.length < nimble) {
					bitmaps = allocGCBitmap();
				}

				assert(bitmaps.length >= nimble,
				       "Failed to allocate GC bitmaps.");

				e.outlineMarksBuffer = bitmaps.ptr;
				bitmaps = bitmaps[nimble .. bitmaps.length];
			}
		}
	}

	void collectImpl(ref CachedExtentMap emap, ubyte gcCycle,
	                 bool containsPointers) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto sharedThis = cast(shared(PageFiller)*) &this;
		sharedThis.arena.clearBinsForCollection();

		import d.gc.sizeclass;
		PriorityExtentHeap[BinCount] collectedSlabs;
		auto slabs = collectedSlabs[0 .. BinCount];

		collectDenseAllocations(emap, slabs, containsPointers);
		collectSparseAllocations(emap, slabs, gcCycle, containsPointers);

		sharedThis.arena.combineBinsAfterCollection(collectedSlabs);
	}

	/**
	 * Dense collection.
	 */
	void collectOutlinedBitmaps() {
		assert(mutex.isHeld(), "Mutex not held!");

		auto ob = outlinedBitmaps;
		scope(success) outlinedBitmaps = null;

		while (ob !is null) {
			// We could free and then fetch next, because we are the GC,
			// but I'd rather avoid this kind of tricks.
			auto next = ob.next;
			scope(success) ob = next;

			auto e = ob.extent;
			freePagesImpl(e, e.blockIndex, 1);
		}
	}

	static
	void finalizeSlabNimble(ulong evicted, ulong metadataFlags, int sizeClass,
	                        Extent* e, size_t nimbleIndex) {
		auto toFinalize = evicted & metadataFlags;
		if (toFinalize == 0) {
			return;
		}

		import d.gc.slab;
		auto slotSize = binInfos[sizeClass].slotSize;
		void* nimbleBase = e.address + (nimbleIndex * 64 * slotSize);

		// All set bits in toFinalize have metadata.
		while (toFinalize != 0) {
			auto index = countTrailingZeros(toFinalize);
			void* ptr = nimbleBase + index * slotSize;

			auto metadata = SlotMetadata.fromBlock(ptr, slotSize);
			auto finalizer = metadata.finalizer;
			if (finalizer) {
				import d.gc.hooks;
				__sd_gc_finalize(ptr, slotSize - metadata.freeSpace, finalizer);
			}

			toFinalize &= (toFinalize - 1);
		}

		/**
		 * /!\ This is not atomic. If we want to collect concurrently, we'll
		 *     need to do this atomically. This will do for now.
		 */
		// Clear the metadata of element we collected.
		metadataFlags &= ~evicted;
		e.slabMetadataFlags.rawContent[nimbleIndex] = metadataFlags;
	}

	void collectDenseAllocations(
		ref CachedExtentMap emap,
		PriorityExtentHeap[] slabs,
		bool containsPointers
	) {
		assert(mutex.isHeld(), "Mutex not held!");

		PriorityExtentHeap deadExtents;

		for (auto r = denseBlocks.range; !r.empty; r.popFront()) {
			auto block = r.front;
			auto bem = emap.blockLookup(block.address);

			uint i = 0;
			while (i < PagesInBlock) {
				i = block.nextAllocatedPage(i);
				if (i >= PagesInBlock) {
					break;
				}

				auto pd = bem.lookup(i);
				auto e = pd.extent;
				assert(e !is null);
				assert(e.isSlab());

				auto ec = pd.extentClass;
				auto sc = ec.sizeClass;

				assert(ec.dense);

				auto npages = e.npages;
				i += npages;

				import d.gc.slab;
				auto nslots = binInfos[sc].nslots;
				auto nimble = alignUp(nslots, 64) / 64;

				ulong* bmp = e.getMarksDenseAndClearOutlines();

				assert(bmp !is null);

				uint count = 0;
				ulong occupancyMask = 0;

				import d.gc.bitmap;
				Bitmap!512 toZero;

				foreach (i; 0 .. nimble) {
					auto oldOccupancy = e.slabData.rawContent[i];
					auto newOccupancy = oldOccupancy & bmp[i];

					occupancyMask |= newOccupancy;
					auto evicted = oldOccupancy ^ newOccupancy;
					count += popCount(evicted);
					if (ShouldZeroFreeSlabs && containsPointers) {
						toZero.rawContent[i] = evicted;
					}

					scope(success) e.slabData.rawContent[i] = newOccupancy;

					if (!ec.supportsMetadata) {
						continue;
					}

					auto metadataFlags = e.slabMetadataFlags.rawContent[i];
					finalizeSlabNimble(evicted, metadataFlags, sc, e, i);
				}

				// The slab is empty.
				if (occupancyMask == 0) {
					deadExtents.insert(e);
					continue;
				}

				if (ShouldZeroFreeSlabs && count && containsPointers) {
					// Zero runs of freed slots.
					auto slotSize = binInfos[sc].slotSize;
					uint current, index, length;
					while (current < nslots && toZero
						       .nextOccupiedRange(current, index, length)) {
						memset(e.address + index * slotSize, 0,
						       length * slotSize);
						current = index + length;
					}
				}

				e.bits += count * Extent.FreeSlotsUnit;

				if (e.nfree > 0) {
					slabs[ec.sizeClass].insert(e);
				}
			}
		}

		while (!deadExtents.empty) {
			freeExtentLocked(emap, deadExtents.pop());
		}

		collectOutlinedBitmaps();
		minimizeDense();
	}

	uint minimizeDense() {
		uint n = 0;
		for (auto r = denseBlocks.range; !r.empty; r.popFront()) {
			auto block = r.front;
			n += block.minimize();
		}

		return n;
	}

	/**
	 * Sparse collection.
	 */
	void collectSparseAllocations(
		ref CachedExtentMap emap,
		PriorityExtentHeap[] slabs,
		ubyte gcCycle,
		bool containsPointers
	) {
		assert(mutex.isHeld(), "Mutex not held!");

		PriorityExtentHeap deadExtents;

		for (auto r = sparseBlocks.range; !r.empty; r.popFront()) {
			auto block = r.front;
			auto bem = emap.blockLookup(block.address);

			uint i = 0;
			while (i < PagesInBlock) {
				i = block.nextAllocatedPage(i);
				if (i >= PagesInBlock) {
					break;
				}

				auto pd = bem.lookup(i);
				auto e = pd.extent;
				assert(e !is null, "GC Metadata leftovers?");

				auto npages = e.npages;
				scope(success) i += npages;

				auto ec = pd.extentClass;
				if (ec.isLarge()) {
					// Make sure we handle huge extents correctly.
					npages = modUp(npages, PagesInBlock);

					if (e.isMarkedLarge(gcCycle)) {
						// It's alive.
						continue;
					}

					// We have not marked this extent this cycle.
					auto f = e.finalizer;
					if (f !is null) {
						import d.gc.hooks;
						__sd_gc_finalize(e.address, e.usedCapacity, f);
					}

					deadExtents.insert(e);
					continue;
				}

				auto markBits = e.getMarksSparse(gcCycle);

				auto metadataFlags = e.slabMetadataFlags.rawContent[0];

				// If completely empty and no metadata exists,
				// we can short circuit here.
				if (markBits == 0 && metadataFlags == 0) {
					deadExtents.insert(e);
					continue;
				}

				auto oldOccupancy = e.slabData.rawContent[0];
				auto newOccupancy = oldOccupancy & markBits;
				auto evicted = oldOccupancy ^ newOccupancy;

				// Call any finalizers on dying slots.
				finalizeSlabNimble(evicted, metadataFlags, ec.sizeClass, e, 0);

				// The slab is empty.
				if (newOccupancy == 0) {
					deadExtents.insert(e);
					continue;
				}

				// Clear any dead slots if they might contain pointers.
				if (ShouldZeroFreeSlabs && containsPointers && evicted != 0) {
					import d.gc.bitmap;
					Bitmap!64 toZero;
					toZero.rawContent[0] = evicted;
					import d.gc.slab;
					auto slotSize = binInfos[ec.sizeClass].slotSize;
					uint current, index, length;
					while (current < 64 && toZero
						       .nextOccupiedRange(current, index, length)) {
						memset(e.address + index * slotSize, 0,
						       length * slotSize);
						current = index + length;
					}
				}

				auto count = popCount(evicted);

				e.slabData.rawContent[0] = newOccupancy;
				e.bits += count * Extent.FreeSlotsUnit;

				if (e.nfree > 0) {
					slabs[ec.sizeClass].insert(e);
				}
			}
		}

		while (!deadExtents.empty) {
			freeExtentLocked(emap, deadExtents.pop());
		}

		minimizeSparse();
	}

	uint minimizeSparse() {
		uint n = 0;
		for (auto r = sparseBlocks.range; !r.empty; r.popFront()) {
			auto block = r.front;
			n += block.minimize();
		}

		return n;
	}

	void freeExtentLocked(ref CachedExtentMap emap, Extent* e) {
		assert(isAligned(e.address, PageSize), "Invalid extent address!");

		emap.clear(e);

		uint n = e.blockIndex;
		uint pages = modUp(e.npages, PagesInBlock);

		(cast(PageFiller*) &this).freePagesImpl(e, n, pages);
	}
}

unittest allocPages {
	import d.gc.arena;
	shared Arena arena;

	auto base = &arena.base;
	scope(exit) arena.base.clear();

	import d.gc.region;
	shared RegionAllocator regionAllocator;
	regionAllocator.base = base;

	auto filler = &arena.filler;
	filler.regionAllocator = &regionAllocator;

	size_t expectedUsedPages = 0;

	void checkFreePages(Extent* e) {
		filler.freePages(e);
		expectedUsedPages -= e.npages;
		assert(filler.usedPages == expectedUsedPages);
	}

	auto checkAllocPage(uint pages, bool clean) {
		bool dirty;
		auto e = filler.allocPages(pages, dirty);

		assert(e !is null);
		assert(e.npages == pages);
		assert(dirty == !clean);

		expectedUsedPages += pages;
		assert(filler.usedPages == expectedUsedPages);

		return e;
	}

	auto e0 = checkAllocPage(1, true);
	auto e1 = checkAllocPage(2, true);
	assert(e1.address is e0.address + e0.size);

	auto e0Addr = e0.address;
	checkFreePages(e0);

	// Do not reuse the free slot is there is no room.
	auto e2 = checkAllocPage(3, true);
	assert(e2.address is e1.address + e1.size);

	// But do reuse that free slot if there isn't.
	auto e3 = checkAllocPage(1, false);
	assert(e3.address is e0Addr);

	// Free everything.
	checkFreePages(e1);
	checkFreePages(e2);
	checkFreePages(e3);

	// Check a wide range of sizes.
	foreach (pages; 1 .. 2 * PagesInBlock) {
		auto e = checkAllocPage(pages, true);
		checkFreePages(e);
	}
}

unittest allocHuge {
	import d.gc.arena;
	shared Arena arena;

	auto base = &arena.base;
	scope(exit) arena.base.clear();

	import d.gc.region;
	shared RegionAllocator regionAllocator;
	regionAllocator.base = base;

	auto filler = &arena.filler;
	filler.regionAllocator = &regionAllocator;

	size_t expectedUsedPages = 0;

	void checkFreePages(Extent* e) {
		filler.freePages(e);
		expectedUsedPages -= e.npages;
		assert(filler.usedPages == expectedUsedPages);
	}

	auto checkAllocPage(uint pages, bool clean, bool huge) {
		bool dirty;
		auto e = filler.allocPages(pages, dirty);

		assert(e !is null);
		assert(e.npages == pages);
		assert(dirty == !clean);

		expectedUsedPages += pages;
		assert(filler.usedPages == expectedUsedPages);

		assert(e.isHuge() == huge);
		return e;
	}

	enum uint AllocSize = PagesInBlock + 1;

	// Allocate a huge extent.
	auto e0 = checkAllocPage(AllocSize, true, true);

	// Free the huge extent.
	auto e0Addr = e0.address;
	checkFreePages(e0);

	// Reallocating the same run will yield the same memory back.
	e0 = checkAllocPage(AllocSize, true, true);
	assert(e0.address is e0Addr);

	// Allocate one page on the borrowed block.
	auto e1 = checkAllocPage(1, true, false);
	assert(e1.address is e0.address + e0.size);

	// Now, freeing the huge extent will leave a page behind.
	checkFreePages(e0);

	// Allocating another huge extent will use a new range.
	auto e2 = checkAllocPage(AllocSize, true, true);
	assert(e2.address is alignUp(e1.address, BlockSize));

	// Allocating new small extents fill the borrowed page.
	auto e3 = checkAllocPage(1, false, false);
	assert(e3.address is alignDown(e1.address, BlockSize));

	// But allocating just the right size will reuse the region.
	auto e4 = checkAllocPage(PagesInBlock, true, true);
	assert(e4.address is e0Addr);

	// Free everything.
	checkFreePages(e1);
	checkFreePages(e2);
	checkFreePages(e3);
	checkFreePages(e4);

	// Check boundaries.
	auto e5 = checkAllocPage(MaxPagesInLargeAlloc, true, false);
	auto e6 = checkAllocPage(MaxPagesInLargeAlloc + 1, true, true);

	checkFreePages(e5);
	checkFreePages(e6);
}
