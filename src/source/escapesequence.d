module source.escapesequence;

enum SequenceType {
	Invalid,
	Character,
	MultiCodePointHtmlEntity,
}

struct EscapeSequence {
private:
	import util.bitfields;
	enum TypeSize = EnumSize!SequenceType;
	enum ExtraBits = 8 * uint.sizeof - TypeSize;

	import std.bitmanip;
	mixin(bitfields!(
		// sdfmt off
		SequenceType, "_type", TypeSize,
		uint, "_extra", ExtraBits,
		// sdfmt on
	));

	union {
		wchar _second;

		import source.name;
		Name _name;
	}

	union {
		dchar _first;

		import source.decodedchar;
		DecodedChar _decodedChar;

		import source.location;
		Location _location;
	}

public:
	this(char c) {
		_type = SequenceType.Character;
		_decodedChar = DecodedChar(c);
	}

	this(dchar d) {
		_type = SequenceType.Character;
		_decodedChar = DecodedChar(d);
	}

	static fromError(Location location, Name error) {
		EscapeSequence r;
		r._type = SequenceType.Invalid;
		r._name = error;
		r._location = location;

		return r;
	}

	static multiCodePointHtmlEntity(dchar first, wchar second) {
		EscapeSequence r;
		r._type = SequenceType.MultiCodePointHtmlEntity;
		r._first = first;
		r._second = second;

		return r;
	}

	@property
	auto type() const {
		return _type;
	}

	@property
	auto location() const in(type == SequenceType.Invalid) {
		return _location;
	}

	@property
	auto error() const in(type == SequenceType.Invalid) {
		return _name;
	}

	@property
	auto decodedChar() const in(type == SequenceType.Character) {
		return _decodedChar;
	}

	@property
	auto first() const in(type == SequenceType.MultiCodePointHtmlEntity) {
		return _first;
	}

	@property
	auto second() const in(type == SequenceType.MultiCodePointHtmlEntity) {
		return _second;
	}

	string appendTo(string s) const in(type != SequenceType.Invalid) {
		if (type == SequenceType.Character) {
			return decodedChar.appendTo(s);
		}

		char[4] buf;

		import std.utf;
		auto i = encode(buf, first);
		s ~= buf[0 .. i];

		i = encode(buf, second);
		s ~= buf[0 .. i];

		return s;
	}
}

static assert(EscapeSequence.sizeof == 16);
