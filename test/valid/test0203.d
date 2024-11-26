//T compiles:yes
//T has-passed:yes
//T retval:0
// GC multithreaded collection deadlock test

import core.stdc.unistd;
import core.stdc.pthread;
import d.sync.atomic;
import d.sync.mutex;

extern(C) void __sd_gc_collect();
extern(C) void* __sd_gc_alloc_finalizer(size_t size, void* finalizer);

shared Atomic!uint shouldQuit;

shared Mutex mtx;

shared size_t ndestroyed;

struct S {
	~this() {
		mtx.lock();
		scope(exit) mtx.unlock();
		ndestroyed += 1;
	}
}

void* runThread(void* ctx) {
	size_t count;
	while (!shouldQuit.load()) {
		S s;
		++count;
	}

	return cast(void*) count;
}

void destroyItem(T)(void* item, size_t size) {
	assert(size == T.sizeof);
	(cast(T*) item).__dtor();
}

void allocateItem(T)() {
	auto ptr = __sd_gc_alloc_finalizer(T.sizeof, &destroyItem!T);
}

void* watchdog(void* ctx) {
	import d.gc.tcache;
	import d.gc.tstate;
	// TODO: there should be an API for this.
	threadCache.state.state.store(SuspendState.Detached);
	int i;
	while (!shouldQuit.load()) {
		// Watchdog timeout!
		assert(++i < 15, "Watchdog timeout!");
		sleep(1);
	}

	return null;
}

void main() {
	pthread_t[5] tids;
	pthread_create(&tids[0], null, watchdog, null);
	// Give the watchdog time to detach.
	sleep(1);
	foreach (i; 1 .. 5) {
		pthread_create(&tids[i], null, runThread, null);
	}

	foreach (i; 0 .. 100) {
		allocateItem!S();
		__sd_gc_collect();
	}

	shouldQuit.store(1);
	void* ret;
	size_t total = 0;
	foreach (i; 0 .. 5) {
		pthread_join(tids[i], &ret);
		total += cast(size_t) ret;
	}

	// Simple sanity check.
	assert(ndestroyed > total && ndestroyed <= total + 100);
}
