module d.gc.bin;

import d.gc.arena;
import d.gc.emap;
import d.gc.extent;
import d.gc.spec;

enum InvalidBinID = 0xff;

struct slabAllocGeometry {
	Extent* e;
	uint sc;
	size_t size;
	uint index;
	void* address;

	this(void* ptr, PageDescriptor pd, bool ptrIsStart) {
		assert(pd.extent !is null, "Extent is null!");
		assert(pd.isSlab(), "Expected a slab!");
		assert(pd.extent.contains(ptr), "ptr not in slab!");

		e = pd.extent;
		sc = pd.sizeClass;

		import d.gc.util;
		auto offset = alignDownOffset(ptr, PageSize) + pd.index * PageSize;
		index = binInfos[sc].computeIndex(offset);

		auto base = ptr - offset;
		size = binInfos[sc].itemSize;
		address = base + index * size;

		assert(!ptrIsStart || (ptr is base + index * size),
		       "ptr does not point to start of slab alloc!");
	}
}

/**
 * A bin is used to keep track of runs of a certain
 * size class. There is one bin per small size class.
 */
struct Bin {
	import d.sync.mutex;
	shared Mutex mutex;

	Extent* current;

	// XXX: We might want to consider targeting Extents
	// on old huge pages instead of just address.
	import d.gc.heap;
	Heap!(Extent, addrExtentCmp) slabs;

	void* alloc(shared(Arena)* arena, shared(ExtentMap)* emap, ubyte sizeClass,
	            size_t usedCapacity) shared {
		assert(isSmallSizeClass(sizeClass));
		assert(&arena.bins[sizeClass] == &this, "Invalid arena or sizeClass!");

		// Load eagerly as prefetching.
		auto size = binInfos[sizeClass].itemSize;

		Extent* slab;
		uint index;

		{
			mutex.lock();
			scope(exit) mutex.unlock();

			slab = (cast(Bin*) &this).getSlab(arena, emap, sizeClass);
			if (slab is null) {
				return null;
			}

			index = slab.allocate();
		}

		return slab.address + index * size;
	}

	bool free(shared(Arena)* arena, void* ptr, PageDescriptor pd) shared {
		assert(&arena.bins[pd.sizeClass] == &this,
		       "Invalid arena or sizeClass!");

		auto sg = slabAllocGeometry(ptr, pd, true);
		auto slots = binInfos[sg.sc].slots;

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Bin*) &this).freeImpl(sg.e, sg.index, slots);
	}

private:
	bool freeImpl(Extent* e, uint index, uint slots) {
		// FIXME: in contract.
		assert(mutex.isHeld(), "Mutex not held!");

		e.free(index);

		auto nfree = e.freeSlots;
		if (nfree == slots) {
			if (e is current) {
				current = null;
				return true;
			}

			// If we only had one slot, we never got added to the heap.
			if (slots > 1) {
				slabs.remove(e);
			}

			return true;
		}

		if (nfree == 1 && e !is current) {
			// Newly non empty.
			assert(slots > 1);
			slabs.insert(e);
		}

		return false;
	}

	auto tryGetSlab() {
		// FIXME: in contract.
		assert(mutex.isHeld(), "Mutex not held!");

		// If the current slab still have free slots, go for it.
		if (current !is null && current.freeSlots != 0) {
			return current;
		}

		current = slabs.pop();
		return current;
	}

	auto getSlab(shared(Arena)* arena, shared(ExtentMap)* emap,
	             ubyte sizeClass) {
		// FIXME: in contract.
		assert(mutex.isHeld(), "Mutex not held!");

		auto slab = tryGetSlab();
		if (slab !is null) {
			return slab;
		}

		{
			// Release the lock while we allocate a slab.
			mutex.unlock();
			scope(exit) mutex.lock();

			// We don't have a suitable slab, so allocate one.
			slab = arena.allocSlab(emap, sizeClass);
		}

		if (slab is null) {
			// Another thread might have been successful
			// while we did not hold the lock.
			return tryGetSlab();
		}

		// We may have allocated the slab we need when the lock was released.
		if (current is null || current.freeSlots == 0) {
			current = slab;
			return slab;
		}

		// If we have, then free the run we just allocated.
		assert(slab !is current);
		assert(current.freeSlots > 0);

		// In which case we put the free run back in the tree.
		assert(slab.freeSlots == binInfos[sizeClass].slots);
		arena.freeSlab(emap, slab);

		// And use the metadata run.
		return current;
	}
}

struct BinInfo {
	ushort itemSize;
	ushort slots;
	ubyte needPages;
	ubyte shift;
	ushort mul;

	this(ushort itemSize, ubyte shift, ubyte needPages, ushort slots) {
		this.itemSize = itemSize;
		this.slots = slots;
		this.needPages = needPages;
		this.shift = (shift + 17) & 0xff;

		// XXX: out contract
		enum MaxShiftMask = (8 * size_t.sizeof) - 1;
		assert(this.shift == (this.shift & MaxShiftMask));

		/**
		 * This is a bunch of magic values used to avoid requiring
		 * division to find the index of an item within a run.
		 *
		 * Computed using finddivisor.d
		 */
		ushort[4] mulIndices = [32768, 26215, 21846, 18725];
		auto tag = (itemSize >> shift) & 0x03;
		this.mul = mulIndices[tag];
	}

	uint computeIndex(size_t offset) const {
		// FIXME: in contract.
		assert(offset < needPages * PageSize, "Offset out of bounds!");

		return cast(uint) ((offset * mul) >> shift);
	}
}

import d.gc.sizeclass;
immutable BinInfo[ClassCount.Small] binInfos = getBinInfos();
