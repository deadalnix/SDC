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
	 * 'as this'. this is a problem as the GC would then be unable to
	 * recognize them and might end up freeing live memory.
	 * 
	 * In order to work around that limitation, the whole range is
	 * shifted by FloatOffset so that the 0x0000 prefix overlap
	 * with pointers.
	 * 
	 * The value of the floating point number can be retrieved by
	 * subtracting FloatOffset from the payload's value.
	 * 
	 * The layout goes as follow:
	 * +--------+------------------------------------------------+
	 * | 0x0000 | true, false, null as well as pointers to heap. |
	 * +--------+------------------------------------------------+
	 * | 0x0001 |                                                |
	 * |  ....  | Positive floating point numbers.               |
	 * | 0x7ff0 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0x7ff1 |                                                |
	 * |  ....  | Infinity, signaling NaN.                       |
	 * | 0x7ff8 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0x7ff9 |                                                |
	 * |  ....  | Quiet NaN. Unused.                             |
	 * | 0x8000 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0x8001 |                                                |
	 * |  ....  | Negative floating point numbers.               |
	 * | 0xfff0 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0xfff1 |                                                |
	 * |  ....  | -Infinity, signaling -NaN.                     |
	 * | 0xfff8 |                                                |
	 * +--------+------------------------------------------------+
	 * | 0xfff9 |                                                |
	 * |  ....  | Quiet -NaN. Unused.                            |
	 * | 0xfffe |                                                |
	 * +--------+--------+ --------------------------------------+
	 * | 0xffff | 0x0000 | 32 bits integers.                     |
	 * +--------+--------+---------------------------------------+
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
	enum FloatOffset = 0x0001000000000000;

	// If some of the bits in the mask are set, then this is a number.
	// If all the bits are set, then this is an integer.
	enum RangeMask = 0xffff000000000000;

	// For convenience, we provide prefixes
	enum HeapPrefix = 0x0000000000000000;
	enum IntegerPrefix = 0xffff000000000000;

	// A series of flags that allow for quick checks.
	enum OtherFlag = 0x02;
	enum BoolFlag = 0x04;

	// Values for constants.
	enum TrueValue = OtherFlag | BoolFlag | true;
	enum FalseValue = OtherFlag | BoolFlag | false;
	enum NullValue = OtherFlag;
	enum UndefinedValue = 0x00;

public:
	this(T)(T t) {
		this = t;
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
		return isNumber() && !isInteger();
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
	private bool isHeapValue() const nothrow {
		if (heapValue is null) {
			return false;
		}

		return (payload & (RangeMask | OtherFlag)) == HeapPrefix;
	}

	@property
	size_t length() const in(isHeapValue()) {
		if (isHeapValue()) {
			return heapValue.length;
		}

		import std.format;
		throw new ValueException(format!"%s does not have length."(dump()));
	}

	inout(Value) opIndex(K)(K key) inout if (isKeyLike!K) {
		return isHeapValue() ? heapValue[key] : Value();
	}

	inout(Value)* opBinaryRight(string op : "in", K)(K key) inout
			if (isKeyLike!K) {
		return isHeapValue() ? key in heapValue : null;
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

	inout(Value)[] toArray() inout {
		if (isArray()) {
			return heapValue.toVArray().toArray();
		}

		import std.format;
		throw new ValueException(format!"%s is not an array."(dump()));
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
		payload = NullValue;
		return this;
	}

	Value opAssign(B : bool)(B b) {
		payload = OtherFlag | BoolFlag | b;
		return this;
	}

	// FIXME: Promote to float for large ints.
	Value opAssign(I : long)(I i) in((i & uint.max) == i) {
		payload = i | IntegerPrefix;
		return this;
	}

	Value opAssign(F : double)(F f) {
		payload = Double(f).toPayload();
		return this;
	}

	Value opAssign(V)(V v) if (.isHeapValue!V) {
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
		return isBoolean() && boolean == b;
	}

	bool opEquals(I : long)(I i) const {
		return isInteger() && integer == i;
	}

	bool opEquals(F : double)(F f) const {
		return isFloat() && floating == f;
	}

	bool opEquals(const Value rhs) const {
		// Special case floating point, because NaN != NaN .
		if (isFloat() || rhs.isFloat()) {
			return isFloat() && rhs.isFloat() && floating == rhs.floating;
		}

		// Floating point's NaN is the only value that is not equal to itself.
		if (payload == rhs.payload) {
			return true;
		}

		return isHeapValue() && rhs == heapValue;
	}

	bool opEquals(V)(V v) const if (.isHeapValue!V) {
		return isHeapValue() && heapValue == v;
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
	import std.meta;
	alias Cases = AliasSeq!(
		// sdfmt off
		null,
		true,
		false,
		0,
		1,
		42,
		0.,
		3.141592,
		// float.nan,
		float.infinity,
		-float.infinity,
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
			assert(v.floating == expected);
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

		static if (Type == "Array") {
			assert(v.toArray() == expected);
		} else {
			import std.exception;
			assertThrown!ValueException(v.toArray());
		}

		bool found = false;
		foreach (I; Cases) {
			static if (!is(E == typeof(I))) {
				assert(v != I);
			} else if (I == expected) {
				found = true;
				assert(v == I);
			} else {
				assert(v != I);
			}
		}

		import std.conv;
		assert(found, to!string(v));
	}

	Value initVar;
	assert(initVar.isUndefined());
	assert(initVar == Value());

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
	testValue!"Float"(0.);
	testValue!"Float"(3.141592);
	// testValue!"Float"(float.nan);
	testValue!"Float"(float.infinity);
	testValue!"Float"(-float.infinity);
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
	auto s = Value("this is a string");
	assert(s[null].isUndefined());
	assert(s[true].isUndefined());
	assert(s[0].isUndefined());
	assert(s[1].isUndefined());
	assert(s[""].isUndefined());
	assert(s["foo"].isUndefined());

	auto a = Value([42]);
	assert(a[null].isUndefined());
	assert(a[true].isUndefined());
	assert(a[0] == 42);
	assert(a[1].isUndefined());
	assert(a[""].isUndefined());
	assert(a["foo"].isUndefined());

	auto o = Value(["foo": "bar"]);
	assert(o[null].isUndefined());
	assert(o[true].isUndefined());
	assert(o[0].isUndefined());
	assert(o[1].isUndefined());
	assert(o[""].isUndefined());
	assert(o["foo"] == "bar");

	auto m = Value([1: "one"]);
	assert(m[null].isUndefined());
	assert(m[true].isUndefined());
	assert(m[0].isUndefined());
	assert(m[1] == "one");
	assert(m[""].isUndefined());
	assert(m["foo"].isUndefined());
}

// in operator
unittest {
	auto s = Value("this is a string");
	assert((null in s) == null);
	assert((true in s) == null);
	assert((0 in s) == null);
	assert((1 in s) == null);
	assert(("" in s) == null);
	assert(("foo" in s) == null);

	auto o = Value(["foo": "bar"]);
	assert((null in o) == null);
	assert((true in o) == null);
	assert((0 in o) == null);
	assert((1 in o) == null);
	assert(("" in o) == null);
	assert(*("foo" in o) == "bar");

	auto m = Value([1: "one"]);
	assert((null in m) == null);
	assert((true in m) == null);
	assert((0 in m) == null);
	assert(*(1 in m) == "one");
	assert(("" in m) == null);
	assert(("foo" in m) == null);
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
