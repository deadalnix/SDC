module config.hash;

import config.traits;
import config.value;

hash_t hash(T)(T t) if (isKeyLike!T) {
	return rehash(Hasher().hash(t));
}

/**
 * The hash generated does not have good collision resistance over
 * all subsets of the bits of the hash value, which causes clumping.
 *
 * In order to fix this, we mix the bits around to ensure good entropy
 * over the ranges we are interested in.
 *
 * NB: On architecture that provide hardware support
 * for CRC32 (ARMv8.1+, x86), we might want to use that.
 */
hash_t rehash(hash_t h) {
	import util.math;
	enum K = 0xc4ceb9fe1a85ec53;
	auto hi = mulhi(h, K);
	auto lo = h * K;
	return (hi ^ lo) * K;
}

enum isHashable(T) = is(typeof(const(T).init.toHash()) : hash_t);

struct Hasher {
	ulong state = 0;

	@safe @nogc
	hash_t mix(ulong k) pure nothrow {
		import util.math;
		auto hi = mulhi(state, k);
		auto lo = state * k;
		state = hi ^ lo;
		return state;
	}

	hash_t hash(T)(T t) if (isPrimitiveValue!T) {
		return hash(Value(t));
	}

	hash_t hash()(typeof(null) nothing) {
		return hash(Value(nothing));
	}

	hash_t hash(B : bool)(B b) {
		return hash(Value(b));
	}

	hash_t hash(I : long)(I i) {
		return hash(Value(i));
	}

	hash_t hash(F : double)(F f) {
		state += Double(f).toPayload();
		return state;
	}

	hash_t hash(H)(const H h) if (isHashable!H) {
		// Forward to the ref version.
		return hash(h);
	}

	hash_t hash(H)(const ref H h) if (isHashable!H) {
		state += h.toHash();
		return state;
	}

	hash_t hash(S : string)(S s) {
		// Ensure we have a non zero hash for empty strings.
		state += (s.length - 8);

		while (s.length >= 8) {
			mix(0x87c37b91114253d5);

			import source.swar.util;
			state += read!ulong(s);

			s = s[8 .. $];
		}

		mix(0x1b87359352dce729);

		import source.swar.util;
		state += read!ulong(s);
		return state;
	}

	hash_t hash(A : E[], E)(A a) if (isKeyLike!E) {
		// Make sure we mix things a bit so that an empty
		// array has a diffrent hash than an empty string.
		state += (a.length ^ 0x1b87359352dce729);
		state ^= (state >> 33);

		foreach (ref e; a) {
			mix(0xe6546b64cc9e2d51);
			state += Hasher().hash(e);
		}

		return state;
	}
}

unittest {
	static void testValueHash(T)(T t) {
		assert(hash(t) == hash(Value(t)));
	}

	testValueHash(null);
	testValueHash(true);
	testValueHash(false);
	testValueHash("");
	testValueHash("dqsflgjh");
	testValueHash(0);
	testValueHash(1);
	testValueHash(12345);
	testValueHash(0.0);
	testValueHash(1.1);
	testValueHash(float.nan);
	testValueHash(float.infinity);
	testValueHash(-float.nan);
	testValueHash(-float.infinity);

	testValueHash([null, null]);
	testValueHash([true, false]);
	testValueHash(["the", "lazy", "fox"]);
	testValueHash([1, 2, 3, 4, 5]);
	testValueHash([0.0, 1.1, 2.2, 3.3, float.infinity]);
}

unittest {
	int[] empty;
	assert(hash("") != 0);
	assert(hash(empty) != 0);
	assert(hash("") != hash(empty));

	import config.heap;
	static void testString(string s) {
		auto vs = VString(s);
		assert(hash(s) == hash(vs));
		assert(hash(s) == rehash(vs.toHash()));

		auto v = Value(s);
		assert(hash(s) == hash(v));
		assert(hash(s) == rehash(v.toHash()));
	}

	testString("");
	testString("foo");
	testString("bar");
	testString("foobar");
	testString("Banana! Banana! Banana! Banana!");

	static void testArray(E)(E[] a) {
		auto va = VArray(a);
		assert(hash(a) == hash(va));
		assert(hash(a) == rehash(va.toHash()));

		auto v = Value(a);
		assert(hash(a) == hash(v));
		assert(hash(a) == rehash(v.toHash()));
	}

	testArray(empty);
	testArray([1, 2, 3]);
	testArray(["1", "2", "3"]);

	ulong[] arr = [1, 2, 3];
	assert(hash(arr) == hash(Value([1, 2, 3])));
}
