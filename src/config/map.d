module config.map;

import config.hash;
import config.heap;
import config.traits;
import config.value;

import util.math;

/**
 * Extract 7 bits of the hash for the tag.
 *
 * Do not use the lower bits as they typically
 * won't have highest entropy.
 */
ubyte HTag(hash_t h) {
	return (h >> 15) & 0x7f;
}

/**
 * The index of the bucket in which we should probe.
 *
 * Uses bits that do not overlap with Htag, to minimize
 * false negatives when filtering tags.
 */
uint HIndex(hash_t h) {
	return (h >> 22) & uint.max;
}

/**
 * The offset of the bucket we need to probe next if
 * the curent one doesn't containt what we are lookign for.
 *
 * We make sure HStep is odd. Because the number of buckets
 * is a power of 2, we are guaranteed that they are coprime,
 * which in turn ensures us that we will visit all buckets.
 *
 * Randomizing probing ensure we avoid clumping.
 */
uint HStep(hash_t h) {
	return ((h >> 15) | 0x01) & uint.max;
}

struct Probe {
	uint index;
	uint step;
	uint mask;

	this(hash_t h, uint bucketCount) in(isPow2(bucketCount)) {
		mask = bucketCount - 1;
		index = HIndex(h) & mask;
		step = HStep(h);
	}

	uint current() const {
		return index & mask;
	}

	uint next() {
		index += step;
		return current;
	}
}

/**
 * NB: Using a size of 12 would make this struct
 * the size of one cache line. There is probably
 * a win here in some circumstances, but that seem
 * unlikely that it does in this context. The prefix
 * prevents this to be aligned on cache lines anyways.
 */
struct Bucket {
private:
	ubyte[14] tags;

	ubyte control;
	ubyte overflow;

	uint[14] indices;

	enum EmptyTag = 0x80;

	@property
	ulong[2] tagBytes() const {
		import source.swar.util;
		return [read!ulong(tags[0 .. 8]), read!ulong(tags.ptr[7 .. 15])];
	}

	void clear() {
		tags[] = EmptyTag;
		control = 0;
		overflow = 0;
	}

public:
	struct Range {
	private:
		uint bits;

		static fromBits(ulong t0, ulong t1) {
			enum Dispatch = 0x0002040810204080;
			uint r0 = (t0 * Dispatch) >> 56;
			uint r1 = (t1 * Dispatch) >> 56;

			return Range(r0 | (r1 << 7));
		}

	public:
		@property
		bool empty() const {
			return bits == 0;
		}

		@property
		uint front() const in(!empty) {
			import core.bitop;
			return bsf(bits);
		}

		void popFront() {
			// Clear the lowest bit.
			bits &= (bits - 1);
		}
	}

	auto match(hash_t h) const {
		enum LSBs = 0x0001010101010101;
		auto v = HTag(h) * LSBs;
		auto t0 = tagBytes[0] ^ v;
		auto t1 = tagBytes[1] ^ v;

		/**
		 * This leverage SWAR to check for 0s in t0 and t1.
		 *
		 * /!\ This has false positive due to overflow, but:
		 *   - All real match are detected.
		 *   - They never occurs on empty slot (tag = 0x80)
		 *   - They will be cleared when checking for key equality.
		 *   - because they are always preceded by a real match,
		 *     we will unfrequently have to check them anyway.
		 *
		 * Abseil provides us with an exemple:
		 *   t0 = 0x1716151413121110
		 *   HTag(h) = 0x12
		 *     => m0 = 0x0000000080800000
		 *
		 * Here, the 3rd and 4th slots match, but only the 3rd
		 * is a real match, the 4th is a false positive.
		 */
		enum MSBs = 0x0080808080808080;
		auto m0 = (t0 - LSBs) & ~t0 & MSBs;
		auto m1 = (t1 - LSBs) & ~t1 & MSBs;

		return Range.fromBits(m0, m1);
	}

	auto emptySlots() const {
		enum MSBs = 0x0080808080808080;
		return Range.fromBits(tagBytes[0] & MSBs, tagBytes[1] & MSBs);
	}

	bool insert(hash_t h, uint index) {
		auto esr = emptySlots;

		// There are no empty slot left.
		if (esr.empty) {
			auto no = overflow + 2;
			overflow = (no | no >> 8) & 0xff;
			return false;
		}

		// Pick the first slot and roll with it.
		auto i = esr.front;
		tags[i] = HTag(h);
		indices[i] = index;

		return true;
	}
}

unittest {
	static matchEmpty(const ref Bucket b, uint start = 0, uint stop = 14) {
		auto es = b.emptySlots();
		foreach (i; start .. stop) {
			assert(!es.empty);
			assert(es.front == i);
			es.popFront();
		}

		assert(es.empty);
	}

	Bucket b;
	b.clear();

	matchEmpty(b);

	auto match0 = b.match(0);
	assert(match0.empty);

	// After inserting one element,
	// it takes the first slot.
	assert(b.insert(hash(0x42), 123));

	matchEmpty(b, 1);

	match0 = b.match(0);
	assert(match0.empty);

	auto match42 = b.match(hash(0x42));
	assert(!match42.empty);
	assert(match42.front == 0);
	assert(b.indices[0] == 123);
	match42.popFront();
	assert(match42.empty);

	// Insert a second element which collides.
	assert(b.insert(hash(0x42), 456));

	matchEmpty(b, 2);

	match0 = b.match(0);
	assert(match0.empty);

	match42 = b.match(hash(0x42));
	assert(!match42.empty);
	assert(match42.front == 0);
	assert(b.indices[0] == 123);
	match42.popFront();
	assert(match42.front == 1);
	assert(b.indices[1] == 456);
	match42.popFront();
	assert(match42.empty);

	// Fill the bucket.
	foreach (i; 0 .. 12) {
		assert(b.insert(hash(0xaa), i));
	}

	assert(b.emptySlots().empty);
	assert(!b.insert(0, 789));
	assert(b.overflow == 2);
}

/**
 * A Value like struct, but that can only contain strings.
 */
struct VObjectKey {
	union {
		VString str;
		ulong payload;
	}

	@safe
	bool isUndefined() const nothrow {
		return payload == 0;
	}

	void clear() {
		payload = 0;
	}

	void destroy() {
		if (!isUndefined()) {
			str.destroy();
			clear();
		}
	}

	string dump() const in(payload != 0) {
		return str.dump();
	}

	@trusted
	inout(VString) getString() inout nothrow in(!isUndefined) {
		return str;
	}

	@safe
	hash_t toHash() const nothrow {
		return isUndefined() ? 0 : getString().toHash();
	}

	VObjectKey opAssign(K)(K k) if (isKeyLike!K) {
		str = VString(k);
		return this;
	}

	bool opEquals(const VString rhs) const {
		return !isUndefined() && rhs == str;
	}

	bool opEquals(const ref Value rhs) const {
		return !isUndefined() && rhs.isString() && rhs == str;
	}

	bool opEquals(K)(K k) const if (isStringValue!K) {
		return !isUndefined() && str == k;
	}

	bool opEquals(K)(K k) const if (isKeyLike!K && !isStringValue!K) {
		return false;
	}
}

enum MapKind {
	Object,
	Map,
}

alias VObject = VMapLike!(MapKind.Object);
alias VMap = VMapLike!(MapKind.Map);

struct VMapLike(MapKind T) {
package:
	struct Impl {
		Descriptor tag;
		uint lgBucketCount;
	}

	Impl* impl;
	alias impl this;

	static if (T == MapKind.Object) {
		alias K = VObjectKey;
		alias Tag = Kind.Object;
		alias isSimilarTo = isObjectValue;
	} else static if (T == MapKind.Map) {
		alias K = Value;
		alias Tag = Kind.Map;
		enum isSimilarTo(T) = isObjectValue!T || isMapValue!T;
	}

	struct Entry {
		K key;
		Value value;

		string dump() const {
			import std.format;
			return format!"%s: %s"(key.dump(), value.dump());
		}

	private:
		void init(SK, SV)(ref SK k, ref SV v) {
			clear();

			key = k;
			value = v;
		}

		void clear() {
			key.clear();
			value.clear();
		}

		void destroy() {
			key.destroy();
			value.destroy();
		}
	}

public:
	this(T)(T t) if (isSimilarTo!T) in(t.length <= int.max) {
		import core.memory;
		impl = allocateWithLength(t.length & uint.max);

		foreach (ref b; buckets) {
			b.clear();
		}

		uint i = 0;
		foreach (ref k, ref v; t) {
			entries[i].init(k, v);
			_insert(k, i++);
		}
	}

	void destroy() {
		foreach (ref e; entries) {
			e.destroy();
		}
	}

	@property
	uint length() const {
		return tag.length;
	}

	@property
	uint bucketCount() const {
		return 1 << lgBucketCount;
	}

	@property
	uint capacity() const {
		return 12 << lgBucketCount;
	}

	string dump() const {
		import std.algorithm, std.format;
		return format!"[%-(%s, %)]"(entries.map!(e => e.dump()));
	}

	@safe
	hash_t toHash() const nothrow {
		import config.hash;
		auto h = Hasher(length);

		foreach (ref e; entries) {
			h.mix(0x85ebca6bc2b2ae35);
			h.hash(e.key);
			h.mix(0xe6546b64cc9e2d51);
			h.hash(e.value);
		}

		return h.mix(0x4cf5ad432745937f);
	}

	uint find(K)(K key) const if (isKeyLike!K) {
		return _find(key);
	}

	inout(Value) at(size_t index) inout {
		if (index >= capacity) {
			// Return `Undefined` to signal we didn't find anything.
			return Value();
		}

		return entries[index].value;
	}

	inout(Value) opIndex(K)(K key) inout if (isKeyLike!K) {
		// TODO: Do not try to look for non string keys in Objects.
		return at(find(key));
	}

	inout(Value) opIndex(const VObjectKey key) inout {
		return key.isUndefined() ? Value() : this[key.str];
	}

	inout(Value)* opBinaryRight(string op : "in", K)(K key) inout
			if (isKeyLike!K) {
		auto index = find(key);
		if (index >= capacity) {
			// If it not in the map, then return null.
			return null;
		}

		return &entries[index].value;
	}

	bool opEquals(M)(M m) const if (isMapLike!M) {
		// Wrong length.
		if (length != m.length) {
			return false;
		}

		// Compare all the values.
		foreach (ref k, ref v; m) {
			if (this[k] != v) {
				return false;
			}
		}

		return true;
	}

	bool opEquals(const VObject rhs) const {
		// Wrong length.
		if (length != rhs.length) {
			return false;
		}

		// Compare all the values.
		foreach (ref e; entries) {
			if (rhs[e.key] != e.value) {
				return false;
			}
		}

		return true;
	}

	bool opEquals(const VMap rhs) const {
		// Wrong length.
		if (length != rhs.length) {
			return false;
		}

		// Compare all the values.
		foreach (ref e; entries) {
			if (rhs[e.key] != e.value) {
				return false;
			}
		}

		return true;
	}

	bool opEquals(const HeapValue rhs) const {
		if (rhs.isObject()) {
			return rhs.toVObject() == this;
		}

		if (rhs.isMap()) {
			return rhs.toVMap() == this;
		}

		return false;
	}

private:
	@property @trusted
	inout(Bucket)[] buckets() inout {
		auto ptr = cast(inout Bucket*) (impl + 1);
		return ptr[0 .. bucketCount];
	}

	@property @trusted
	inout(Entry)[] entries() inout {
		auto ptr = cast(inout Entry*) (buckets.ptr + bucketCount);
		return ptr[0 .. tag.length];
	}

	uint _find(K)(K key) const if (isKeyLike!K) {
		auto h = hash(key);
		auto p = Probe(h, bucketCount);

		foreach (_; 0 .. bucketCount) {
			auto b = &buckets[p.current];
			auto r = b.match(h);
			foreach (n; r) {
				auto index = b.indices[n];
				if (entries[index].key == key) {
					return index;
				}
			}

			if (b.overflow == 0) {
				break;
			}

			p.next();
		}

		// Return a sentinel to indicate absence.
		return -1;
	}

	void _insert(K)(K key, uint index) {
		auto h = hash(key);
		auto p = Probe(h, bucketCount);

		while (!buckets[p.current].insert(h, index)) {
			p.next();
		}
	}

	static allocateWithLength(uint length) {
		static uint countLeadingZeros(ulong x) {
			version(LDC) {
				import ldc.intrinsics;
				return llvm_ctlz(x, false) & uint.max;
			} else {
				foreach (uint i; 0 .. 8 * ulong.sizeof) {
					if (x & (long.min >> i)) {
						return i;
					}
				}

				return 8 * ulong.sizeof;
			}
		}

		static uint lg2Ceil(ulong x) in(x > 1) {
			enum uint S = 8 * ulong.sizeof;
			return S - countLeadingZeros(x - 1);
		}

		uint lgC = (length <= 12) ? 0 : lg2Ceil(((length - 1) / 12) + 1);

		import core.memory;
		auto ptr = cast(Impl*) GC.malloc(
			Impl.sizeof + ((Bucket.sizeof + 2 * 14 * Value.sizeof) << lgC),
			GC.BlkAttr.APPENDABLE
		);

		ptr.tag = Descriptor(Tag, length);
		ptr.lgBucketCount = lgC;

		return ptr;
	}
}

unittest {
	static testVObject(O : E[string], E)(O content) {
		auto o = VObject(content);
		assert(o.length == content.length);
		assert(o.capacity >= content.length);
		assert(o == content);

		auto m = VMap(content);

		assert(m.length == content.length);
		assert(m.capacity >= content.length);
		assert(m == content);
		assert(m == o);
		assert(o == m);

		foreach (k, v; content) {
			assert(o[k] == v, k);
			assert(k in o);
			assert(*(k in o) == v);

			assert(m[k] == v, k);
			assert(k in m);
			assert(*(k in m) == v);
		}

		// Key that doesn't exist.
		assert(("not in the map" in o) == null);
		assert(o["not in the map"].isUndefined());

		assert(("not in the map" in m) == null);
		assert(m["not in the map"].isUndefined());

		// Key that isn't a string.
		assert((42 in o) == null);
		assert(o[42].isUndefined());

		assert((42 in m) == null);
		assert(m[42].isUndefined());
	}

	Value[string] o;
	testVObject(o);

	testVObject(["foo": "bar"]);
	testVObject(["foo": "bar", "fizz": "buzz"]);

	uint[string] numbers =
		["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
		 "six": 6, "seven": 7, "eight": 8, "nine": 9];
	testVObject(numbers);

	numbers["ten"] = 10;
	testVObject(numbers);
	numbers["eleven"] = 11;
	testVObject(numbers);
	numbers["twelve"] = 12;
	testVObject(numbers);
	numbers["thriteen"] = 13;
	testVObject(numbers);
	numbers["fourteen"] = 14;
	testVObject(numbers);

	assert(VObject(["ping": "pong"]) != Value());
	assert(VObject(["ping": "pong"]) == Value(["ping": "pong"]));
	assert(VObject(["ping": "pong"]) == VMap(["ping": "pong"]));

	static testObjectEquality(T)(T t) {
		auto a = VObject(["ping": "pong"]);
		assert(a != t);
		assert(a != Value(t));
	}

	testObjectEquality(["foo": "bar"]);
	testObjectEquality([1: "fizz", 2: "buzz"]);

	assert(VMap(["ping": "pong"]) != Value());
	assert(VMap(["ping": "pong"]) == Value(["ping": "pong"]));
	assert(VMap(["ping": "pong"]) == VObject(["ping": "pong"]));

	static testMapEquality(T)(T t) {
		auto m = VMap(["ping": "pong"]);
		assert(m != t);
		assert(m != Value(t));
	}

	testMapEquality(["foo": "bar"]);
	testMapEquality([1: "fizz", 2: "buzz"]);
}
