module dmd.thread;

import d.gc.types;
import d.gc.emap;

extern(C):

// druntime API.
bool thread_preSuspend(void* stackTop);
bool thread_postSuspend();

void thread_preStopTheWorld();
void thread_postRestartTheWorld();

void thread_scanAll_C(ScanDg* context, typeof(&__sd_scanAllThreadsFn) scan);

// note, we must interface with DMD using extern(C) calls, so we
// cannot call thread_scanAll directly. This requires a hook compiled
// on the druntime side that forwards to thread_scanAll, and we cannot
// use delegates (as those are not the same ABI)
// the context pointer is just a pass-through for the druntime side, so we
// type it based on what we are passing.
void __sd_scanAllThreadsFn(ScanDg* context, void* start, void* stop) {
	import d.gc.range;
	(*context)(makeRange(start, stop));
}

// sdrt API.
void __sd_gc_global_scan(ScanDg scan) {
	// Scan all registered roots and ranges.
	import d.gc.global;
	gState.scanRoots(scan);

	import d.gc.thread;
	scanSuspendedThreads(scan);

	thread_scanAll_C(&scan, &__sd_scanAllThreadsFn);
}

/**
 * Free a pointer directly to an arena. Needed to avoid messing up threadCache
 * bins in signal handler.
 */
private void arenaFree(ref CachedExtentMap emap, void* ptr) {
	import d.gc.util, d.gc.spec;
	auto aptr = alignDown(ptr, PageSize);
	auto pd = emap.lookup(aptr);
	if (!pd.isSlab()) {
		pd.arena.freeLarge(emap, pd.extent);
		return;
	}

	const(void*)[1] worklist = [ptr];
	pd.arena.batchFree(emap, worklist[0 .. 1], &pd);
}

void __sd_gc_pre_suspend_hook(void* stackTop) {
	if (!thread_preSuspend(stackTop)) {
		return;
	}

	// Druntime is managing this thread, do not use our mechanism to scan
	// the stacks, because druntime has a complex mechanism to deal with
	// stacks (for fiber support).
	import d.gc.tcache;
	threadCache.stackTop = null;

	/**
	 * If the thread is managed by druntime, then we'll get the
	 * TLS segments when calling thread_scanAll_C, so we can remove
	 * them from the thread cache in order to not scan them twice.
	 * 
	 * Note that we cannot do so with the stack, because we need to
	 * scan it eagerly, as registers containing possible pointers gets
	 * pushed on it.
	 */
	auto tls = threadCache.tlsSegments;
	if (tls.ptr is null) {
		return;
	}

	threadCache.tlsSegments = [];

	// Arena needs a CachedExtentMap for freeing pages.
	auto emap = CachedExtentMap(threadCache.emap.emap, threadCache.emap.base);
	arenaFree(emap, tls.ptr);
}

void __sd_gc_post_suspend_hook() {
	thread_postSuspend();
}

void __sd_gc_pre_stop_the_world_hook(void* stackTop) {
	thread_preStopTheWorld();
}

void __sd_gc_post_restart_the_world_hook() {
	thread_postRestartTheWorld();
}

// druntime handles this on its own.
void __sd_gc_register_global_segments() {}
