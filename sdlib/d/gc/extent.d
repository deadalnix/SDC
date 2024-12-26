module d.gc.extent;

import d.sync.atomic;

import d.gc.base;
import d.gc.bitmap;
import d.gc.heap;
import d.gc.sizeclass;
import d.gc.spec;
import d.gc.util;

struct ExtentClass {
	ubyte data;

	this(ubyte data) {
		this.data = data;
	}

	enum Mask = (1 << 6) - 1;

	import d.gc.sizeclass;
	static assert((ClassCount.Small & ~Mask) == 0,
	              "ExtentClass doesn't fit on 6 bits!");

	static large() {
		return ExtentClass(0);
	}

	static slab(ubyte sizeClass) {
		// FIXME: in contract.
		assert(sizeClass < ClassCount.Small, "Invalid size class!");

		sizeClass += 1;
		return ExtentClass(sizeClass);
	}

	bool isSlab() const {
		return data != 0;
	}

	bool isLarge() const {
		return data == 0;
	}

	@property
	ubyte sizeClass() const {
		// FIXME: in contract.
		assert(isSlab(), "Non slab do not have a size class!");
		return (data - 1) & ubyte.max;
	}

	@property
	bool dense() const {
		enum Sieve = 1 << 0 | 1 << 16 | 1 << 20 | 1 << 22;
		auto match = Sieve & (1 << data);
		return !match && data < 24;
	}

	@property
	bool sparse() const {
		return !dense;
	}

	@property
	bool supportsMetadata() const {
		return data != 1;
	}

	@property
	bool supportsInlineMarking() const {
		return uint(data - 1) > 2;
	}
}

unittest ExtentClass {
	auto l = ExtentClass.large();
	assert(!l.isSlab());
	assert(l.isLarge());
	assert(!l.dense);
	assert(l.sparse);
	assert(l.supportsMetadata);
	assert(l.supportsInlineMarking);

	foreach (ubyte sc; 0 .. ClassCount.Small) {
		auto s = ExtentClass.slab(sc);
		assert(s.isSlab());
		assert(!s.isLarge());
		assert(s.sizeClass == sc);

		assert(s.dense == isDenseSizeClass(sc));
		assert(s.sparse == isSparseSizeClass(sc));
		assert(s.supportsMetadata == sizeClassSupportsMetadata(sc));
		assert(s.supportsInlineMarking == sizeClassSupportsInlineMarking(sc));
	}
}

struct Extent {
private:
	/**
	 * This is a bitfield containing the following elements:
	 *  - n: The number of free slots.
	 *  - p: The address of the memory managed by Extent.
	 *  - a: The arena index.
	 * 
	 * 63    56 55    48 47    40 39    32 31    24 23    16 15     8 7      0
	 * nnnnnnnn nnnnnnnn pppppppp pppppppp pppppppp pppppppp ppppaaaa aaaaaaaa
	 */
	ulong bits;

	// Verify our assumptions.
	static assert(LgAddressSpace <= 48, "Address space too large!");
	static assert(LgPageSize >= LgArenaCount, "Not enough space in low bits!");

	// Useful constants for bit manipulations.
	enum FreeSlotsIndex = 48;
	enum FreeSlotsUnit = 1UL << FreeSlotsIndex;

public:
	uint _npages;
	ExtentClass extentClass;
	ubyte generation;

	import d.gc.block;
	BlockDescriptor* block;

private:
	Node!Extent _phnode;

	/**
	 * The GC metadata field can be interpreted in a couple of ways depending
	 * on the allocation type:
	 *  - For dense slabs, if the bit fields do not fit inline in the Extent,
	 *    we allocate a buffer for the bitmap and we store a pointer to that
	 *    buffer here.
	 *  - For large allocations, we store the GC cycle in this field when marking.
	 *  - For sparse slabs, we store the GC cycle in the lower 8 bits, and turn
	 *    the higher bits into a bitfield. If the GC cycle is incorrect, then the
	 *    bitfield can be ignored.
	 * 
	 * Using the GC cycle ensures that we do not need to cleanup in between cycles.
	 * The leftover data are known to be outdated.
	 */
	union GCMetadata {
		ulong* outlineBuffer;
		shared(Bitmap!512)* outlineBitmap;
		shared Atomic!ulong gcWord;
	}

	GCMetadata _gcMetadata;

	// TODO: Reuse this data to do something useful,
	// like garbage collection :P
	void* _pad1;

	/**
	 * When this is a slab, the second part of the Extent is made
	 * of various bitfields that are interpreted differently depending
	 * on the number of slots in the slab as follow:
	 *  - b: Whether the slot is allocated.
	 *  - f: Whether the slot has metadata.
	 *  - m: Mark bits for the GC.
	 * 
	 *      0      128      256              512
	 * 512: bbbbbbbb bbbbbbbb bbbbbbbb bbbbbbbb
	 * 256: bbbbbbbb bbbbbbbb ffffffff ffffffff
	 * 128: bbbbbbbb mmmmmmmm ffffffff ........
	 * 
	 * When a metadata flag is required, but no space is available for
	 * them in the bitfields, we expect the GC to use the next size class.
	 * 
	 * When mark bits are required, but no space is available for them
	 * a bitfield is allocated on the heap, and a pointer to it is stored
	 * in the GC metadata.
	 * 
	 * When this is a large allocation, we store whether the allocation
	 * has metadata, and if there is a one, a pointer to the finalizer.
	 * 
	 * FIXME: When considering this bitfield and the GC metadata, we have a
	 *        640 bits budget to play with. Size class 2 contains 170 slots,
	 *        but currently does not support marking inline. However, even
	 *        rounding up to the closest multiple of 64 bits, 192, we only
	 *        need 576 bits to store occupancy, metatadat flags and mark bits.
	 *        The data layout would benefit from being reworked as to allow
	 *        size class 2 to be marked inline.
	 */
	struct SlabMetadata {
		ulong[2] pad;
		shared Bitmap!128 marks;
		shared Bitmap!256 flags;
	}

	union Bitmaps {
		Bitmap!512 slabData;
		SlabMetadata slabMetadata;
	}

	struct LargeData {
		// Metadata for large extents.
		size_t usedCapacity;

		// Optional finalizer.
		Finalizer finalizer;
	}

	union Metadata {
		// Slab occupancy (and metadata flags for supported size classes)
		Bitmaps slabData;

		// Metadata for large extents.
		LargeData largeData;
	}

	Metadata _metadata;

	this(uint arenaIndex, void* ptr, uint npages, ubyte generation,
	     BlockDescriptor* block, ExtentClass extentClass) {
		// FIXME: in contract.
		assert((arenaIndex & ~ArenaMask) == 0, "Invalid arena index!");
		assert(isAligned(ptr, PageSize), "Invalid alignment!");

		this.bits = arenaIndex | cast(size_t) ptr;

		this._npages = npages;
		this.extentClass = extentClass;
		this.generation = generation;
		this.block = block;

		if (extentClass.isSlab()) {
			import d.gc.slab;
			bits |= ulong(nslots) << FreeSlotsIndex;

			slabData.clear();
		} else {
			setUsedCapacity(size);
			setFinalizer(null);
		}
	}

public:
	Extent* at(void* ptr, uint npages, BlockDescriptor* block,
	           ExtentClass extentClass) {
		this = Extent(arenaIndex, ptr, npages, generation, block, extentClass);
		return &this;
	}

	Extent* at(void* ptr, uint npages, BlockDescriptor* block) {
		return at(ptr, npages, block, ExtentClass.large());
	}

	Extent* growBy(uint delta) {
		assert(isLarge(), "Only large extents can be resized!");

		import d.gc.size;
		assert(
			!isHugePageCount(npages + delta) || isAligned(address, BlockSize),
			"Huge extents must be block aligned!"
		);

		this._npages += delta;
		return &this;
	}

	Extent* shrinkBy(uint delta) {
		assert(isLarge(), "Only large extents can be resized!");
		assert(delta < npages, "Invalid delta!");

		this._npages -= delta;

		import d.gc.util;
		setUsedCapacity(min(usedCapacity, size));

		return &this;
	}

	static fromSlot(uint arenaIndex, GenerationPointer slot) {
		// FIXME: in contract
		assert((arenaIndex & ~ArenaMask) == 0, "Invalid arena index!");
		assert(slot.address !is null, "Slot is empty!");
		assert(isAligned(slot.address, ExtentAlign), "Invalid slot alignment!");

		auto e = cast(Extent*) slot.address;
		e.bits = arenaIndex;
		e.generation = slot.generation;

		return e;
	}

	@property
	void* address() const {
		return cast(void*) (bits & PagePointerMask);
	}

	@property
	size_t size() const {
		return npages * PageSize;
	}

	@property
	uint npages() const {
		return _npages;
	}

	bool isHuge() const {
		import d.gc.size;
		return isHugePageCount(npages);
	}

	@property
	uint blockIndex() const {
		assert(isHuge() || block.address is alignDown(address, BlockSize));
		assert(!isHuge() || isAligned(address, BlockSize));

		return ((cast(size_t) address) / PageSize) % PagesInBlock;
	}

	@property
	ref Node!Extent phnode() {
		return _phnode;
	}

	bool contains(const void* ptr) const {
		return ptr >= address && ptr < address + size;
	}

	/**
	 * Arena.
	 */
	@property
	uint arenaIndex() const {
		return bits & ArenaMask;
	}

	@property
	bool containsPointers() const {
		return (arenaIndex & 0x01) != 0;
	}

	/**
	 * Slab features.
	 */
	bool isSlab() const {
		return extentClass.isSlab();
	}

	@property
	uint nslots() const {
		assert(isSlab(), "nslots accessed on non slab!");

		import d.gc.slab;
		return binInfos[extentClass.sizeClass].nslots;
	}

	@property
	uint nfree() const {
		// FIXME: in contract.
		assert(isSlab(), "nfree accessed on non slab!");

		enum Mask = (1 << 10) - 1;
		return (bits >> FreeSlotsIndex) & Mask;
	}

	void** batchAllocate(void** insert, uint nfill, size_t slotSize) {
		// FIXME: in contract.
		assert(isSlab(), "allocate accessed on non slab!");
		assert(nfree > 0, "Slab is full!");

		// Make sure we do not try to fill more slots than we have.
		nfill = min(nfill, nfree);

		uint total = nfill;
		uint n = -1;
		ulong nimble = 0;
		ulong current = 0;

		while (nfill > 0) {
			while (current == 0) {
				nimble = slabData.rawContent[++n];
				current = ~nimble;
			}

			enum NimbleSize = 8 * ulong.sizeof;
			auto shift = n * NimbleSize;

			import sdc.intrinsics;
			uint count = popCount(current);
			count = min(count, nfill);

			foreach (_; 0 .. count) {
				import sdc.intrinsics;
				auto bit = countTrailingZeros(current);
				current ^= 1UL << bit;

				auto slot = shift + bit;
				*(insert++) = address + slot * slotSize;
			}

			slabData.rawContent[n] = ~current;
			nfill -= count;
		}

		assert(nfill == 0);
		bits -= total * FreeSlotsUnit;
		return insert;
	}

	void free(uint index) {
		// FIXME: in contract.
		assert(isSlab(), "free accessed on non slab!");
		assert(slabData.valueAt(index), "Slot is already free!");

		bits += FreeSlotsUnit;
		slabData.clearBit(index);
	}

	/**
	 * Metadata features for slabs.
	 */
	@property
	ref Bitmap!512 slabData() {
		// FIXME: in contract.
		assert(isSlab(), "slabData accessed on non slab!");

		return _metadata.slabData.slabData;
	}

	@property
	ref shared(Bitmap!256) slabMetadataFlags() {
		assert(extentClass.supportsMetadata,
		       "size class not supports slab metadata!");

		return _metadata.slabData.slabMetadata.flags;
	}

	bool hasMetadata(uint index) {
		assert(extentClass.supportsMetadata,
		       "size class not supports slab metadata!");
		assert(index < nslots, "index is out of range!");

		return slabMetadataFlags.valueAtAtomic(index);
	}

	void enableMetadata(uint index) {
		assert(extentClass.supportsMetadata,
		       "size class not supports slab metadata!");
		assert(index < nslots, "index is out of range!");

		slabMetadataFlags.setBitAtomic(index);
	}

	void disableMetadata(uint index) {
		assert(extentClass.supportsMetadata,
		       "size class not supports slab metadata!");
		assert(index < nslots, "index is out of range!");

		slabMetadataFlags.clearBitAtomic(index);
	}

	@property
	ref shared(Bitmap!128) slabMetadataMarks() {
		assert(extentClass.dense, "size class not dense!");
		assert(extentClass.supportsInlineMarking,
		       "size class not supports inline marking!");

		return _metadata.slabData.slabMetadata.marks;
	}

	@property
	ref ulong* outlineMarksBuffer() {
		assert(extentClass.dense, "size class not dense!");
		assert(!extentClass.supportsInlineMarking,
		       "size class supports inline marking!");

		return _gcMetadata.outlineBuffer;
	}

	@property
	ref shared(Bitmap!512) outlineMarks() {
		assert(extentClass.dense, "size class not dense!");
		assert(!extentClass.supportsInlineMarking,
		       "size class supports inline marking!");

		return *_gcMetadata.outlineBitmap;
	}

	bool markSparseSlot(ubyte gcCycle, uint index) {
		assert(extentClass.sparse, "size class not sparse!");
		assert(!isLarge(), "size class large!");
		auto bit = 0x100 << index;

		auto old = gcWord.load();
		while ((old & 0xff) != gcCycle) {
			if (gcWord.casWeak(old, gcCycle | bit)) {
				return true;
			}
		}

		if (old & bit) {
			return false;
		}

		old = gcWord.fetchOr(bit);
		return (old & bit) == 0;
	}

	bool markLarge(ubyte gcCycle) {
		assert(isLarge(), "size class not large!");
		auto old = gcWord.load();
		while (true) {
			if (old == gcCycle) {
				return false;
			}

			if (gcWord.casWeak(old, gcCycle)) {
				return true;
			}
		}
	}

	bool markDenseSlot(uint index) {
		assert(extentClass.dense, "size class not dense!");
		if (extentClass.supportsInlineMarking) {
			return !slabMetadataMarks.setBitAtomic(index);
		}

		auto bmp = &outlineMarks;
		return bmp !is null && !bmp.setBitAtomic(index);
	}

	ulong getMarksSparse(ubyte gcCycle) {
		assert(extentClass.sparse, "Size class not sparse!");
		assert(!isLarge(), "Size class large!");

		auto w = gcWord.load();
		auto markCycle = w & 0xff;
		if (markCycle == gcCycle) {
			return w >> 8;
		}

		return 0;
	}

	bool isMarkedLarge(ubyte gcCycle) {
		assert(isLarge(), "Size class not large!");

		return gcCycle == gcWord.load();
	}

	ulong* getMarksDenseAndClearOutlines() {
		return getMarksDenseImpl!true();
	}

	ulong* getMarksDense() {
		return getMarksDenseImpl!false();
	}

	@property
	ref shared(Atomic!ulong) gcWord() {
		assert(extentClass.sparse, "size class not sparse!");

		return _gcMetadata.gcWord;
	}

	/**
	 * Large features.
	 */
	bool isLarge() const {
		return extentClass.isLarge();
	}

	@property
	size_t usedCapacity() {
		assert(isLarge(), "usedCapacity accessed on non large!");
		return _metadata.largeData.usedCapacity;
	}

	void setUsedCapacity(size_t size) {
		assert(isLarge(), "Cannot set used capacity on a slab alloc!");
		_metadata.largeData.usedCapacity = size;
	}

	@property
	Finalizer finalizer() {
		assert(isLarge(), "Finalizer accessed on non large!");
		return _metadata.largeData.finalizer;
	}

	void setFinalizer(Finalizer finalizer) {
		assert(isLarge(), "Cannot set finalizer on a slab alloc!");
		_metadata.largeData.finalizer = finalizer;
	}

private:

	ulong* getMarksDenseImpl(bool clearOutlines)() {
		assert(extentClass.dense, "Size class not dense!");
		if (extentClass.supportsInlineMarking) {
			return cast(ulong*) &slabMetadataMarks;
		}

		auto bmp = outlineMarksBuffer;
		if (clearOutlines) {
			outlineMarksBuffer = null;
		}

		return bmp;
	}
}

unittest finalizers {
	static void destruct(void* ptr, size_t size) {}

	Extent e;

	enum PageCount = 5;
	ubyte[(PageCount + 1) * PageSize] buffer;

	// Make sure we are page alligned.
	auto ptr = alignUp(buffer.ptr, PageSize);
	e.at(ptr, PageCount, null);

	assert(e.finalizer is null);
	assert(e.usedCapacity == 20480);

	e.setUsedCapacity(20000);
	assert(e.finalizer is null);
	assert(e.usedCapacity == 20000);

	e.setFinalizer(destruct);
	assert(cast(void*) e.finalizer is cast(void*) destruct);
	assert(e.usedCapacity == 20000);

	e.setUsedCapacity(20400);
	assert(cast(void*) e.finalizer is cast(void*) destruct);
	assert(e.usedCapacity == 20400);
}

static assert(Extent.sizeof == ExtentSize, "Unexpected Extent size!");
static assert(Extent.sizeof == ExtentAlign, "Unexpected Extent alignment!");

alias PriorityExtentHeap = Heap!(Extent, priorityExtentCmp);

/**
 * FIXME: We don't want to take into account the number of free slots
 *        when prioritizing extents. This forces many heaps manipulations
 *        in the bins for dubious benefits.
 *        A better approach would be to prefers older slabs/blocks, which
 *        are more likely to contain "immortal" elements, and discriminate
 *        on address to tie break.
 * 
 * Note:
 * This used to use the bits in the Extent, but now we simply use the address.
 * This works, contrary to the previous approach which could lead to heap
 * corruption, but still not idea. We probably want to target older blocks.
 */
ptrdiff_t priorityExtentCmp(Extent* lhs, Extent* rhs) {
	auto l = cast(size_t) lhs.address;
	auto r = cast(size_t) rhs.address;

	return (l > r) - (l < r);
}

unittest priority {
	static makeExtent(void* address, uint nalloc) {
		Extent e;
		e.at(address, 1, null, ExtentClass.slab(0));
		e.bits -= nalloc * Extent.FreeSlotsUnit;

		assert(e.address is address);
		assert(e.nfree == (512 - nalloc));
		return e;
	}

	PriorityExtentHeap heap;
	assert(heap.top is null);

	auto minPtr = cast(void*) PageSize;
	auto midPtr = cast(void*) BlockSize;
	auto maxPtr = cast(void*) (AddressSpace - PageSize);

	// Lowest priority slab possible.
	auto e0 = makeExtent(maxPtr, 0);
	heap.insert(&e0);
	assert(heap.top is &e0);

	// Lower address is better.
	auto e1 = makeExtent(null, 0);
	heap.insert(&e1);
	assert(heap.top is &e1);

	/**
	 * FIXME: The tests here were based on the use of bits.
	 *        This can lead to corruption, but simply using
	 *        the address is not satisfactory.
	 *        The test was left commented as example of what
	 *        the test for a proper implementation of this
	 *        function could look like.
	 */
	/+
	// But more allocations is even better!
	auto e2 = makeExtent(maxPtr, 500);
	heap.insert(&e2);
	assert(heap.top is &e2);

	// Lower address remains a tie breaker.
	auto e3 = makeExtent(null, 500);
	heap.insert(&e3);
	assert(heap.top is &e3);

	// Try inserting a few blocks out of order.
	auto e4 = makeExtent(midPtr + PageSize, 500);
	auto e5 = makeExtent(maxPtr - PageSize, 250);
	auto e6 = makeExtent(midPtr, 250);
	auto e7 = makeExtent(midPtr, 400);
	heap.insert(&e4);
	heap.insert(&e5);
	heap.insert(&e6);
	heap.insert(&e7);

	// Pop all the blocks and check they come out in
	// the expected order.
	assert(heap.pop() is &e3);
	assert(heap.pop() is &e4);
	assert(heap.pop() is &e2);
	assert(heap.pop() is &e7);
	assert(heap.pop() is &e6);
	assert(heap.pop() is &e5);
	assert(heap.pop() is &e1);
	assert(heap.pop() is &e0);
	assert(heap.pop() is null);
	// +/
}

alias UnusedExtentHeap = Heap!(Extent, unusedExtentCmp);

ptrdiff_t unusedExtentCmp(Extent* lhs, Extent* rhs) {
	static assert(LgAddressSpace <= 56, "Address space too large!");

	auto l = ulong(lhs.generation) << 56;
	auto r = ulong(rhs.generation) << 56;

	l |= cast(size_t) lhs;
	r |= cast(size_t) rhs;

	return (l > r) - (l < r);
}

unittest contains {
	auto base = cast(void*) 0x56789abcd000;
	enum Pages = 13;
	enum Size = Pages * PageSize;

	Extent e;
	e.at(base, Pages, null);

	assert(!e.contains(base - 1));
	assert(!e.contains(base + Size));

	foreach (i; 0 .. Size) {
		assert(e.contains(base + i));
	}
}

unittest allocfree {
	Extent e;
	e.at(null, 1, null, ExtentClass.slab(0));

	static checkAllocate(ref Extent e, uint index) {
		void*[1] buffer;
		auto insert = e.batchAllocate(buffer.ptr, 1, PointerSize);
		assert(insert is buffer.ptr + 1);

		auto expected = index * PointerSize;
		auto provided = cast(size_t) buffer[0];

		assert(provided == expected);
	}

	assert(e.isSlab());
	assert(e.extentClass.sizeClass == 0);
	assert(e.nfree == 512);

	checkAllocate(e, 0);
	assert(e.nfree == 511);

	checkAllocate(e, 1);
	assert(e.nfree == 510);

	checkAllocate(e, 2);
	assert(e.nfree == 509);

	e.free(1);
	assert(e.nfree == 510);

	checkAllocate(e, 1);
	assert(e.nfree == 509);

	checkAllocate(e, 3);
	assert(e.nfree == 508);

	e.free(0);
	e.free(3);
	e.free(2);
	e.free(1);
	assert(e.nfree == 512);
}

unittest batchAllocate {
	Extent e;
	e.at(null, 1, null, ExtentClass.slab(0));

	void*[1025] buffer = void;

	auto checkBatchAllocate(void** bottom, uint nfill, uint eCount,
	                        uint preFree, uint postFree) {
		auto sentinel = cast(void*) 0xa5a5deadbeef5a5a;

		auto top = bottom + nfill;
		*top = sentinel;

		assert(e.nfree == preFree);

		auto insert = e.batchAllocate(bottom, nfill, PointerSize);
		assert(*top is sentinel);

		auto count = insert - bottom;
		assert(count == eCount);
		assert(e.nfree == postFree);
	}

	checkBatchAllocate(buffer.ptr, 1024, 512, 512, 0);
	foreach (i; 0 .. 512) {
		assert(i * PointerSize == cast(size_t) buffer[i]);
	}

	// Free half the elements.
	foreach (i; 0 .. 256) {
		e.free(2 * i);
	}

	checkBatchAllocate(buffer.ptr, 512, 256, 256, 0);
	foreach (i; 0 .. 256) {
		assert(2 * i * PointerSize == cast(size_t) buffer[i]);
	}

	// Free All the element but two in the middle
	foreach (i; 0 .. 255) {
		e.free(i);
		e.free(511 - i);
	}

	checkBatchAllocate(buffer.ptr, 500, 500, 510, 10);

	foreach (i; 0 .. 255) {
		assert(i * PointerSize == cast(size_t) buffer[i]);
	}

	foreach (i; 255 .. 500) {
		assert((i + 2) * PointerSize == cast(size_t) buffer[i]);
	}
}
