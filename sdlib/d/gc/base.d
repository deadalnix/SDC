module d.gc.base;

import d.gc.spec;
import d.gc.util;

shared Base gBase;

struct GenerationPointer {
private:
	static assert(LgAddressSpace <= 48, "Address space too large!");
	ulong data;

	this(ulong data) {
		this.data = data;
	}

	this(void* ptr, ubyte generation) {
		data = cast(size_t) ptr;
		data |= ulong(generation) << 56;
	}

public:
	static getNull() {
		return GenerationPointer(0);
	}

	@property
	void* address() {
		return cast(void*) (data & AddressMask);
	}

	@property
	ubyte generation() {
		return data >> 56;
	}

	auto add(ulong offset) {
		return GenerationPointer(data + offset);
	}
}

/**
 * Bump the pointer style allocator.
 *
 * It never deallocates, except on destruction.
 * It serves as a base allocator for address space.
 */
struct Base {
private:
	import d.sync.mutex;
	Mutex mutex;

	// The slice of memory we have to allocate slots from.
	GenerationPointer nextSlot;

	// The slice of memory we allocate metadata from.
	void* nextMetadataPage;
	uint availableMetadataPages;
	ubyte currentGeneration;

	// Linked list of all the blocks.
	Block* head;

	// Free list of block headers to be reserved.
	Block* blockFreeList;

public:
	void clear() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(Base*) &this).clearImpl();
	}

	GenerationPointer allocSlot() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Base*) &this).allocSlotImpl();
	}

	GenerationPointer allocMetadataPage() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Base*) &this).allocMetadataPageImpl();
	}

	void* reserveAddressSpace(size_t size) shared {
		// Bump the alignement to block size if apropriate.
		auto alignment = isAligned(size, BlockSize) ? BlockSize : PageSize;

		size = alignUp(size, alignment);
		return reserveAddressSpace(size, alignment);
	}

	void* reserveAddressSpace(size_t size, size_t alignment) shared {
		assert(alignment >= PageSize && isPow2(alignment),
		       "Invalid alignment!");
		assert(size > 0 && isAligned(size, PageSize), "Invalid size!");

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Base*) &this).reserveAddressSpaceImpl(size, alignment);
	}

private:
	void clearImpl() {
		assert(mutex.isHeld(), "Mutex not held!");

		head.clearAll();
		head = null;
		blockFreeList = null;
	}

	auto allocSlotImpl() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (hasFreeSlot()) {
			goto Success;
		}

		// Eagerly try to refill, because it may allocate a slot
		// and we want to catch this rather than void a whole page.
		if (!refillMetadataSpace()) {
			return GenerationPointer.getNull();
		}

		// We may have allocated a slot to store block informations,
		// so we need to check again as we might be good to go.
		if (hasFreeSlot()) {
			goto Success;
		}

		nextSlot = allocMetadataPageImpl();
		if (nextSlot.address is null) {
			return GenerationPointer.getNull();
		}

	Success:
		scope(success) nextSlot = nextSlot.add(ExtentSize);
		return nextSlot;
	}

	auto allocMetadataPageImpl() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (!refillMetadataSpace()) {
			return GenerationPointer.getNull();
		}

		assert(availableMetadataPages > 0, "No Metadata page available!");
		assert(isAligned(nextMetadataPage, PageSize),
		       "Invalid nextMetadataPage alignment!");

		auto ptr = nextMetadataPage;
		auto generation = currentGeneration;

		availableMetadataPages--;
		nextMetadataPage += PageSize;

		// We just filled a block worth of metadata, make it huge!
		if (isAligned(nextMetadataPage, BlockSize)) {
			import d.gc.memmap;
			page_hugify(nextMetadataPage - BlockSize, BlockSize);
		}

		return GenerationPointer(ptr, generation);
	}

	void* reserveAddressSpaceImpl(size_t size, size_t alignment) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto block = getOrAllocateBlock();
		if (block is null) {
			return null;
		}

		import d.gc.memmap;
		auto ptr = pages_map(null, size, alignment);
		if (ptr is null) {
			freeBlockImpl(block);
			return null;
		}

		registerBlock(block, ptr, size);
		return ptr;
	}

	/**
	 * Block management.
	 */
	Block* allocBlock() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Base*) &this).getOrAllocateBlock();
	}

	void freeBlock(Block* block) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(Base*) &this).freeBlockImpl(block);
	}

	auto freeBlockImpl(Block* block) {
		assert(mutex.isHeld(), "Mutex not held!");

		block.next = blockFreeList;
		blockFreeList = block;
	}

	void registerBlock(Block* block, void* ptr, size_t size) {
		assert(mutex.isHeld(), "Mutex not held!");

		block.addr = ptr;
		block.size = size;
		block.next = head;

		head = block;
	}

	auto getOrAllocateBlock() {
		assert(mutex.isHeld(), "Mutex not held!");

		refillBlocks();
		return getBlockInFrelist();
	}

	Block* getBlockInFrelist() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (blockFreeList is null) {
			return null;
		}

		auto ret = blockFreeList;
		blockFreeList = blockFreeList.next;
		return ret;
	}

	bool hasFreeSlot() {
		return !isAligned(nextSlot.address, PageSize);
	}

	bool refillMetadataSpace() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (availableMetadataPages > 0) {
			return true;
		}

		// Allocate exponentially more space for metadata.
		auto shift = currentGeneration++;
		auto size = BlockSize << shift;

		import d.gc.memmap;
		auto ptr = pages_map(null, size, BlockSize);
		if (ptr is null) {
			return false;
		}

		// We try to avoid using huge pages right away so that
		// each base remain cheap even when not used much.
		page_dehugify(ptr, size);

		nextMetadataPage = ptr;
		availableMetadataPages = PagesInBlock << shift;

		// We expect this allocation to always succeed as we just
		// reserved a ton of address space.
		auto block = getOrAllocateBlock();
		assert(block !is null, "Failed to allocate a block!");

		registerBlock(block, ptr, size);
		return true;
	}

	bool refillBlocks() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (blockFreeList !is null) {
			return true;
		}

		// We may have free slots left but no metatdata space.
		if (hasFreeSlot()) {
			goto Refill;
		}

		// Because refilling metadata space may allocate blocks
		// and we are about to use some metadata space, we want
		// to double check the free list.
		if (!refillMetadataSpace()) {
			return false;
		}

		if (blockFreeList !is null) {
			return true;
		}

	Refill:
		assert(blockFreeList is null, "There are blocks in the freelist!");

		enum BlockPerExtent = ExtentSize / alignUp(Block.sizeof, Quantum);
		static assert(BlockPerExtent == 5, "For documentation purposes.");

		auto slot = allocSlotImpl();

		auto buf = cast(Block*) slot.address;
		assert(buf !is null, "Failed to allocate block!");

		foreach (i; 1 .. BlockPerExtent) {
			buf[i - 1].next = &buf[i];
			buf[i].next = null;
		}

		blockFreeList = buf;
		return true;
	}
}

private:
static assert(Block.sizeof <= ExtentSize, "Block got too large!");

struct Block {
	void* addr;
	size_t size;

	Block* next;

	void clearAll() {
		auto next = &this;
		while (next !is null) {
			auto block = next;
			next = block.next;

			import d.gc.memmap;
			pages_unmap(block.addr, block.size);
		}
	}
}

unittest base {
	shared Base base;
	scope(exit) base.clear();

	// We can allocate blocks from base.
	auto b0 = base.allocBlock();
	auto b1 = base.allocBlock();
	assert(b0 + 1 is b1);

	// We get the same block recycled.
	base.freeBlock(b0);
	base.freeBlock(b1);
	assert(base.allocBlock() is b1);
	assert(base.allocBlock() is b0);

	// Now allocate slots.
	auto s0 = base.allocSlot();
	auto s1 = base.allocSlot();
	assert(s0.address is alignUp(b0, ExtentSize));
	assert(s0.address + ExtentSize is s1.address);
	assert(s0.generation == s1.generation);

	auto prev = s1;
	foreach (i; 0 .. 16381) {
		auto current = base.allocSlot();
		assert(prev.address + ExtentSize is current.address);
		assert(prev.generation == current.generation);

		prev = current;
	}

	auto n = base.allocSlot();
	assert(prev.generation + 1 == n.generation);
}

unittest count_blocks {
	shared Base base;
	scope(exit) base.clear();

	static countBlocks(ref shared Base base) {
		uint ret = 0;

		auto current = cast(Block*) base.head;
		while (current !is null) {
			current = current.next;
			ret++;
		}

		return ret;
	}

	static size_t indexInBlock(void* ptr) {
		auto v = cast(size_t) ptr;
		return (v % BlockSize) / ExtentSize;
	}

	static size_t indexInBlock(GenerationPointer ptr) {
		return indexInBlock(ptr.address);
	}

	// Almost fill in a block of metadata.
	auto prev = base.allocSlot();
	assert(indexInBlock(prev) == 1);

	foreach (i; 2 .. 16382) {
		auto current = base.allocSlot();
		assert(indexInBlock(current) == i);
		assert(countBlocks(base) == 1);
		assert(prev.generation == current.generation);

		prev = current;
	}

	// Empty the free list.
	while (base.blockFreeList !is null) {
		base.allocBlock();
		assert(countBlocks(base) == 1);
	}

	auto b = base.allocBlock();
	assert(indexInBlock(b) == 16382);
	assert(countBlocks(base) == 1);

	auto current = base.allocSlot();
	assert(indexInBlock(current) == 16383);
	assert(countBlocks(base) == 1);
	assert(prev.generation == current.generation);

	// Empty the free list.
	while (base.blockFreeList !is null) {
		base.allocBlock();
		assert(countBlocks(base) == 1);
	}

	current = base.allocSlot();
	assert(indexInBlock(current) == 1);
	assert(countBlocks(base) == 2);
	assert(prev.generation + 1 == current.generation);
}
