module config.value;

import config.heap;
import config.map;
import config.traits;

class ValueException : Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__,
	     Throwable next = null) {
		super(msg, file, line, next);
	}
}

struct Value {
private:
	/**
	 * We use NaN boxing to pack all kind of values into a 64 bits payload.
	 * 
	 * NaN have a lot of bits we can play with in their payload. However,
	 * the range over which NaNs occuirs does not allow to store pointers
	 * 'as this'. This is a problem as the GC would then be unable to
	 * recognize them and might end up freeing live memory.
	 * 
	 * In order to work around that limitation, the whole range is shifted
	 * by FloatOffset so that the 0x0000 prefix overlap with pointers.
	 * 
	 * The value of the floating point number can be retrieved by
	 * subtracting FloatOffset from the payload's value.
	 * 
	 * The layout goes as follow:
	 * +--------+------------------------------------------------+
	 * | 0x0000 | true, false, null as well as pointers to heap. |
	 * +--------+--------+ --------------------------------------+
	 * | 0x0001 | 0x0000 | 32 bits integers.                     |
	 * +--------+--------+---------------------------------------+
	 * | 0x0002 |                                                |
	 * |  ....  | Positive floating point numbers.               |
	 * | 0x7ff1 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0x7ff2 |                                                |
	 * |  ....  | Infinity, signaling NaN.                       |
	 * | 0x7ff9 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0x7ffa |                                                |
	 * |  ....  | Quiet NaN. Unused.                             |
	 * | 0x8001 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0x8002 |                                                |
	 * |  ....  | Negative floating point numbers.               |
	 * | 0xfff1 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0xfff2 |                                                |
	 * |  ....  | -Infinity, signaling -NaN.                     |
	 * | 0xfff9 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0xfffa |                                                |
	 * |  ....  | Quiet -NaN. Unused.                            |
	 * | 0xffff |                                                |
	 * +--------+------------------------------------------------+
	 */
	union {
		ulong payload;
		HeapValue heapValue;
	}

	// We want the pointer values to be stored 'as this' so they can
	// be scanned by the GC. However, we also want to use the NaN
	// range in the double to store the pointers.
	// Because theses ranges overlap, we offset the values of the
	// double by a constant such as they do.
	enum FloatOffset = 0x0002000000000000;

	// If some of the bits in the mask are set, then this is a number.
	// If all the bits are set, then this is an integer.
	enum RangeMask = 0xffff000000000000;

	// For convenience, we provide prefixes.
	enum IntegerPrefix = 0x0001000000000000;

	// A series of flags that allow for quick checks.
	enum OtherFlag = 0x02;
	enum BoolFlag = 0x04;

	// Values for constants.
	enum TrueValue = OtherFlag | BoolFlag | true;
	enum FalseValue = OtherFlag | BoolFlag | false;
	enum NullValue = OtherFlag;
	enum UndefinedValue = 0x00;

public:
	this(T)(T t) if (isValue!T) {
		this = t;
	}

	this(this) {
		if (isHeapValue()) {
			heapValue.acquire();
		}
	}

	~this() {
		destroy();
	}

	package void clear() {
		payload = 0;
	}

	void destroy() {
		if (isHeapValue()) {
			heapValue.release();
		}

		clear();
	}

	bool isUndefined() const {
		return payload == UndefinedValue;
	}

	/**
	 * Primitive types support.
	 */
	bool isNull() const {
		return payload == NullValue;
	}

	bool isBoolean() const {
		return (payload | 0x01) == TrueValue;
	}

	@property
	bool boolean() const {
		if (isBoolean()) {
			return payload & 0x01;
		}

		import std.format;
		throw new ValueException(format!"%s is not a boolean."(dump()));
	}

	bool isInteger() const {
		return (payload & RangeMask) == IntegerPrefix;
	}

	@property
	int integer() const {
		if (isInteger()) {
			uint i = payload & uint.max;
			return i;
		}

		import std.format;
		throw new ValueException(format!"%s is not an integer."(dump()));
	}

	bool isNumber() const {
		return (payload & RangeMask) != 0;
	}

	bool isFloat() const {
		return payload >= FloatOffset;
	}

	@property
	double floating() const {
		if (isFloat()) {
			return Double(payload).toFloat();
		}

		import std.format;
		throw new ValueException(
			format!"%s is not a floating point number."(dump()));
	}

	/**
	 * Values that lives on the heap.
	 */
	@trusted
	private bool isHeapValue() const nothrow {
		if (heapValue is null) {
			return false;
		}

		return (payload & (RangeMask | OtherFlag)) == 0;
	}

	@property
	uint length() const in(isHeapValue()) {
		if (isHeapValue()) {
			return heapValue.length;
		}

		import std.format;
		throw new ValueException(format!"%s does not have length."(dump()));
	}

	inout(Value) at(size_t index) inout {
		return isHeapValue() ? heapValue.at(index) : Value();
	}

	inout(Value) opIndex(K)(K key) inout if (isKeyLike!K) {
		return isHeapValue() ? heapValue[key] : Value();
	}

	void opIndexAssign(K, V)(V value, K key) if (isKeyLike!K && isValue!V) {
		if (isHeapValue()) {
			heapValue[key] = value;
			return;
		}

		import std.format;
		throw new ValueException(
			format!"%s[%s] cannot be assigned to."(dump(), Value(key).dump()));
	}

	inout(Value)* opBinaryRight(string op : "in", K)(K key) inout
			if (isKeyLike!K) {
		return isHeapValue() ? key in heapValue : null;
	}

	static struct Range {
	private:
		Value data;
		uint start;
		uint stop;

		this(const ref Value data) {
			this.data = data;
			start = 0;
			stop = data.isHeapValue() ? data.length : 0;
		}

	public:
		@property
		Value front() const {
			return data.at(start);
		}

		void popFront() {
			start++;
		}

		@property
		Value back() const {
			return data.at(stop - 1);
		}

		void popBack() {
			stop--;
		}

		@property
		uint length() const {
			return (stop - start) & (empty - 1);
		}

		@property
		bool empty() const {
			return start >= stop;
		}
	}

	Range opSlice() const {
		return Range(this);
	}

	/**
	 * Strings.
	 */
	bool isString() const {
		return isHeapValue() && heapValue.isString();
	}

	string toString() const {
		if (isString()) {
			return heapValue.toVString().toString();
		}

		import std.format;
		throw new ValueException(format!"%s is not a string."(dump()));
	}

	/**
	 * Arrays.
	 */
	bool isArray() const {
		return isHeapValue() && heapValue.isArray();
	}

	/**
	 * Objects and Maps.
	 */
	bool isObject() const {
		return isHeapValue() && heapValue.isObject();
	}

	bool isMap() const {
		return isHeapValue() && heapValue.isMap();
	}

	/**
	 * Conversion.
	 */
	bool opCast(B : bool)() const {
		/**
		 * What is false? Baby don't hurt me...
		 *   - undefined
		 *   - null
		 *   - false (duh!)
		 *   - 0
		 *   - 0.0
		 *   - -0.0
		 *   - ""
		 *   - []
		 *   - {}
		 */
		enum FalseMask = OtherFlag | BoolFlag | IntegerPrefix;
		enum FloatMask = 0x7fffffffffffffff;
		if (((payload | FalseMask) == FalseMask)
			    || ((payload & FloatMask) == FloatOffset)) {
			return false;
		}

		return !isHeapValue() || length > 0;
	}

	/**
	 * Misc
	 */
	string dump() const {
		if (isUndefined()) {
			return "(undefined)";
		}

		if (isNull()) {
			return "null";
		}

		if (isBoolean()) {
			return boolean ? "true" : "false";
		}

		if (isInteger()) {
			import std.conv;
			return to!string(integer);
		}

		if (isFloat()) {
			import std.conv;
			return to!string(floating);
		}

		assert(isHeapValue());
		return heapValue.dump();
	}

	@trusted
	hash_t toHash() const nothrow {
		return isHeapValue() ? heapValue.toHash() : payload;
	}

	/**
	 * Assignement
	 */
	Value opAssign()(typeof(null) nothing) {
		destroy();
		payload = NullValue;
		return this;
	}

	Value opAssign(B : bool)(B b) {
		destroy();
		payload = OtherFlag | BoolFlag | b;
		return this;
	}

	// FIXME: Promote to float for large ints.
	Value opAssign(I : long)(I i) in((i & uint.max) == i) {
		destroy();
		payload = i | IntegerPrefix;
		return this;
	}

	Value opAssign(F : double)(F f) {
		destroy();
		payload = Double(f).toPayload();
		return this;
	}

	Value opAssign(V)(V v) if (.isHeapValue!V && !isBoxedValue!V) {
		destroy();
		heapValue = v;
		return this;
	}

	/**
	 * Equality
	 */
	bool opEquals(T : typeof(null))(T t) const {
		return isNull();
	}

	bool opEquals(B : bool)(B b) const {
		return payload == (OtherFlag | BoolFlag | b);
	}

	bool opEquals(I : long)(I i) const {
		return isInteger() && integer == i;
	}

	bool opEquals(F : double)(F f) const {
		return payload == Double(f).toPayload()
			|| Double(payload).toFloat() == f;
	}

	bool opEquals(V)(V v) const if (.isHeapValue!V || isBoxedHeapValue!V) {
		return isHeapValue() && heapValue == v;
	}

	bool opEquals(const Value rhs) const {
		return this == rhs;
	}

	bool opEquals(const ref Value rhs) const {
		if (rhs == Double(payload).toFloat()) {
			/**
			 * Floating point's NaN is usually not equal to itself.
			 * However, this forces us to special case them here,
			 * as well as prevent short circuit on identity for arrays,
			 * objects, maps and generally any structures that may
			 * contains a float.
			 *
			 * So instead, we consider that NaN == NaN. Voila!
			 */
			return true;
		}

		// If payload are not equal, then check for heap value.
		return isHeapValue() && rhs == heapValue;
	}
}

struct Double {
	double value;

	this(double value) {
		this.value = value;
	}

	this(ulong payload) {
		auto x = payload - Value.FloatOffset;
		this(*(cast(double*) &x));
	}

	double toFloat() const {
		return value;
	}

	ulong toPayload() const {
		auto x = *(cast(ulong*) &value);
		return x + Value.FloatOffset;
	}
}

// Assignement and comparison.
unittest {
	Value initVar;
	assert(initVar.isUndefined());
	assert(initVar == Value());

	import std.meta;
	alias Cases = AliasSeq!(
		// sdfmt off
		null,
		true,
		false,
		0,
		1,
		42,
		0.0,
		-0.0,
		3.141592,
		float.infinity,
		-float.infinity,
		float.nan,
		-float.nan,
		"",
		"foobar",
		[1, 2, 3],
		[1, 2, 3, 4],
		["y" : true, "n" : false],
		["x" : 3, "y" : 5],
		["foo" : "bar"],
		["fizz" : "buzz"],
		["first" : [1, 2], "second" : [3, 4]],
		[["a", "b"] : [1, 2], ["c", "d"] : [3, 4]]
		// sdfmt on
	);

	static testAllValues(string Type, E)(Value v, E expected) {
		assert(v.isNumber() == (Type == "Float" || Type == "Integer"));

		import std.format;
		assert(mixin(format!"v.is%s()"(Type)));

		static if (Type == "Boolean") {
			assert(v.boolean == expected);
		} else {
			import std.exception;
			assertThrown!ValueException(v.boolean);
		}

		static if (Type == "Integer") {
			assert(v.integer == expected);
		} else {
			import std.exception;
			assertThrown!ValueException(v.integer);
		}

		static if (Type == "Float") {
			assert(v.floating == expected || expected != expected);
		} else {
			import std.exception;
			assertThrown!ValueException(v.floating);
		}

		static if (Type == "String") {
			assert(v.toString() == expected);
		} else {
			import std.exception;
			assertThrown!ValueException(v.toString());
		}

		bool found = false;
		foreach (I; Cases) {
			static if (!is(E == typeof(I))) {
				assert(v != I);
			} else if (I is expected || I == expected) {
				found = true;
				assert(v == I);
			} else {
				assert(v != I);
			}
		}

		assert(found, v.dump());
	}

	static testValue(string Type, E)(E expected) {
		Value v = expected;
		testAllValues!Type(v, expected);
	}

	testValue!"Null"(null);
	testValue!"Boolean"(true);
	testValue!"Boolean"(false);
	testValue!"Integer"(0);
	testValue!"Integer"(1);
	testValue!"Integer"(42);
	testValue!"Float"(0.0);
	testValue!"Float"(-0.0);
	testValue!"Float"(3.141592);
	testValue!"Float"(float.infinity);
	testValue!"Float"(-float.infinity);
	testValue!"Float"(float.nan);
	testValue!"Float"(-float.nan);
	testValue!"String"("");
	testValue!"String"("foobar");
	testValue!"Array"([1, 2, 3]);
	testValue!"Array"([1, 2, 3, 4]);
	testValue!"Object"(["y": true, "n": false]);
	testValue!"Object"(["x": 3, "y": 5]);
	testValue!"Object"(["foo": "bar"]);
	testValue!"Object"(["fizz": "buzz"]);
	testValue!"Object"(["first": [1, 2], "second": [3, 4]]);
	testValue!"Map"([["a", "b"]: [1, 2], ["c", "d"]: [3, 4]]);
}

// length
unittest {
	assert(Value("").length == 0);
	assert(Value("abc").length == 3);
	assert(Value([1, 2, 3]).length == 3);
	assert(Value([1, 2, 3, 4, 5]).length == 5);
	assert(Value(["foo", "bar"]).length == 2);
	assert(Value([3.2, 37.5]).length == 2);
	assert(Value([3.2: "a", 37.5: "b", 1.1: "c"]).length == 3);
}

// indexing
unittest {
	Value s = "this is a string";
	assert(s[null].isUndefined());
	assert(s[true].isUndefined());
	assert(s[0].isUndefined());
	assert(s[1].isUndefined());
	assert(s[""].isUndefined());
	assert(s["foo"].isUndefined());

	Value a = [42];
	assert(a[null].isUndefined());
	assert(a[true].isUndefined());
	assert(a[0] == 42);
	assert(a[1].isUndefined());
	assert(a[""].isUndefined());
	assert(a["foo"].isUndefined());

	Value o = ["foo": "bar"];
	assert(o[null].isUndefined());
	assert(o[true].isUndefined());
	assert(o[0].isUndefined());
	assert(o[1].isUndefined());
	assert(o[""].isUndefined());
	assert(o["foo"] == "bar");

	Value m = [1: "one"];
	assert(m[null].isUndefined());
	assert(m[true].isUndefined());
	assert(m[0].isUndefined());
	assert(m[1] == "one");
	assert(m[""].isUndefined());
	assert(m["foo"].isUndefined());
}

// index assign
unittest {
	const Value base = [1, 2, 3, 4, 5];

	Value a = base;
	a[2] = "banana";

	foreach (i; 0 .. 5) {
		assert(base[i] == i + 1);

		if (i == 2) {
			assert(a[i] == "banana");
		} else {
			assert(a[i] == i + 1);
		}
	}

	a[10] = 123;
	foreach (i; 0 .. 10) {
		if (i == 2) {
			assert(a[i] == "banana");
		} else if (i == 10) {
			assert(a[i] == 123);
		} else if (i > 4) {
			assert(a[i].isUndefined());
		} else {
			assert(a[i] == i + 1);
		}
	}
}

// in operator
unittest {
	Value s = "this is a string";
	assert((null in s) == null);
	assert((true in s) == null);
	assert((0 in s) == null);
	assert((1 in s) == null);
	assert(("" in s) == null);
	assert(("foo" in s) == null);

	Value o = ["foo": "bar"];
	assert((null in o) == null);
	assert((true in o) == null);
	assert((0 in o) == null);
	assert((1 in o) == null);
	assert(("" in o) == null);
	assert(*("foo" in o) == "bar");

	Value m = [1: "one"];
	assert((null in m) == null);
	assert((true in m) == null);
	assert((0 in m) == null);
	assert(*(1 in m) == "one");
	assert(("" in m) == null);
	assert(("foo" in m) == null);
}

// range
unittest {
	void checkRange(T)(Value v, T[] expected) {
		assert(v.length == expected.length);
		assert(v[].length == expected.length);

		size_t i = 0;
		foreach (Value e; v[]) {
			assert(e == expected[i++]);
		}

		foreach_reverse (Value e; v[]) {
			assert(e == expected[--i]);
		}

		// Check that the length adapts when we pop elements.
		auto r = v[];
		assert(r.length == v.length);

		foreach (n; 0 .. v.length) {
			r.popFront();
			assert(r.length == v.length - n - 1);
		}

		// Pop past the end.
		r.popFront();
		assert(r.length == 0);
	}

	Value a = [1, 2, 3, 4, 5];
	checkRange(a, [1, 2, 3, 4, 5]);

	Value o = ["foo": "bar"];
	checkRange(o, ["bar"]);

	Value m = [1: "one"];
	checkRange(m, ["one"]);
}

// bool conversion
unittest {
	assert(!!Value() == false);
	assert(!!Value(null) == false);
	assert(!!Value(true) == true);
	assert(!!Value(false) == false);
	assert(!!Value(0) == false);
	assert(!!Value(1) == true);
	assert(!!Value(42) == true);
	assert(!!Value(0.0) == false);
	assert(!!Value(-0.0) == false);
	assert(!!Value(1.0) == true);
	assert(!!Value(-1.0) == true);
	assert(!!Value(float.infinity) == true);
	assert(!!Value(-float.infinity) == true);
	assert(!!Value(float.nan) == true);
	assert(!!Value(-float.nan) == true);
	assert(!!Value("") == false);
	assert(!!Value("hello!") == true);
	assert(!!Value((int[]).init) == false);
	assert(!!Value([1, 2, 3]) == true);
	assert(!!Value((string[string]).init) == false);
	assert(!!Value(["foo": "bar"]) == true);
	assert(!!Value((int[string]).init) == false);
	assert(!!Value([1: "one"]) == true);
}

// string conversion.
unittest {
	assert(Value().dump() == "(undefined)");
	assert(Value(null).dump() == "null");
	assert(Value(true).dump() == "true");
	assert(Value(false).dump() == "false");
	assert(Value(0).dump() == "0");
	assert(Value(1).dump() == "1");
	assert(Value(42).dump() == "42");

	// FIXME: I have not found how to write down float in a compact form that is
	// not ambiguous with an integer in some cases. Here, D writes '1' by default.
	// std.format is not of great help on that one.
	// assert(Value(1.0).dump() == "1.0");
	assert(Value(4.2).dump() == "4.2");
	assert(Value(0.5).dump() == "0.5");

	assert(Value("").dump() == `""`);
	assert(Value("abc").dump() == `"abc"`);
	assert(Value("\n\t\n").dump() == `"\n\t\n"`);
	assert(Value([1, 2, 3]).dump() == "[1, 2, 3]", Value([1, 2, 3]).dump());
	assert(Value(["y": true, "n": false]).dump() == `["y": true, "n": false]`);
	assert(Value([["a", "b"]: [1, 2], ["c", "d"]: [3, 4]]).dump()
		== `[["a", "b"]: [1, 2], ["c", "d"]: [3, 4]]`);
}

// Reference counting.
unittest {
	Value s = "foobar";
	assert(s.heapValue.refCount == 0);

	auto s2 = s;
	assert(s.heapValue.refCount == 2);

	Value a = ["foobar"];
	assert(a.heapValue.refCount == 0);
	assert(a[0].heapValue.refCount == 2);

	auto a2 = a;
	assert(a.heapValue.refCount == 2);
	assert(a[0].heapValue.refCount == 2);

	Value o = ["foo": "bar"];
	assert(o.heapValue.refCount == 0);
	assert(o["foo"].heapValue.refCount == 2);

	auto o2 = o;
	assert(o.heapValue.refCount == 2);
	assert(o["foo"].heapValue.refCount == 2);
}
