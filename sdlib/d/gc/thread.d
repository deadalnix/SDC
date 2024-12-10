module d.gc.thread;

import d.gc.capi;
import d.gc.tcache;
import d.gc.tstate;
import d.gc.types;

void createProcess() {
	enterBusyState();
	scope(exit) exitBusyState();

	import d.gc.fork;
	setupFork();

	import d.gc.signal;
	setupSignals();

	initThread();

	import d.gc.hooks;
	__sd_gc_register_global_segments();

	import d.rt.elf;
	registerTlsSegments();
}

void createThread() {
	enterBusyState();
	scope(exit) {
		exitThreadCreation();
		exitBusyState();
	}

	initThread();

	import d.rt.elf;
	registerTlsSegments();
}

void destroyThread() {
	/**
	 * Note: we are about to remove the thread from the active thread
	 * list, we do not want to suspend, because the thread will never be
	 * woken up. Therefore -- no exitBusyState.
	 */
	enterBusyState();

	threadCache.destroyThread();
	gThreadState.remove(&threadCache);
}

void enterThreadCreation() {
	gThreadState.enterThreadCreation();
}

void exitThreadCreation() {
	gThreadState.exitThreadCreation();
}

uint getRegisteredThreadCount() {
	return gThreadState.getRegisteredThreadCount();
}

uint getSuspendedThreadCount() {
	return gThreadState.getSuspendedThreadCount();
}

uint getRunningThreadCount() {
	return gThreadState.getRunningThreadCount();
}

void enterBusyState() {
	threadCache.state.enterBusyState();
}

void exitBusyState() {
	threadCache.state.exitBusyState();
}

void stopTheWorld() {
	gThreadState.stopTheWorld();
}

void restartTheWorld() {
	gThreadState.restartTheWorld();
}

void threadScan(ScanDg scan) {
	// Scan the registered TLS segments.
	foreach (s; threadCache.tlsSegments) {
		scan(s);
	}

	import d.gc.stack;
	scanStack(scan);
}

void scanSuspendedThreads(ScanDg scan) {
	gThreadState.scanSuspendedThreads(scan);
}

private:

void initThread() {
	assert(threadCache.state.busy, "Thread is not busy!");

	import d.gc.emap, d.gc.base;
	threadCache.initialize(&gExtentMap, &gBase);
	threadCache.activateGC();

	import d.gc.global;
	gThreadState.register(&threadCache);
}

struct ThreadState {
private:
	import d.sync.atomic;
	uint startingThreadCount;
	enum uint PauseThreadCreationBit = 1 << 31;

	import d.sync.mutex;
	shared Mutex mStats;

	uint registeredThreadCount = 0;
	uint suspendedThreadCount = 0;

	Mutex mThreadList;
	ThreadRing registeredThreads;

	Mutex stopTheWorldMutex;

	shared Mutex createThreadMutex;

public:
	/**
	 * Thread management.
	 */
	void enterThreadCreation() shared {
		createThreadMutex.lock();
		scope(exit) createThreadMutex.unlock();

		(cast(ThreadState*) &this).enterThreadCreationImpl();
	}

	void exitThreadCreation() shared {
		createThreadMutex.lock();
		scope(exit) createThreadMutex.unlock();

		(cast(ThreadState*) &this).exitThreadCreationImpl();
	}

	void register(ThreadCache* tcache) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).registerImpl(tcache);
	}

	void remove(ThreadCache* tcache) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).removeImpl(tcache);
	}

	auto getRegisteredThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		return (cast(ThreadState*) &this).registeredThreadCount;
	}

	auto getSuspendedThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		return (cast(ThreadState*) &this).suspendedThreadCount;
	}

	auto getRunningThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		auto state = cast(ThreadState*) &this;
		return state.registeredThreadCount - state.suspendedThreadCount;
	}

	void stopTheWorld() shared {
		import d.gc.hooks;
		__sd_gc_pre_stop_the_world_hook();

		stopTheWorldMutex.lock();

		pauseThreadCreation();

		import d.gc.tcache;
		threadCache.stoppingTheWorld = true;

		uint count;

		// Make sure no suspended threads have the create thread mutex locked.
		createThreadMutex.lock();
		scope(exit) createThreadMutex.unlock();
		while (suspendRunningThreads(count++)) {
			import sys.posix.sched;
			sched_yield();
		}
	}

	void restartTheWorld() shared {
		import d.gc.tcache;
		assert(threadCache.stoppingTheWorld);
		threadCache.stoppingTheWorld = false;

		allowThreadCreation();

		while (resumeSuspendedThreads()) {
			import sys.posix.sched;
			sched_yield();
		}

		stopTheWorldMutex.unlock();

		import d.gc.hooks;
		__sd_gc_post_restart_the_world_hook();
	}

	void scanSuspendedThreads(ScanDg scan) shared {
		assert(stopTheWorldMutex.isHeld());

		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).scanSuspendedThreadsImpl(scan);
	}

private:
	void registerImpl(ThreadCache* tcache) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		{
			mStats.lock();
			scope(exit) mStats.unlock();
			registeredThreadCount++;
		}

		registeredThreads.insert(tcache);
	}

	void enterThreadCreationImpl() {
		assert(createThreadMutex.isHeld(), "Mutex not held!");

		// Wait for the world to not be stopping by another thread.
		import d.gc.tcache;
		if (!threadCache.stoppingTheWorld) {
			createThreadMutex.waitFor(canCreateThreads);
			assert(!(startingThreadCount & PauseThreadCreationBit));
		}

		++startingThreadCount;
	}

	bool canCreateThreads() {
		return !(startingThreadCount & PauseThreadCreationBit);
	}

	void exitThreadCreationImpl() {
		assert(createThreadMutex.isHeld(), "Mutex not held!");
		assert((startingThreadCount & ~PauseThreadCreationBit) > 0,
		       "enterThreadCreation was not called!");

		startingThreadCount--;
	}

	void pauseThreadCreation() shared {
		createThreadMutex.lock();
		scope(exit) createThreadMutex.unlock();

		(cast(ThreadState*) &this).pauseThreadCreationImpl();
	}

	void pauseThreadCreationImpl() {
		assert(createThreadMutex.isHeld(), "Mutex not held!");
		assert((startingThreadCount & PauseThreadCreationBit) == 0);

		/**
		 * Wait for threads in the process of starting to finish
		 * starting, prevent any new threads from starting.
		 */
		startingThreadCount += PauseThreadCreationBit;
		createThreadMutex.waitFor(canStopTheWorld);
	}

	bool canStopTheWorld() {
		return startingThreadCount == PauseThreadCreationBit;
	}

	void allowThreadCreation() shared {
		createThreadMutex.lock();
		scope(exit) createThreadMutex.unlock();

		(cast(ThreadState*) &this).allowThreadCreationImpl();
	}

	void allowThreadCreationImpl() {
		assert(createThreadMutex.isHeld(), "Mutex not held!");
		assert(startingThreadCount == PauseThreadCreationBit);

		startingThreadCount -= PauseThreadCreationBit;
	}

	void removeImpl(ThreadCache* tcache) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		{
			mStats.lock();
			scope(exit) mStats.unlock();
			registeredThreadCount--;
		}

		registeredThreads.remove(tcache);
	}

	bool suspendRunningThreads(uint count) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		return (cast(ThreadState*) &this).suspendRunningThreadsImpl(count);
	}

	bool suspendRunningThreadsImpl(uint count) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		bool retry = false;
		uint suspended = 0;

		auto r = registeredThreads.range;
		while (!r.empty) {
			auto tc = r.front;
			scope(success) r.popFront();

			// Make sure we do not self suspend!
			if (tc is &threadCache) {
				continue;
			}

			// If the thread isn't already stopped, we'll need to retry.
			auto ss = tc.state.suspendState;
			if (ss == SuspendState.Detached) {
				continue;
			}

			// If a thread is detached, stop trying.
			if (count > 32 && ss == SuspendState.Signaled) {
				import d.gc.proc;
				if (isDetached(tc.tid)) {
					tc.state.detach();
					continue;
				}
			}

			suspended += ss == SuspendState.Suspended;
			retry |= ss != SuspendState.Suspended;

			// If the thread has already been signaled.
			if (ss != SuspendState.None) {
				continue;
			}

			import d.gc.signal;
			signalThreadSuspend(tc);
		}

		mStats.lock();
		scope(exit) mStats.unlock();

		suspendedThreadCount = suspended;
		return retry;
	}

	bool resumeSuspendedThreads() shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		return (cast(ThreadState*) &this).resumeSuspendedThreadsImpl();
	}

	bool resumeSuspendedThreadsImpl() {
		assert(mThreadList.isHeld(), "Mutex not held!");

		bool retry = false;
		uint suspended = 0;

		auto r = registeredThreads.range;
		while (!r.empty) {
			auto tc = r.front;
			scope(success) r.popFront();

			// If the thread isn't already resumed, we'll need to retry.
			auto ss = tc.state.suspendState;
			if (ss == SuspendState.Detached) {
				continue;
			}

			suspended += ss == SuspendState.Suspended;
			retry |= ss != SuspendState.None;

			// If the thread isn't suspended, move on.
			if (ss != SuspendState.Suspended) {
				continue;
			}

			import d.gc.signal;
			signalThreadResume(tc);
		}

		mStats.lock();
		scope(exit) mStats.unlock();

		suspendedThreadCount = suspended;
		return retry;
	}

	void scanSuspendedThreadsImpl(ScanDg scan) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		auto r = registeredThreads.range;
		while (!r.empty) {
			auto tc = r.front;
			scope(success) r.popFront();

			// If the thread isn't suspended, move on.
			auto ss = tc.state.suspendState;
			if (ss != SuspendState.Suspended && ss != SuspendState.Detached) {
				continue;
			}

			// Scan the registered TLS segments.
			foreach (s; tc.tlsSegments) {
				scan(s);
			}

			// Only suspended thread have their stack properly set.
			// For detached threads, we just hope nothing's in there.
			if (ss == SuspendState.Suspended) {
				import d.gc.range;
				scan(makeRange(tc.stackTop, tc.stackBottom));
			}
		}
	}
}

shared ThreadState gThreadState;
