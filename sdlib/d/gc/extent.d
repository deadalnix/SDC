module d.gc.extent;

import d.gc.base;
import d.gc.heap;
import d.gc.rbtree;
import d.gc.sizeclass;
import d.gc.spec;
import d.gc.util;

alias ExtentTree = RBTree!(Extent, addrRangeExtentCmp);

alias PHNode = heap.Node!Extent;
alias RBNode = rbtree.Node!Extent;

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

	@property
	ubyte sizeClass() const {
		// FIXME: in contract.
		assert(isSlab(), "Non slab do not have a size class!");
		return (data - 1) & ubyte.max;
	}
}

unittest ExtentClass {
	auto l = ExtentClass.large();
	assert(!l.isSlab());

	auto s0 = ExtentClass.slab(0);
	assert(s0.isSlab());
	assert(s0.sizeClass == 0);

	auto s9 = ExtentClass.slab(9);
	assert(s9.isSlab());
	assert(s9.sizeClass == 9);

	auto smax = ExtentClass.slab(ClassCount.Small - 1);
	assert(smax.isSlab());
	assert(smax.sizeClass == ClassCount.Small - 1);
}

struct Extent {
private:
	/**
	 * This is a bitfield containing the following elements:
	 *  - e: The extent class.
	 *  - a: The arena index.
	 *  - n: The number of free slots.
	 * 
	 * 63    56 55    48 47    40 39    32 31    24 23    16 15     8 7      0
	 * nnnnnnnn nnnnnnnn ....aaaa aaaaaaaa ........ ........ ........ ..eeeeee
	 */
	ulong bits;

public:
	void* address;
	size_t sizeAndGen;

	import d.gc.hpd;
	HugePageDescriptor* hpd;

private:
	// TODO: Reuse this data to do something useful,
	// like garbage collection :P
	void* _pad;

	union Links {
		PHNode phnode;
		RBNode rbnode;
	}

	Links _links;

	// The largest slab slot count which allows freespace flags:
	enum maxFreeSpaceFlags = 256;

	// The largest slab slot count which allows finalizer flags:
	enum maxFinalizerFlags = 128;

	struct LargeData {
		size_t usedCapacity;
		void* finalizer;
	}

	import d.gc.bitmap;
	union MetaData {
		// Slab occupancy (and freespace flags for supported size classes.)
		Bitmap!512 slabData;

		// Metadata for large extents.
		LargeData largeData;
	}

	MetaData _metadata;

	this(uint arenaIndex, void* ptr, size_t size, ubyte generation,
	     HugePageDescriptor* hpd, ExtentClass ec) {
		// FIXME: in contract.
		assert((arenaIndex & ~ArenaMask) == 0, "Invalid arena index!");
		assert(isAligned(ptr, PageSize), "Invalid alignment!");
		assert(isAligned(size, PageSize), "Invalid size!");

		this.address = ptr;
		this.sizeAndGen = size | generation;
		this.hpd = hpd;

		bits = ec.data;
		bits |= ulong(arenaIndex) << 32;

		if (ec.isSlab()) {
			import d.gc.bin;
			bits |= ulong(binInfos[ec.sizeClass].slots) << 48;

			slabData.clear();
		} else {
			setUsedCapacity(size);
			setFinalizer(null);
		}
	}

public:
	Extent* at(void* ptr, size_t size, HugePageDescriptor* hpd,
	           ExtentClass ec) {
		this = Extent(arenaIndex, ptr, size, generation, hpd, ec);
		return &this;
	}

	Extent* at(void* ptr, size_t size, HugePageDescriptor* hpd) {
		return at(ptr, size, hpd, ExtentClass.large());
	}

	static fromSlot(uint arenaIndex, Base.Slot slot) {
		// FIXME: in contract
		assert((arenaIndex & ~ArenaMask) == 0, "Invalid arena index!");
		assert(slot.address !is null, "Slot is empty!");
		assert(isAligned(slot.address, ExtentAlign),
		       "Invalid slot alignement!");

		auto e = cast(Extent*) slot.address;
		e.bits = ulong(arenaIndex) << 32;
		e.sizeAndGen = slot.generation;

		return e;
	}

	@property
	size_t size() const {
		return sizeAndGen & ~PageMask;
	}

	bool isHuge() const {
		return size > HugePageSize;
	}

	@property
	ubyte generation() const {
		return sizeAndGen & 0xff;
	}

	@property
	ref PHNode phnode() {
		return _links.phnode;
	}

	@property
	ref RBNode rbnode() {
		return _links.rbnode;
	}

	bool contains(void* ptr) const {
		return ptr >= address && ptr < address + size;
	}

	/**
	 * Arena.
	 */
	@property
	uint arenaIndex() const {
		return (bits >> 32) & ArenaMask;
	}

	@property
	bool containsPointers() const {
		return (arenaIndex & 0x01) != 0;
	}

	/**
	 * Slab features.
	 */
	@property
	auto extentClass() const {
		return ExtentClass(bits & ExtentClass.Mask);
	}

	bool isSlab() const {
		auto ec = extentClass;
		return ec.isSlab();
	}

	@property
	ubyte sizeClass() const {
		auto ec = extentClass;
		return ec.sizeClass;
	}

	@property
	uint freeSlots() const {
		// FIXME: in contract.
		assert(isSlab(), "freeSlots accessed on non slab!");

		enum Mask = (1 << 10) - 1;
		return (bits >> 48) & Mask;
	}

	uint allocate() {
		// FIXME: in contract.
		assert(isSlab(), "allocate accessed on non slab!");
		assert(freeSlots > 0, "Slab is full!");

		scope(success) bits -= (1UL << 48);
		return slabData.setFirst();
	}

	void free(uint index) {
		// FIXME: in contract.
		assert(isSlab(), "free accessed on non slab!");
		assert(slabData.valueAt(index), "Slot is already free!");

		bits += (1UL << 48);
		slabData.clearBit(index);
	}

	@property
	ref Bitmap!512 slabData() {
		// FIXME: in contract.
		assert(isSlab(), "slabData accessed on non slab!");

		return _metadata.slabData;
	}

	/**
	 * Freespace Flag features for slabs.
	 */

	@property
	bool allowsFreeSpace() const {
		return isSlab() && isAppendableSizeClass(sizeClass);
	}

	uint freeSpaceIndex(uint index) {
		assert(index < maxFreeSpaceFlags, "Invalid freespace flag index!");
		return index + maxFreeSpaceFlags;
	}

	bool hasFreeSpace(uint index) {
		// FIXME: atomic
		return allowsFreeSpace && slabData.valueAt(freeSpaceIndex(index));
	}

	void clearFreeSpace(uint index) {
		// FIXME: atomic
		slabData.clearBit(freeSpaceIndex(index));
	}

	void setFreeSpace(uint index) {
		// FIXME: atomic
		slabData.setBit(freeSpaceIndex(index));
	}

	/**
	 * Finalizer Flag features for slabs.
	 */

	@property
	bool allowsFinalized() const {
		return isSlab() && isFinalizableSizeClass(sizeClass);
	}

	uint finalizedIndex(uint index) {
		assert(index < maxFinalizerFlags, "Invalid finalizer flag index!");
		return index + maxFinalizerFlags;
	}

	bool hasFinalized(uint index) {
		// FIXME: atomic
		return allowsFinalized && slabData.valueAt(finalizedIndex(index));
	}

	void clearFinalized(uint index) {
		// FIXME: atomic
		slabData.clearBit(finalizedIndex(index));
	}

	void setFinalized(uint index) {
		// FIXME: atomic
		slabData.setBit(finalizedIndex(index));
	}

	/**
	 * Large features.
	 */
	bool isLarge() const {
		return !isSlab();
	}

	@property
	ulong usedCapacity() {
		assert(isLarge(), "usedCapacity accessed on non large!");
		return _metadata.largeData.usedCapacity;
	}

	void setUsedCapacity(size_t size) {
		assert(isLarge(), "Cannot set used capacity on a slab alloc!");
		_metadata.largeData.usedCapacity = size;
	}

	@property
	void* finalizer() {
		assert(isLarge(), "finalizer accessed on non large!");
		return _metadata.largeData.finalizer;
	}

	void setFinalizer(void* finalizer) {
		assert(isLarge(), "Cannot set finalizer on a slab alloc!");
		_metadata.largeData.finalizer = finalizer;
	}
}

static assert(Extent.sizeof == ExtentSize, "Unexpected Extent size!");
static assert(Extent.sizeof == ExtentAlign, "Unexpected Extent alignment!");

ptrdiff_t addrExtentCmp(Extent* lhs, Extent* rhs) {
	auto l = cast(size_t) lhs.address;
	auto r = cast(size_t) rhs.address;

	// We need to compare that way to avoid integer overflow.
	return (l > r) - (l < r);
}

ptrdiff_t addrRangeExtentCmp(Extent* lhs, Extent* rhs) {
	auto l = cast(size_t) lhs.address;
	auto rstart = cast(size_t) rhs.address;
	auto rend = rstart + rhs.size;

	// We need to compare that way to avoid integer overflow.
	return (l >= rend) - (l < rstart);
}

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
	enum Size = 13 * PageSize;

	Extent e;
	e.address = base;
	e.sizeAndGen = Size;

	assert(!e.contains(base - 1));
	assert(!e.contains(base + Size));

	foreach (i; 0 .. Size) {
		assert(e.contains(base + i));
	}
}

unittest allocfree {
	Extent e;
	e.at(null, PageSize, null, ExtentClass.slab(0));

	assert(e.isSlab());
	assert(e.sizeClass == 0);
	assert(e.freeSlots == 512);

	assert(e.allocate() == 0);
	assert(e.freeSlots == 511);

	assert(e.allocate() == 1);
	assert(e.freeSlots == 510);

	assert(e.allocate() == 2);
	assert(e.freeSlots == 509);

	e.free(1);
	assert(e.freeSlots == 510);

	assert(e.allocate() == 1);
	assert(e.freeSlots == 509);

	assert(e.allocate() == 3);
	assert(e.freeSlots == 508);

	e.free(0);
	e.free(3);
	e.free(2);
	e.free(1);
	assert(e.freeSlots == 512);
}
