module d.gc.tstate;

import sdc.intrinsics;
import d.gc.tcache;

enum SuspendState {
	// The thread is running as usual.
	None,
	// A signal has been sent to the thread that it'll need to suspend.
	Signaled,
	// The suspend was delayed, because the thread was busy.
	Delayed,
	// The thread is suspended.
	Suspended,
	// The thread is in the process of resuming operations.
	Resumed,
	// The thread cannot use the GC because a collect is happening.
	Probation,
	// The thread is detached. The GC won't stop it.
	Detached,
}

static auto status(size_t v) {
	enum StatusMask = ThreadState.BusyIncrement - 1;
	return cast(SuspendState) (v & StatusMask);
}

struct ThreadState {
private:
	import d.sync.atomic;
	import d.sync.mutex;
	shared Atomic!size_t state;
	shared Mutex busyWaitMutex;

	enum BusyIncrement = 0x08;

	enum RunningState = SuspendState.None;
	enum SignaledState = SuspendState.Signaled;
	enum SuspendedState = SuspendState.Suspended;
	enum DelayedState = SuspendState.Delayed;
	enum ResumedState = SuspendState.Resumed;
	enum ProbationState = SuspendState.Probation;

	enum MustSuspendState = BusyIncrement | SuspendState.Delayed;

public:
	@property
	auto suspendState() {
		return status(state.load());
	}

	@property
	bool busy() {
		return state.load() >= BusyIncrement;
	}

	void sendSuspendSignal() {
		auto s = state.load();
		while (true) {
			auto n = s + SuspendState.Signaled;

			assert(status(s) == SuspendState.None);
			assert(status(n) == SuspendState.Signaled);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	void detach() {
		auto s = state.load();
		while (true) {
			auto n = s - SuspendState.Signaled + SuspendState.Detached;

			assert(status(s) == SuspendState.Signaled);
			assert(status(n) == SuspendState.Detached);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	bool onSuspendSignal() {
		auto s = state.load();

		while (true) {
			assert(status(s) == SuspendState.Signaled);

			// If the thread isn't busy, we can suspend
			// from the signal handler.
			if (s == SignaledState) {
				import d.gc.signal;
				suspendThreadFromSignal(&this);

				return true;
			}

			// The thread is busy, delay suspension.
			auto n = s + SuspendState.Signaled;
			assert(status(n) == SuspendState.Delayed);

			if (state.casWeak(s, n)) {
				return false;
			}
		}
	}

	void sendResumeSignal() {
		auto s = state.load();
		while (true) {
			auto n = s + SuspendState.Signaled;

			assert(status(s) == SuspendState.Suspended);
			assert(status(n) == SuspendState.Resumed);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	void clearProbationState() {
		size_t s = ProbationState;
		if (state.casWeak(s, RunningState)) {
			return;
		}

		// The thread has now tried to enter a busy state. Must use the
		// lock to to wake it up.
		busyWaitMutex.lock();
		scope(exit) busyWaitMutex.unlock();
		while (true) {
			enum BusyMask = ~(BusyIncrement - 1);
			auto n = s & BusyMask;

			assert(s >= BusyIncrement);
			assert(n >= BusyIncrement);
			assert(status(s) == ProbationState);
			assert(status(n) == RunningState);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	void onResumeSignal() {
		assert(state.load() == ResumedState);
		state.store(ProbationState);
	}

	void enterBusyState() {
		auto s = state.fetchAdd(BusyIncrement);
		assert(status(s) != SuspendState.Suspended);
		if (status(s) != ProbationState) {
			return;
		}

		// In Resumed state, we need to wait until the GC cycle is done before doing anything.
		busyWaitMutex.lock();
		scope(exit) busyWaitMutex.unlock();
		busyWaitMutex.waitFor(offProbation);
	}

	bool exitBusyState() {
		size_t s = BusyIncrement;
		if (likely(state.casWeak(s, RunningState))) {
			return false;
		}

		return exitBusyStateSlow(s);
	}

package:
	void markSuspended() {
		// The status to delayed because of the fetchAdd in onSuspendSignal.
		auto s = state.load();
		assert(s == SignaledState || s == MustSuspendState);

		state.store(SuspendedState);
	}

private:
	bool offProbation() {
		auto s = state.load();
		assert(s >= BusyIncrement);
		return status(s) != ProbationState;
	}

	bool exitBusyStateSlow(size_t s) {
		while (true) {
			assert(s >= BusyIncrement);
			assert(status(s) != SuspendState.Suspended);

			if (s == MustSuspendState) {
				import d.gc.signal;
				suspendThreadDelayed(&this);

				return true;
			}

			if (state.casWeak(s, s - BusyIncrement)) {
				return false;
			}
		}
	}
}

unittest busy {
	ThreadState s;

	void check(SuspendState ss, bool busy) {
		assert(s.suspendState == ss);
		assert(s.busy == busy);
	}

	// Check init state.
	check(SuspendState.None, false);

	void checkForState(SuspendState ss) {
		// Check simply busy/unbusy state transtion.
		s.state.store(ss);
		check(ss, false);

		s.enterBusyState();
		check(ss, true);

		assert(!s.exitBusyState());
		check(ss, false);

		// Check nesting busy states.
		s.enterBusyState();
		s.enterBusyState();
		check(ss, true);

		assert(!s.exitBusyState());
		check(ss, true);

		assert(!s.exitBusyState());
		check(ss, false);
	}

	checkForState(SuspendState.None);
	checkForState(SuspendState.Signaled);
}

unittest suspend {
	import d.gc.signal;
	setupSignals();

	static runThread(void* delegate() dg) {
		static struct Delegate {
			void* ctx;
			void* function(void*) fun;
		}

		auto x = *(cast(Delegate*) &dg);

		import core.stdc.pthread;
		pthread_t tid;
		auto r = pthread_create(&tid, null, x.fun, x.ctx);
		assert(r == 0, "Failed to create thread!");

		return tid;
	}

	// Make sure to use the state from the thread cache
	// so signal can find it back when needed.
	import d.gc.tcache;
	ThreadCache* tc = &threadCache;

	// Depending on the environement the thread runs in,
	// this may not have been initialized.
	import core.stdc.pthread;
	tc.self = pthread_self();

	ThreadState* s = &tc.state;
	scope(exit) {
		assert(s.state.load() == 0, "Invalid leftover state!");
	}

	import d.sync.atomic;
	shared Atomic!uint resumeCount;
	shared Atomic!uint lockedProbationCount;
	shared Atomic!uint mustStop;

	bool checkSuspend() {
		if (s.suspendState != SuspendState.Suspended) {
			return false;
		}

		resumeCount.fetchAdd(1);

		import d.gc.signal;
		signalThreadResume(tc);

		while (s.suspendState == SuspendState.Suspended) {
			import sys.posix.sched;
			sched_yield();
		}

		return true;
	}

	bool checkProbation() {
		/*
		 * Clear probation when in busy state, the main thread will
		 * have locked and is waiting for an external thread to clear
		 * it.
		 */
		if (s.suspendState != SuspendState.Probation || !s.busy) {
			return false;
		}

		lockedProbationCount.fetchAdd(1);

		s.clearProbationState();
		return true;
	}

	void* autoResume() {
		while (mustStop.load() == 0) {
			if (!checkSuspend() && !checkProbation()) {
				import sys.posix.sched;
				sched_yield();
			}
		}

		return null;
	}

	auto autoResumeThreadID = runThread(autoResume);

	scope(exit) {
		mustStop.store(1);

		void* ret;
		pthread_join(autoResumeThreadID, &ret);
	}

	void check(SuspendState ss, bool busy, uint suspendCount) {
		assert(s.suspendState == ss);
		assert(s.busy == busy);
		assert(resumeCount.load() == suspendCount);
	}

	// Check init state.
	check(SuspendState.None, false, 0);

	// Simple signal.
	s.sendSuspendSignal();
	check(SuspendState.Signaled, false, 0);

	assert(s.onSuspendSignal());
	check(SuspendState.Probation, false, 1);

	// Clear the probation
	s.clearProbationState();
	check(SuspendState.None, false, 1);

	// Signal while busy.
	s.sendSuspendSignal();
	check(SuspendState.Signaled, false, 1);

	s.enterBusyState();
	s.enterBusyState();
	check(SuspendState.Signaled, true, 1);

	assert(!s.onSuspendSignal());
	check(SuspendState.Delayed, true, 1);

	assert(!s.exitBusyState());
	check(SuspendState.Delayed, true, 1);

	assert(s.exitBusyState());
	check(SuspendState.Probation, false, 2);

	// Enter busy state while on probation
	assert(lockedProbationCount.load() == 0);
	s.enterBusyState();
	assert(lockedProbationCount.load() == 1);
	check(SuspendState.None, true, 2);

	assert(!s.exitBusyState());
	check(SuspendState.None, false, 2);
}
