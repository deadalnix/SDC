module d.gc.collector;

import d.gc.arena;
import d.gc.emap;
import d.gc.spec;
import d.gc.tcache;

struct Collector {
	ThreadCache* treadCache;

	this(ThreadCache* tc) {
		this.treadCache = tc;
	}

	@property
	ref CachedExtentMap emap() {
		return threadCache.emap;
	}

	bool maybeRunGCCycle(ref size_t delta, ref size_t target) {
		return gCollectorState.maybeRunGCCycle(this, delta, target);
	}

	void runGCCycle() {
		import d.gc.thread;
		stopTheWorld();
		scope(exit) restartTheWorld();

		import d.gc.global;
		auto gcCycle = gState.nextGCCycle();

		import d.gc.region;
		auto dataRange = gDataRegionAllocator.computeAddressRange();
		auto ptrRange = gPointerRegionAllocator.computeAddressRange();

		import d.gc.range;
		auto managedAddressSpace = merge(dataRange, ptrRange);

		prepareGCCycle();

		import d.gc.scanner;
		shared(Scanner) scanner = Scanner(gcCycle, managedAddressSpace);

		// Go on and on until all worklists are empty.
		scanner.mark();

		/**
		 * We might have allocated, and therefore refilled the bin
		 * during the collection process. As a result, slots in the
		 * bins may not be makred at this point.
		 * 
		 * The straightforward way to handle this is simply to flush
		 * the bins.
		 * 
		 * Alternatively, we could make sure the slots are marked.
		 */
		threadCache.flushCache();

		collect(gcCycle);
	}

	void prepareGCCycle() {
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.prepareGCCycle(emap);
			}
		}
	}

	void collect(ubyte gcCycle) {
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.collect(emap, gcCycle);
			}
		}
	}
}

private:
struct CollectorState {
private:
	import d.sync.mutex;
	Mutex mutex;

	// This makes for a 32MB default target.
	size_t targetPageCount = 32 * 1024 * 1024 / PageSize;

public:
	bool maybeRunGCCycle(ref Collector collector, ref size_t delta,
	                     ref size_t target) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(CollectorState*) &this)
			.maybeRunGCCycleImpl(collector, delta, target);
	}

private:
	bool maybeRunGCCycleImpl(ref Collector collector, ref size_t delta,
	                         ref size_t target) {
		if (!needCollection(delta)) {
			target = delta;
			return false;
		}

		collector.runGCCycle();

		target = updateTargetPageCount();
		return true;
	}

	bool needCollection(ref size_t delta) {
		size_t total;

		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				total += a.usedPages;
			}
		}

		if (total >= targetPageCount) {
			// How much did we overshoot?
			delta = total - targetPageCount;
			return true;
		}

		// How many more pages before we need a collection.
		delta = targetPageCount - total;
		return false;
	}

	size_t updateTargetPageCount() {
		size_t total;

		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a is null) {
				continue;
			}

			total += a.usedPages;
		}

		// We set the target at 1.75x the current heap size in pages.
		targetPageCount = total + (total >> 1) + (total >> 2);
		return targetPageCount - total;
	}
}

shared CollectorState gCollectorState;
