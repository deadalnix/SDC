module config.heap;

import config.map;
import config.traits;
import config.value;

enum Kind : ubyte {
	String,
	Array,
	Object,
	Map,
}

struct Descriptor {
package:
	Kind kind;
	ubyte refCount;

	uint length;

	static assert(Descriptor.sizeof == 8,
	              "Descriptors are expected to be 64 bits.");

	this(Kind kind, uint length) {
		this.kind = kind;
		this.refCount = 0;
		this.length = length;
	}

	bool release() {
		return HeapValue(&this).release();
	}

public:
	@safe @nogc
	bool isString() const pure nothrow {
		return kind == Kind.String;
	}

	@safe @nogc
	bool isArray() const pure nothrow {
		return kind == Kind.Array;
	}

	@safe @nogc
	bool isObject() const pure nothrow {
		return kind == Kind.Object;
	}

	@safe @nogc
	bool isMap() const pure nothrow {
		return kind == Kind.Map;
	}
}

struct HeapValue {
package:
	Descriptor* tag;
	alias tag this;

	this(const Descriptor* tag) {
		this.tag = cast(Descriptor*) tag;
	}

	this(H)(H h) if (isHeapValue!H || isBoxedHeapValue!H) {
		this = h;
	}

	static dispatch(alias fun, T, A...)(T t, A args) {
		if (t.isString()) {
			return fun(t.toVString(), args);
		}

		if (t.isArray()) {
			return fun(t.toVArray(), args);
		}

		if (t.isObject()) {
			return fun(t.toVObject(), args);
		}

		if (t.isMap()) {
			return fun(t.toVMap(), args);
		}

		assert(0, "Malformed HeapValue");
	}

	void acquire() {
		uint c = refCount + 2;
		refCount = (c | (c >> 8)) & 0xff;
	}

	bool release() {
		if (refCount != 0) {
			refCount -= 2;
			return false;
		}

		static fun(T)(T x) {
			return x.destroy();
		}

		dispatch!fun(this);

		import core.memory;
		GC.free(this);

		return true;
	}

package:
	@trusted @nogc
	ref inout(VString) toVString() inout nothrow pure return
	in(isString()) {
		return *(cast(inout(VString)*) &this);
	}

	@trusted @nogc
	ref inout(VArray) toVArray() inout nothrow pure return
	in(isArray()) {
		return *(cast(inout(VArray)*) &this);
	}

	@trusted @nogc
	ref inout(VObject) toVObject() inout nothrow pure return
	in(isObject()) {
		return *(cast(inout(VObject)*) &this);
	}

	@trusted @nogc
	ref inout(VMap) toVMap() inout nothrow pure return
	in(isMap()) {
		return *(cast(inout(VMap)*) &this);
	}

	/**
	 * Misc.
	 */
	string dump() const {
		static fun(T)(T x) {
			return x.dump();
		}

		return dispatch!fun(this);
	}

	@safe
	size_t toHash() const nothrow {
		@safe
		static fun(T)(T x) nothrow {
			return x.toHash();
		}

		return dispatch!fun(this);
	}

	/**
	 * Assignement.
	 */
	HeapValue opAssign(const Descriptor* tag) {
		this.tag = cast(Descriptor*) tag;
		return this;
	}

	HeapValue opAssign(const VString s) {
		return this = &s.tag;
	}

	HeapValue opAssign(const VArray a) {
		return this = &a.tag;
	}

	HeapValue opAssign(const VObject o) {
		return this = &o.tag;
	}

	HeapValue opAssign(const VMap m) {
		return this = &m.tag;
	}

	HeapValue opAssign(S)(S s) if (isStringValue!S) {
		return this = VString(s);
	}

	HeapValue opAssign(A)(A a) if (isArrayValue!A) {
		return this = VArray(a);
	}

	HeapValue opAssign(O)(O o) if (isObjectValue!O) {
		return this = VObject(o);
	}

	HeapValue opAssign(M)(M m) if (isMapValue!M) {
		return this = VMap(m);
	}

	/**
	 * Equality check.
	 */
	bool opEquals(S)(S s) const if (isStringValue!S) {
		return isString() && toVString() == s;
	}

	bool opEquals(A)(A a) const if (isArrayValue!A) {
		return isArray() && toVArray() == a;
	}

	bool opEquals(M)(M m) const if (isMapLike!M) {
		if (isObject()) {
			return toVObject() == m;
		}

		if (isMap()) {
			return toVMap() == m;
		}

		return false;
	}

	bool opEquals(const HeapValue rhs) const {
		if (tag == rhs.tag) {
			return true;
		}

		if (length != rhs.length) {
			return false;
		}

		if (isString()) {
			return toVString() == rhs;
		}

		if (isArray()) {
			return toVArray() == rhs;
		}

		if (isObject()) {
			return toVObject() == rhs;
		}

		if (isMap()) {
			return toVMap() == rhs;
		}

		assert(0, "Malformed HeapValue");
	}

	bool opEquals(V)(V v) const if (isPrimitiveValue!V) {
		return false;
	}

	/**
	 * Indexing features.
	 */
	inout(Value) at(size_t index) inout {
		if (isArray()) {
			return toVArray().at(index);
		}

		if (isObject()) {
			return toVObject().at(index);
		}

		if (isMap()) {
			return toVMap().at(index);
		}

		return Value();
	}

	inout(Value) opIndex(K)(K key) inout if (isKeyLike!K) {
		if (isArray()) {
			return toVArray()[key];
		}

		if (isObject()) {
			return toVObject()[key];
		}

		if (isMap()) {
			return toVMap()[key];
		}

		return Value();
	}

	void opIndexAssign(K, V)(V value, K key) if (isKeyLike!K && isValue!V) {
		if (isString()) {
			import std.format;
			throw new ValueException(
				format!"string %s cannot be assigned to."(dump()));
		}

		if (isArray()) {
			toVArray()[key] = value;
			return;
		}

		assert(0, "TODO");
	}

	inout(Value)* opBinaryRight(string op : "in", K)(K key) inout
			if (isKeyLike!K) {
		if (isObject()) {
			return key in toVObject();
		}

		if (isMap()) {
			return key in toVMap();
		}

		return null;
	}
}

unittest {
	HeapValue h = VString("test");
	assert(h != Value());

	static testHeapEquality(T)(T t) {
		HeapValue hvs = VString("test");
		assert(hvs != t);
		assert(hvs != Value(t));

		// A few of numbers chosen at random.
		// https://dilbert.com/strip/2001-10-25
		HeapValue hva = VArray([9, 9, 9, 9]);
		assert(hva != t);
		assert(hva != Value(t));

		HeapValue hvo = VObject(["ping": "pong"]);
		assert(hvo != t);
		assert(hvo != Value(t));

		HeapValue hvm = VMap(["ping": "pong"]);
		assert(hvm != t);
		assert(hvm != Value(t));
	}

	testHeapEquality("");
	testHeapEquality(1);
	testHeapEquality(2.3);
	testHeapEquality([1, 2, 3]);
	testHeapEquality(["foo": "bar"]);
	testHeapEquality([1: "fizz", 2: "buzz"]);
}

struct VString {
private:
	struct Impl {
		Descriptor tag;
	}

	Impl* impl;
	alias impl this;

public:
	this(string s) in(s.length < uint.max) {
		import core.memory;
		impl = cast(Impl*) GC
			.malloc(Impl.sizeof + s.length,
			        GC.BlkAttr.NO_SCAN | GC.BlkAttr.APPENDABLE);

		tag = Descriptor(Kind.String, s.length & uint.max);

		import core.stdc.string;
		memcpy(impl + 1, s.ptr, s.length);
	}

	void destroy() {}

	bool opEquals(string s) const {
		return toString() == s;
	}

	bool opEquals(const VString rhs) const {
		return this == rhs.toString();
	}

	bool opEquals(const HeapValue rhs) const {
		return rhs.isString() && rhs.toVString() == this;
	}

	@safe
	size_t toHash() const nothrow {
		import config.hash;
		return Hasher().hash(toString());
	}

	@trusted
	string toString() const nothrow {
		auto ptr = cast(immutable char*) (impl + 1);
		return ptr[0 .. tag.length];
	}

	string dump() const {
		import std.format;
		auto s = toString();
		return format!"%(%s%)"((&s)[0 .. 1]);
	}
}

unittest {
	static testString(string s) {
		auto sv = VString(s);
		assert(sv == s);

		auto sv2 = VString(s);
		assert(sv == sv2);

		import config.hash;
		assert(hash(sv) == hash(s));
	}

	testString("");
	testString("a");
	testString("toto");
	testString("\0\0\0\0\0\0\0");
	testString("🙈🙉🙊");

	assert(VString("test") != Value());
	assert(VString("test") == Value("test"));

	assert(VString("test") != "");
	assert(VString("test") != Value(""));
}

struct VArray {
private:
	struct Impl {
		Descriptor tag;
	}

	Impl* impl;
	alias impl this;

public:
	this(A)(A a) if (isArrayValue!A) in(a.length < uint.max) {
		impl = allocateWithLength(a.length & uint.max);

		foreach (i, ref e; toArray()) {
			e.clear();
			e = a[i];
		}
	}

	void destroy() {
		foreach (ref a; toArray()) {
			a.destroy();
		}
	}

	inout(Value) at(size_t index) inout {
		return this[index];
	}

	inout(Value) opIndex(size_t index) inout {
		return (index < tag.length) ? toArray()[index] : Value();
	}

	inout(Value) opIndex(const Value v) inout {
		return v.isInteger() ? this[v.integer] : Value();
	}

	inout(Value) opIndex(V)(V v) inout if (isValue!V) {
		return Value();
	}

	void opIndexAssign(I : uint, V)(V value, I index) if (isValue!V) {
		if (index >= tag.length || tag.refCount != 0) {
			auto old = this;

			import std.algorithm;
			auto l = max(tag.length, index + 1);
			impl = allocateWithLength(l);

			foreach (i, ref e; toArray()) {
				e.clear();
			}

			auto a = toArray().ptr;
			foreach (i, ref e; old.toArray()) {
				a[i] = e;
			}

			old.tag.release();
		}

		toArray().ptr[index] = value;
	}

	void opIndexAssign(K, V)(V value, K key) if (isKeyLike!K && isValue!V) {
		assert(0, "Promote to whatever.");
	}

	bool opEquals(A)(A a) const if (isArrayValue!A) {
		// Wrong length.
		if (tag.length != a.length) {
			return false;
		}

		foreach (i, ref _; a) {
			if (this[i] != a[i]) {
				return false;
			}
		}

		return true;
	}

	bool opEquals(const VArray rhs) const {
		return toArray() == rhs.toArray();
	}

	bool opEquals(const HeapValue rhs) const {
		return rhs.isArray() && rhs.toVArray() == this;
	}

	@safe
	size_t toHash() const nothrow {
		import config.hash;
		return Hasher().hash(toArray());
	}

	string dump() const {
		import std.algorithm, std.format;
		return format!"[%-(%s, %)]"(toArray().map!(v => v.dump()));
	}

	@trusted
	inout(Value)[] toArray() inout nothrow {
		auto ptr = cast(inout Value*) (impl + 1);
		return ptr[0 .. tag.length];
	}

	static allocateWithLength(uint length) {
		import core.memory;
		auto ptr = cast(Impl*) GC
			.malloc(Impl.sizeof + Value.sizeof * length, GC.BlkAttr.APPENDABLE);

		ptr.tag = Descriptor(Kind.Array, length);
		return ptr;
	}
}

unittest {
	static testArray(T)(T[] a) {
		auto va = VArray(a);
		assert(va == a);

		import std.algorithm, std.array;
		auto a2 = a.map!(e => Value(e)).array();
		auto va2 = VArray(a2);
		assert(va2 == a);
		assert(va2 == va);
		assert(va2 == a2);

		import config.hash;
		assert(hash(va) == hash(a));
		assert(hash(va2) == hash(a));
		assert(hash(va2) == hash(va));
		assert(hash(va2) == hash(a2));
	}

	int[] empty;
	testArray(empty);
	testArray(["", "foo", "bar"]);
	testArray([1, 2, 3, 4, 5]);

	assert(VArray([9, 9, 9, 9]) != Value());
	assert(VArray([9, 9, 9, 9]) == Value([9, 9, 9, 9]));

	assert(VArray([9, 9, 9, 9]) != ["foo", "bar"]);
	assert(VArray([9, 9, 9, 9]) != Value(["foo", "bar"]));

	auto a = VArray([0, 11, 22, 33, 44, 55]);
	assert(a[-1].isUndefined());
	assert(a[6].isUndefined());
	assert(a[""].isUndefined());
	assert(a["foo"].isUndefined());

	foreach (i; 0 .. 6) {
		assert(a[i] == 11 * i);
		assert(a[Value(i)] == 11 * i);
	}
}
