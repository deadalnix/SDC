module source.lexstring;

mixin template LexStringImpl(Token,
                             alias StringSuffixes = ["": "getStringLiteral"]) {
	/**
	 * Character literals.
	 */
	Token lexCharacter(string s : `'`)() {
		uint l = s.length;
		uint begin = index - l;

		if (reachedEOF()) {
			return getExpectedError(begin, "a character literal");
		}

		char c = frontChar;
		const start = index;
		auto dc = DecodedChar(c);

		switch (c) {
			case '\'':
				popChar();
				return getError(begin, "Character literal cannot be empty.");

			case '\\':
				popChar();

				auto es = lexEscapeSequence(start);
				if (es.type == SequenceType.Character) {
					dc = es.decodedChar;
					break;
				}

				assert(es.type == SequenceType.Invalid);
				if (frontChar == '\'') {
					popChar();
				}

				return getError(es.location, es.error);

			default:
				dchar d;

				import source.util.utf8;
				if (!decode(content, index, d)) {
					return getError(start, "Invalid UTF-8 sequence.");
				}

				dc = DecodedChar(d);
				break;
		}

		c = frontChar;
		if (c != '\'') {
			return getExpectedError(begin, "`\'` to end character literal");
		}

		popChar();

		auto location = base.getWithOffsets(begin, index);
		return Token.getCharacterLiteral(location, dc);
	}

	/**
	 * String literals.
	 */
	import source.name;
	auto lexStrignSuffix(uint begin, Name value) {
		return lexLiteralSuffix!StringSuffixes(begin, value);
	}

	auto getStringLiteral(string s : "")(Location location, Name value) {
		return Token.getStringLiteral(location, value);
	}

	Token buildRawString(uint begin, size_t start, size_t stop) {
		Name value = decodeLiterals
			? context.getName(content[start .. stop])
			: BuiltinName!"";
		return lexStrignSuffix(begin, value);
	}

	Token lexRawString(char Delimiter = '`')(uint begin) {
		size_t start = index;

		auto c = frontChar;
		while (c != Delimiter) {
			if (reachedEOF()) {
				import std.format;
				enum E = format!"'%s' to end string literal"(Delimiter);
				return getExpectedError(begin, E);
			}

			popChar();
			c = frontChar;
		}

		uint end = popChar();
		return buildRawString(begin, start, end);
	}

	Token lexString(string s : "`")() {
		uint l = s.length;
		return lexRawString!'`'(index - l);
	}

	Token lexString(string s : "'")() {
		uint l = s.length;
		return lexRawString!'\''(index - l);
	}

	Token lexDecodedString(char Delimiter = '"')(uint begin) {
		size_t start = index;
		string decoded;

		auto c = frontChar;
		while (c != Delimiter) {
			if (reachedEOF()) {
				import std.format;
				enum E = format!"'%s' to end string literal"(Delimiter);
				return getExpectedError(begin, E);
			}

			if (c != '\\') {
				popChar();
				c = frontChar;
				continue;
			}

			if (!decodeLiterals) {
				popChar();

				c = frontChar;
				if (c == '\0') {
					break;
				}

				popChar();
				c = frontChar;
				continue;
			}

			scope(success) {
				start = index;
			}

			// Workaround for https://issues.dlang.org/show_bug.cgi?id=22271
			if (decoded == "") {
				decoded = content[start .. index];
			} else {
				decoded ~= content[start .. index];
			}

			const beginEscape = index;
			popChar();

			auto es = lexEscapeSequence(beginEscape);
			if (es.type == SequenceType.Invalid) {
				return getError(es.location, es.error);
			}

			decoded = es.appendTo(decoded);
			c = frontChar;
		}

		uint end = popChar();

		Name value;
		if (decodeLiterals) {
			// Workaround for https://issues.dlang.org/show_bug.cgi?id=22271
			if (decoded == "") {
				decoded = content[start .. end];
			} else {
				decoded ~= content[start .. end];
			}

			value = context.getName(decoded);
		}

		return lexStrignSuffix(begin, value);
	}

	Token lexString(string s : `"`)() {
		uint l = s.length;
		return lexDecodedString!'"'(index - l);
	}

	/**
	 * Escape sequences.
	 */
	import source.escapesequence;
	auto getEscapeSequenceError(uint begin, string error) {
		return EscapeSequence.fromError(base.getWithOffsets(begin, index),
		                                context.getName(error));
	}

	EscapeSequence lexOctalEscapeSequence(uint begin) {
		uint r = 0;
		foreach (i; 0 .. 3) {
			auto c = frontChar;
			if (c < '0' || c > '7') {
				break;
			}

			popChar();
			r = (r * 8) | (c - '0');
			c = frontChar;
		}

		if (r <= 0xff) {
			return EscapeSequence(char(r & 0xff));
		}

		import std.format;
		return getEscapeSequenceError(
			begin,
			format!"Escape octal sequence \\%03o is larger than \\377."(r),
		);
	}

	bool decodeNHexCharacters(T)(ref T result) {
		enum N = 2 * T.sizeof;
		auto rc = remainingContent;

		import source.swar.hex;
		if (rc.length >= N && startsWithHexDigits!N(rc)) {
			import std.meta;
			alias I = AliasSeq!(ubyte, ushort, uint)[T.sizeof / 2];

			result = decodeHexDigits!I(rc);
			index += N;
			return true;
		}

		import source.util.ascii;
		for (size_t i = 0; i < N && isHexDigit(frontChar); i++) {
			popChar();
		}

		return false;
	}

	import source.decodedchar;
	EscapeSequence lexUnicodeEscapeSequence(char C)(uint begin)
			if (C == 'u' || C == 'U') {
		import std.meta;
		alias T = AliasSeq!(wchar, dchar)[C == 'U'];

		popChar();

		T v;
		if (decodeNHexCharacters(v)) {
			import std.utf;
			if (C == 'u' || isValidDchar(v)) {
				return EscapeSequence(v);
			}
		}

		import std.format;
		return getEscapeSequenceError(
			begin,
			format!"%s is not a valid unicode character."(
				content[begin .. index]),
		);
	}

	EscapeSequence lexEscapeSequence(uint begin) {
		dchar c = frontChar;
		switch (c) {
			case '\'', '"', '\\', '?', '$':
				break;

			case '0':
				c = '\0';
				break;

			case '1': .. case '7':
				return lexOctalEscapeSequence(begin);

			case 'a':
				c = '\a';
				break;

			case 'b':
				c = '\b';
				break;

			case 'f':
				c = '\f';
				break;

			case 'r':
				c = '\r';
				break;

			case 'n':
				c = '\n';
				break;

			case 't':
				c = '\t';
				break;

			case 'v':
				c = '\v';
				break;

			case 'x':
				popChar();

				char decoded;
				if (decodeNHexCharacters(decoded)) {
					return EscapeSequence(decoded);
				}

				import std.format;
				return getEscapeSequenceError(
					begin,
					format!"%s is not a valid hexadecimal sequence."(
						content[begin .. index])
				);

			case 'u':
				return lexUnicodeEscapeSequence!'u'(begin);

			case 'U':
				return lexUnicodeEscapeSequence!'U'(begin);

			case '&':
				assert(0, "HTML5 named character references not implemented");

			default:
				return getExpectedError!getEscapeSequenceError(
					begin, "a valid escape sequence", true);
		}

		popChar();
		return EscapeSequence(c);
	}
}

unittest {
	import source.context, source.dlexer;
	auto context = new Context();

	auto makeTestLexer(string s) {
		import source.location;
		auto base = context.registerMixin(Location.init, s);
		return lex(base, context);
	}

	auto checkLexChar(string s, uint expected) {
		auto lex = makeTestLexer(s);

		import source.parserutil;
		lex.match(TokenType.Begin);

		auto t = lex.match(TokenType.CharacterLiteral);
		assert(t.decodedChar.asIntegral == expected);

		assert(lex.front.type == TokenType.End);
		assert(lex.index == s.length + 1);
	}

	auto checkLexString(string s, string expected) {
		auto lex = makeTestLexer(s);

		import source.parserutil;
		lex.match(TokenType.Begin);

		auto t = lex.match(TokenType.StringLiteral);
		assert(t.decodedString.toString(context) == expected);

		assert(lex.front.type == TokenType.End);
		assert(lex.index == s.length + 1);
	}

	auto checkLexInvalid(string s, string expected) {
		auto lex = makeTestLexer(s);

		import source.parserutil;
		lex.match(TokenType.Begin);

		auto t = lex.match(TokenType.Invalid);
		auto error = t.error.toString(context);
		assert(error == expected, error);
	}

	auto checkTokenSequence(string s, TokenType[] tokenTypes) {
		auto lex = makeTestLexer(s);

		import source.parserutil;
		lex.match(TokenType.Begin);

		foreach (t; tokenTypes) {
			lex.match(t);
		}

		assert(lex.front.type == TokenType.End);
		assert(lex.index == s.length + 1);
	}

	// Check for plain old ASCII.
	checkLexString(`""`, "");
	checkLexString(`"foobar"`, "foobar");

	checkTokenSequence(`''""`, [TokenType.Invalid, TokenType.StringLiteral]);
	checkTokenSequence(`'a'""`,
	                   [TokenType.CharacterLiteral, TokenType.StringLiteral]);
	checkTokenSequence(`'\'""`, [TokenType.Invalid, TokenType.StringLiteral]);

	checkLexChar("'a'", 0x61);
	checkLexInvalid(`''`, "Character literal cannot be empty.");
	checkLexInvalid(`'aa'`, "Expected `'` to end character literal, not 'a'.");
	checkLexInvalid("'\xc0'", "Invalid UTF-8 sequence.");

	checkTokenSequence(
		`'aa'""`,
		[TokenType.Invalid, TokenType.Identifier, TokenType.Invalid,
		 TokenType.Invalid]
	);
	checkTokenSequence("'\\\xc0'``",
	                   [TokenType.Invalid, TokenType.StringLiteral]);

	// Invalid strings.
	checkLexInvalid(
		`"`, `Expected '"' to end string literal, not the end of the input.`);
	checkLexInvalid(
		"`", "Expected '`' to end string literal, not the end of the input.");

	// ASCII characters.
	checkLexChar("' '", 0x20);
	checkLexChar("'!'", 0x21);
	checkLexChar("'0'", 0x30);
	checkLexChar("'9'", 0x39);
	checkLexChar("'A'", 0x41);
	checkLexChar("'Z'", 0x5a);
	checkLexChar("'a'", 0x61);
	checkLexChar("'z'", 0x7a);
	checkLexChar("'~'", 0x7e);

	checkLexChar("'\0'", 0);
	checkLexChar("'\t'", 0x09);
	checkLexChar("'\r'", 0x0d);
	checkLexChar("'\n'", 0x0a);

	// Unfinished characters.
	checkLexInvalid(`'`,
	                "Expected a character literal, not the end of the input.");
	checkLexInvalid(
		"'a", "Expected `'` to end character literal, not the end of the input."
	);
	checkLexInvalid("'aa", "Expected `'` to end character literal, not 'a'.");
	checkLexInvalid("'a ", "Expected `'` to end character literal, not ' '.");
	checkLexInvalid("'a\n",
	                "Expected `'` to end character literal, not '\\n'.");
	checkLexInvalid("'αa", "Expected `'` to end character literal, not 'a'.");
	checkLexInvalid("'aα", "Expected `'` to end character literal, not 'α'.");
	checkLexInvalid(
		"'\0",
		"Expected `'` to end character literal, not the end of the input.");
	checkLexInvalid(
		"'\\", "Expected a valid escape sequence, not the end of the input.");
	checkLexInvalid("'\\\0", "Expected a valid escape sequence, not '\\0'.");
	checkLexInvalid(
		"'\\n",
		"Expected `'` to end character literal, not the end of the input.");

	// Check unicode support.
	checkLexString(`"\U0001F0BD\u0393α\u1FD6\u03B1\U0001FA01🙈🙉🙊\U0001F71A"`,
	               "🂽Γαῖα🨁🙈🙉🙊🜚");

	checkLexChar(`'\U0001F0BD'`, 0x1F0BD);
	checkLexChar(`'\u0393'`, 0x393);
	checkLexChar(`'α'`, 0x3B1);
	checkLexChar(`'\u1FD6'`, 0x1FD6);
	checkLexChar(`'\u03B1'`, 0x3B1);
	checkLexChar(`'\U0001FA01'`, 0x1FA01);
	checkLexChar(`'🙈'`, 0x1F648);
	checkLexChar(`'🙉'`, 0x1F649);
	checkLexChar(`'🙊'`, 0x1F64a);
	checkLexChar(`'\U0001FA01'`, 0x1FA01);

	checkLexInvalid(`"\U0001F0B`,
	                `\U0001F0B is not a valid unicode character.`);
	checkLexInvalid(`"\U0001F0B"`,
	                `\U0001F0B is not a valid unicode character.`);
	checkLexInvalid(`"\u039"`, `\u039 is not a valid unicode character.`);
	checkLexInvalid(`"\u039G"`, `\u039 is not a valid unicode character.`);
	checkLexInvalid(`"\u03@3"`, `\u03 is not a valid unicode character.`);

	checkTokenSequence(`'\U0001F0B'""`,
	                   [TokenType.Invalid, TokenType.StringLiteral]);
	checkTokenSequence(`'\U0001F0BD'""`,
	                   [TokenType.CharacterLiteral, TokenType.StringLiteral]);
	checkTokenSequence(
		`'\u03@3'""`,
		[TokenType.Invalid, TokenType.At, TokenType.IntegerLiteral,
		 TokenType.Invalid, TokenType.Invalid]
	);

	// Check other escaped characters.
	checkLexString(`"\'\"\?\$\0\a\b\f\r\n\t\v"`, "\'\"\?$\0\a\b\f\r\n\t\v");
	checkLexInvalid(`"\c"`, "Expected a valid escape sequence, not 'c'.");
	checkLexInvalid(`"\α"`, "Expected a valid escape sequence, not 'α'.");
	checkLexInvalid("'\\\0'", "Expected a valid escape sequence, not '\\0'.");

	checkLexChar(`'\"'`, 0x22);
	checkLexChar(`'\''`, 0x27);
	checkLexChar(`'\?'`, 0x3f);

	checkLexChar(`'\0'`, 0);
	checkLexChar(`'\a'`, 7);
	checkLexChar(`'\b'`, 8);
	checkLexChar(`'\t'`, 9);
	checkLexChar(`'\n'`, 10);
	checkLexChar(`'\v'`, 11);
	checkLexChar(`'\f'`, 12);
	checkLexChar(`'\r'`, 13);
	checkLexInvalid(`'\c'`, "Expected a valid escape sequence, not 'c'.");
	checkLexInvalid(`'\α'`, "Expected a valid escape sequence, not 'α'.");

	checkTokenSequence(`'\0'"\0"`,
	                   [TokenType.CharacterLiteral, TokenType.StringLiteral]);

	checkTokenSequence(`'\c'""`, [TokenType.Invalid, TokenType.StringLiteral]);
	checkTokenSequence(`'\α'""`, [TokenType.Invalid, TokenType.StringLiteral]);

	// Check hexadecimal escape sequences.
	checkLexString(`"\xfa\xff\x20\x00\xAA\xf0\xa0"`,
	               "\xfa\xff\x20\x00\xAA\xf0\xa0");
	checkLexInvalid(`"\xgg"`, `\x is not a valid hexadecimal sequence.`);

	checkLexChar(`'\xfa'`, 0xfa);
	checkLexChar(`'\xff'`, 0xff);
	checkLexChar(`'\x20'`, 0x20);
	checkLexChar(`'\x00'`, 0x00);
	checkLexChar(`'\xAA'`, 0xAA);
	checkLexChar(`'\xf0'`, 0xf0);
	checkLexChar(`'\xa0'`, 0xa0);
	checkLexInvalid(`'\xgg'`, `\x is not a valid hexadecimal sequence.`);

	checkTokenSequence(`'\x'""`, [TokenType.Invalid, TokenType.StringLiteral]);
	checkTokenSequence(`'\xf'""`, [TokenType.Invalid, TokenType.StringLiteral]);
	checkTokenSequence(`'\xff'""`,
	                   [TokenType.CharacterLiteral, TokenType.StringLiteral]);
	checkTokenSequence(
		`'\xgg""`,
		[TokenType.Invalid, TokenType.Identifier, TokenType.StringLiteral]
	);

	// Check octal escape sequences.
	checkLexString(`"\0\1\11\44\77\111\377"`, "\0\x01\x09\x24\x3f\x49\xff");
	checkLexString(`"\1111\378"`, "\x491\x1f8");
	checkLexInvalid(`"\400"`,
	                `Escape octal sequence \400 is larger than \377.`);

	checkLexChar(`'\0'`, 0);
	checkLexChar(`'\1'`, 0x01);
	checkLexChar(`'\11'`, 0x09);
	checkLexChar(`'\44'`, 0x24);
	checkLexChar(`'\77'`, 0x3f);
	checkLexChar(`'\111'`, 0x49);
	checkLexChar(`'\377'`, 0xff);
	checkLexInvalid(`'\1111'`,
	                "Expected `'` to end character literal, not '1'.");
	checkLexInvalid(`'\378'`,
	                "Expected `'` to end character literal, not '8'.");
	checkLexInvalid(`'\400'`,
	                `Escape octal sequence \400 is larger than \377.`);

	checkTokenSequence(`'\400'""`,
	                   [TokenType.Invalid, TokenType.StringLiteral]);
	checkTokenSequence(
		`'\378'""`,
		[TokenType.Invalid, TokenType.IntegerLiteral, TokenType.Invalid,
		 TokenType.Invalid]
	);
}
