module format.parser;

/**
 * While we already have a parser in libd, we cannot use it here.
 * This is because libd's parser is meant to validate that the source
 * is well a formed D program. However, we want to be able to format
 * even incomplete programs as part of the developper's process.
 *
 * This parser, on the other hand, is meant to recognize common patterns
 * in the language, without ensuring that they are indeed correct.
 */
struct Parser {
private:
	import source.dlexer;
	TokenRange trange;

	import format.chunk;
	Builder builder;

	bool needDoubleIndent = false;
	bool doubleIndentBlock = false;
	bool canBeDeclaration = false;
	bool expectParameters = false;

	enum Mode {
		Declaration,
		Statement,
		Parameter,
	}

	Mode mode;

	auto changeMode(Mode m) {
		static struct Guard {
			~this() {
				parser.mode = oldMode;
			}

		private:
			Parser* parser;
			Mode oldMode;
		}

		Mode oldMode = mode;
		mode = m;

		return Guard(&this, oldMode);
	}

	/**
	 * When we can't parse we skip and forward chunks "as this"
	 */
	Location skipped;

	/**
	 * Comments to be emitted before the next token.
	 *  - inFlightComments: Comments which are on their own.
	 *  - nextComments: Comment attached to what comes next.
	 */
	Location[] inFlightComments;
	Location[] nextComments;

	/**
	 * Passthrough for portion of code not to be formatted.
	 *
	 * When formatting is disabled, we keep parsing anyways. This ensures
	 * the state of affairs, such as identation levels, are kept track off.
	 * However, nothign is sent to the builder as parsing progresses, and
	 * everything is sent as one signle chunk at the end of it.
	 */
	Position sdfmtOffStart;

	bool skipFormatting() const {
		return sdfmtOffStart != Position();
	}

public:
	import source.context;
	this(Position base, Context context) {
		this.trange = lex(base, context).getLookahead().withComments();
	}

	Chunk[] parse() in(match(TokenType.Begin)) {
		// Emit the shebang if there is one.
		write(token.location, token.toString(context));
		trange.popFront();
		newline();

		parseComments();

		parseModule();

		assert(match(TokenType.End));

		emitSkippedTokens();
		flushComments();

		return builder.build();
	}

private:
	/**
	 * Chunk builder facilities
	 */
	void write(Location loc, string s) {
		if (skipFormatting()) {
			return;
		}

		if (newLineCount(loc) == 0) {
			builder.write(s);
			return;
		}

		// We have a multi line chunk.
		import std.array;
		foreach (i, l; s.split('\n')) {
			if (i > 0) {
				builder.split(true, true);
				builder.newline(1);
			}

			builder.write(l);
		}
	}

	void space() {
		if (skipFormatting()) {
			return;
		}

		builder.space();
	}

	void newline() {
		newline(newLineCount());
	}

	void newline(int nl) {
		if (skipFormatting()) {
			return;
		}

		builder.newline(nl);
	}

	void clearSeparator() {
		if (skipFormatting()) {
			return;
		}

		builder.clearSeparator();
	}

	void split(bool glued = false, bool continuation = false,
	           bool naturalBreak = false) {
		emitRawContent();
		builder.split(glued || skipFormatting(), continuation, naturalBreak);
	}

	auto wrappedGuard(alias buildGuard, T...)(T args) {
		alias G = typeof(buildGuard(&this, args));

		static struct Guard {
			this(T...)(Parser* parser, T args) {
				this._guard = buildGuard(parser, args);
				this.parser = parser;
			}

			~this() {
				parser.emitRawContent();
			}

			alias guard this;
			@property
			auto ref guard() {
				return _guard;
			}

		private:
			Parser* parser;
			G _guard;
		}

		return Guard(&this, args);
	}

	auto indent(uint level = 1) {
		return wrappedGuard!((Parser* p, uint l) => p.builder.indent(l))(level);
	}

	auto unindent(uint level = 1) {
		return
			wrappedGuard!((Parser* p, uint l) => p.builder.unindent(l))(level);
	}

	import format.span;
	auto span(S = Span, T...)(T args) {
		emitSkippedTokens();
		emitInFlightComments();

		return
			wrappedGuard!((Parser* p, T args) => p.builder.span!S(args))(args);
	}

	auto spliceSpan(S = Span, T...)(T args) {
		emitSkippedTokens();
		emitInFlightComments();

		return wrappedGuard!(
			(Parser* p, T args) => p.builder.spliceSpan!S(args))(args);
	}

	auto block() {
		emitRawContent();

		static emitNewLine(Parser* parser) {
			parser.newline(1);
		}

		return wrappedGuard!((Parser* p) => p.builder.block!emitNewLine(p))();
	}

	/**
	 * Miscellaneous and conveniences.
	 */
	@property
	auto context() {
		return trange.context;
	}

	/**
	 * Whitespace management.
	 */
	import source.location;
	uint getLineNumber(Position p) {
		return p.getFullPosition(context).getLineNumber();
	}

	uint getLineNumber(ref TokenRange r) {
		return getLineNumber(r.front.location.stop);
	}

	uint getLineNumber() {
		return getLineNumber(trange);
	}

	int newLineCount(Position start, Position stop) {
		return getLineNumber(stop) - getLineNumber(start);
	}

	int newLineCount(Location location) {
		return newLineCount(location.start, location.stop);
	}

	int newLineCount(ref TokenRange r) {
		return newLineCount(r.previous, r.front.location.start);
	}

	int newLineCount() {
		return newLineCount(trange);
	}

	uint getSourceOffset(Position p) {
		return p.getFullPosition(context).getSourceOffset();
	}

	int whiteSpaceLength(Position start, Position stop) {
		return getSourceOffset(stop) - getSourceOffset(start);
	}

	int whiteSpaceLength() {
		return whiteSpaceLength(trange.previous, token.location.start);
	}

	void emitSourceBasedWhiteSpace(Position previous, Location current) {
		if (auto nl = newLineCount(previous, current.start)) {
			newline(nl);
			return;
		}

		if (whiteSpaceLength(previous, current.start) > 0) {
			space();
		}
	}

	void emitSourceBasedWhiteSpace() {
		emitSourceBasedWhiteSpace(trange.previous, token.location);
	}

	/**
	 * Token processing.
	 */
	@property
	Token token() const {
		return trange.front;
	}

	bool match(TokenType t) {
		return token.type == t;
	}

	auto runOnType(TokenType T, alias fun)() {
		if (match(T)) {
			return fun();
		}
	}

	void nextToken() {
		emitSkippedTokens();
		flushComments();

		if (match(TokenType.End)) {
			// We reached the end of our input.
			return;
		}

		// Process current token.
		write(token.location, token.toString(context));

		trange.popFront();
		parseComments();
	}

	/**
	 * We skip over portions of the code we can't parse.
	 */
	void skipToken() {
		flushComments();

		if (skipped.length == 0) {
			emitSourceBasedWhiteSpace();
			space();
			split();

			skipped = Location(trange.previous, token.location.stop);
		} else {
			skipped = skipped.spanTo(token.location);
		}

		if (match(TokenType.End)) {
			// We skipped until the end.
			return;
		}

		trange.popFront();

		// Skip over comments that look related too.
		while (match(TokenType.Comment) && newLineCount() == 0) {
			skipped = skipped.spanTo(token.location);
			trange.popFront();
		}

		parseComments();
	}

	void emitSkippedTokens() {
		if (skipped.length == 0) {
			return;
		}

		import std.string;
		auto str = skipped.getFullLocation(context).getSlice().strip();
		write(skipped, str);
		skipped = Location.init;

		emitSourceBasedWhiteSpace();
		split();
	}

	/**
	 * Unformated code management.
	 */
	void emitRawContent() {
		auto upTo = inFlightComments.length > 0
			? inFlightComments[0]
			: nextComments.length > 0 ? nextComments[0] : token.location;

		emitRawContent(upTo.start);
	}

	void emitRawContent(Position upTo) {
		if (!skipFormatting()) {
			return;
		}

		builder.write(
			Location(sdfmtOffStart, upTo).getFullLocation(context).getSlice());
		sdfmtOffStart = upTo;
	}

	/**
	 * Comments management
	 */
	void emitComment(Location loc, Position previous) {
		emitSourceBasedWhiteSpace(previous, loc);

		import std.string;
		auto comment = loc.getFullLocation(context).getSlice().strip();
		if (skipFormatting() && comment == "// sdfmt on") {
			emitRawContent(loc.start);
			sdfmtOffStart = Position();
		}

		write(loc, comment);

		if (comment == "// sdfmt off") {
			sdfmtOffStart = loc.stop;
			assert(skipFormatting(), "We should start skipping.");
		}

		// Make sure we have a line split after // style comments.
		if (!skipFormatting() && comment.startsWith("//")) {
			newline(1);
			split();
		}
	}

	void emitComments(ref Location[] commentBlock, Location nextTokenLoc) {
		if (commentBlock.length == 0) {
			return;
		}

		scope(success) {
			commentBlock = [];
		}

		Position previous = commentBlock[0].start;

		foreach (loc; commentBlock) {
			scope(success) {
				previous = loc.stop;
			}

			emitComment(loc, previous);
		}

		emitSourceBasedWhiteSpace(previous, nextTokenLoc);
	}

	void emitInFlightComments() {
		auto nextTokenLoc =
			nextComments.length > 0 ? nextComments[0] : token.location;

		emitComments(inFlightComments, nextTokenLoc);
	}

	void flushComments() {
		emitInFlightComments();
		emitComments(nextComments, token.location);
	}

	bool hasComments() {
		return inFlightComments.length > 0 || nextComments.length > 0;
	}

	void parseComments() in(inFlightComments == [] && nextComments == []) {
		if (!match(TokenType.Comment)) {
			return;
		}

		emitSkippedTokens();

		/**
		 * We distrube comments in 3 groups:
		 *   1 - The comments attached to the previous structural element.
		 *   2 - The comments in flight between two structural elements.
		 *   3 - The comments attached to the next structural element.
		 * We want to emit group 1 right away, but wait for later when
		 * emitting groups 2 and 3.
		 */
		while (match(TokenType.Comment) && newLineCount() == 0) {
			emitComment(token.location, trange.previous);
			trange.popFront();
		}

		emitSourceBasedWhiteSpace();

		Location[] commentBlock = [];
		while (match(TokenType.Comment)) {
			commentBlock ~= token.location;
			trange.popFront();

			if (newLineCount() < 2) {
				continue;
			}

			inFlightComments ~= commentBlock;
			commentBlock = [];
		}

		nextComments = commentBlock;
	}

	/**
	 * Parsing
	 */
	void parseModule() {
		auto guard = changeMode(Mode.Declaration);

		while (!match(TokenType.End)) {
			parseStructuralElement();
		}

		// In case there is still some unformatted content in the pipe.
		emitRawContent();
	}

	void parseStructuralElement() {
		emitInFlightComments();

		canBeDeclaration = true;

	Entry:
		switch (token.type) with (TokenType) {
			case End:
				return;

			case Module:
				parseModuleDeclaration();
				break;

			/**
			 * Misc
			 */
			case DotDotDot:
				nextToken();
				return;

			/**
			 * Statements
			 */
			case OpenBrace:
				parseBlock(mode);

				// Blocks do not end with a semicolon.
				return;

			case Identifier:
				auto lookahead = trange.getLookahead();
				lookahead.popFront();
				auto t = lookahead.front.type;

				if (mode == Mode.Parameter
					    && (t == Colon || t == Equal || t == DotDotDot)) {
					parseTemplateParameter();
					break;
				}

				if (t != Colon) {
					// This is an expression or a declaration.
					goto default;
				}

				lookahead.popFront();
				if (newLineCount(lookahead) == 0) {
					nextToken();
					nextToken();
					space();
					goto Entry;
				}

				{
					auto guard = unindent();
					newline(2);
					nextToken();
				}

				parseColonBlock();
				break;

			case If:
				parseIf();
				break;

			case Version, Debug:
				parseVersion();
				break;

			case Else:
				parseElse();
				break;

			case While:
				parseWhile();
				break;

			case Do:
				parseDoWhile();
				break;

			case For:
				parseFor();
				break;

			case Foreach, ForeachReverse:
				withCaseLevelIndent!parseForeach();
				break;

			case Return:
				// If this is a parameter, then return is a storage class.
				if (mode == Mode.Parameter) {
					goto default;
				}

				goto ReturnLike;

			case Throw:
				goto ReturnLike;

			ReturnLike:
				parseReturn();
				break;

			case Break, Continue:
				nextToken();

				if (match(Identifier)) {
					space();
					nextToken();
				}

				break;

			case With:
				parseWith();
				break;

			case Switch:
				parseSwitch();
				break;

			case Case:
				{
					auto guard = unindent();
					newline();

					while (true) {
						nextToken();
						space();

						parseList!parseExpression(TokenType.Colon);

						if (!match(DotDot)) {
							break;
						}

						space();
						nextToken();
						space();
					}
				}

				parseColonBlock();
				break;

			case Default:
				{
					auto guard = unindent();
					newline();
					nextToken();
				}

				parseColonBlock();
				break;

			case Goto:
				nextToken();
				if (match(Identifier) || match(Default)) {
					space();
					nextToken();
				} else if (match(Case)) {
					space();
					nextToken();

					if (!match(Semicolon)) {
						space();
						parseExpression();
					}
				}

				break;

			case Try:
				parseTry();
				break;

			case Catch:
				parseCatch();
				break;

			case Finally:
				parseFinally();
				break;

			case Scope:
				parseScope();
				break;

			case Assert:
				parseExpression();
				break;

			/**
			 * Compile time constructs.
			 */
			case Static:
				withCaseLevelIndent!parseStatic();
				break;

			case Mixin:
				parseMixin();
				break;

			/**
			 * Declaration
			 */
			case This:
				// This template parameters.
				auto lookahead = trange.getLookahead();
				lookahead.popFront();

				auto t = lookahead.front.type;
				if (t == TokenType.Identifier) {
					nextToken();
					space();
					parseTypedDeclaration();
					break;
				}

				if (t != TokenType.OpenParen || mode != Mode.Declaration) {
					// This is an expression.
					goto default;
				}

				parseConstructor();
				break;

			case Tilde:
				// Check for destructors.
				auto lookahead = trange.getLookahead();
				lookahead.popFront();

				if (lookahead.front.type != TokenType.This) {
					// This is an expression.
					goto default;
				}

				lookahead.popFront();

				auto t = lookahead.front.type;
				if (t != TokenType.OpenParen || mode != Mode.Declaration) {
					// This is an expression.
					goto default;
				}

				parseDestructor();
				break;

			case Template:
				parseTemplate();
				break;

			case Import:
				auto lookahead = trange.getLookahead();
				lookahead.popFront();

				if (lookahead.front.type == TokenType.OpenParen) {
					// This is an import expression.
					goto default;
				}

				parseImport();
				break;

			case Unittest:
				nextToken();
				space();

				if (match(Identifier)) {
					nextToken();
					space();
				}

				parseBlock(Mode.Statement);

				// Blocks do not end with a semicolon.
				return;

			case Invariant:
				nextToken();
				parseArgumentList();

				if (!match(OpenBrace)) {
					break;
				}

				space();
				parseBlock(Mode.Statement);

				// Blocks do not end with a semicolon.
				return;

			case Struct, Union, Class, Interface:
				parseAggregate();
				break;

			default:
				if (parseStorageClassDeclaration()) {
					break;
				}

				if (!parseIdentifier()) {
					// We made no progress, start skipping.
					skipToken();
					return;
				}

				if (match(Identifier)) {
					// We have a declaration.
					parseTypedDeclaration();
					break;
				}

				// We just have some kind of expression.
				parseAssignExpressionSuffix();
				break;
		}

		if (mode != Mode.Parameter) {
			if (match(TokenType.Semicolon)) {
				nextToken();
				newline();
			} else {
				emitSourceBasedWhiteSpace();
			}
		}
	}

	/**
	 * Structural elements.
	 */
	void parseModuleDeclaration() in(match(TokenType.Module)) {
		nextToken();
		space();
		parseIdentifier();
	}

	/**
	 * Identifiers
	 */
	enum IdentifierKind {
		None,
		Symbol,
		Type,
		Expression,
	}

	bool parseIdentifier(IdentifierKind expected = IdentifierKind.Symbol) {
		flushComments();
		auto guard = span();

		parseIdentifierPrefix();

		auto kind = parseBaseIdentifier(expected);
		if (kind == IdentifierKind.None) {
			return false;
		}

		kind = parseIdentifierSuffix(kind);

		if (expected <= IdentifierKind.Symbol) {
			return true;
		}

		// We expect something specific.
		while (kind == IdentifierKind.Symbol) {
			kind = parseIdentifierSuffix(expected);
		}

		return true;
	}

	void parseIdentifierPrefix() {
		while (true) {
			switch (token.type) with (TokenType) {
				// Prefixes.
				case Dot:
				case Ampersand:
				case PlusPlus:
				case MinusMinus:
				case Star:
				case Plus:
				case Minus:
				case Bang:
				case Tilde:
					nextToken();
					break;

				case Cast:
					nextToken();
					if (match(OpenParen)) {
						nextToken();
						parseType();
						clearSeparator();
					}

					runOnType!(CloseParen, nextToken)();
					space();
					split();
					break;

				default:
					return;
			}
		}
	}

	IdentifierKind parseBaseIdentifier(IdentifierKind kind) {
		switch (token.type) with (TokenType) {
			case Identifier:
				nextToken();

				import source.parserutil;
				auto lookahead = trange.getLookahead();
				auto t = getStorageClassTokenType(lookahead);

				if (t != FatArrow) {
					return kind;
				}

				// Lambda expression
				parseStorageClasses(true);
				space();
				nextToken();
				space();
				split();
				parseExpression();
				return IdentifierKind.Expression;

			// Litterals
			case This:
			case Super:
			case True:
			case False:
			case Null:
			case IntegerLiteral:
			case FloatLiteral:
			case StringLiteral:
			case CharacterLiteral:
			case __File__:
			case __Line__:
			case Dollar:
				nextToken();
				return IdentifierKind.Expression;

			case __Traits:
				nextToken();
				parseArgumentList();
				return IdentifierKind.Symbol;

			case Assert, Import:
				nextToken();
				parseArgumentList();
				return IdentifierKind.Expression;

			case Throw:
				parseReturn();
				return IdentifierKind.Expression;

			case New:
				nextToken();
				space();

				if (!match(Class)) {
					parseType();
					parseArgumentList();
					return IdentifierKind.Expression;
				}

				// Ok new class.
				nextToken();
				parseArgumentList();
				space();
				parseIdentifier();
				space();
				parseInlineBlock(Mode.Declaration);

				return IdentifierKind.Expression;

			case Is:
				parseIsExpression();
				return IdentifierKind.Expression;

			case OpenParen: {
				import source.parserutil;
				auto lookahead = trange.getLookahead();
				lookahead.popMatchingDelimiter!OpenParen();

				auto t = getStorageClassTokenType(lookahead);
				if (t != OpenBrace && t != FatArrow && t != At && t != Nothrow
					    && t != Pure && t != Ref && t != Synchronized) {
					// Not a lambda.
					goto ParenIdentifier;
				}

				// We have a lambda.
				goto LambdaWithParameters;
			}

			ParenIdentifier:
				auto guard = span();
				nextToken();

				// FIXME: Customize the list parsed based on kind.
				parseExpression();

				runOnType!(CloseParen, nextToken)();
				return kind;

			case OpenBrace: {
				// Try to detect if it is a struct literal or a parameterless lambda.
				import source.parserutil;
				auto lookahead = trange.getLookahead();

				lookahead.popFront();
				if (lookahead.front.type != Identifier) {
					goto Lambda;
				}

				lookahead.popFront();
				if (lookahead.front.type != Colon) {
					goto Lambda;
				}

				// We may still have a lambda starting with a labeled statement,
				// so we go on the hunt for a semicolon.
				lookahead.popFront();
				while (true) {
					switch (lookahead.front.type) {
						case CloseBrace:
							goto StructLiteral;

						case Semicolon:
							goto Lambda;

						case End:
							// This is malformed, assume literal.
							goto StructLiteral;

						case OpenParen:
							lookahead.popMatchingDelimiter!OpenParen();
							break;

						case OpenBrace:
							lookahead.popMatchingDelimiter!OpenBrace();
							break;

						case OpenBracket:
							lookahead.popMatchingDelimiter!OpenBracket();
							break;

						default:
							lookahead.popFront();
					}
				}
			}

			StructLiteral:
				parseStructLiteral();
				return IdentifierKind.Expression;

			case Function, Delegate:
				nextToken();
				if (!match(OpenParen) && !match(OpenBrace)) {
					// We have an explicit type.
					expectParameters = true;
					scope(success) expectParameters = false;

					space();
					parseType();
				}

				goto LambdaWithParameters;

			LambdaWithParameters:
				parseParameterList();
				space();
				parseStorageClasses(true);
				goto Lambda;

			Lambda:
				if (parseInlineBlock(Mode.Statement)) {
					return IdentifierKind.Expression;
				}

				if (match(FatArrow)) {
					nextToken();
					space();
					split();
					parseExpression();
				}

				return IdentifierKind.Expression;

			case OpenBracket:
				parseArrayLiteral();
				return IdentifierKind.Expression;

			case Typeid:
				nextToken();
				parseArgumentList();
				return IdentifierKind.Expression;

			case Mixin:
				parseMixin();

				// Assume it is an expression. Technically, it could be a declaration,
				// but it does change anything from a formatting perspective.
				return IdentifierKind.Expression;

			// Types
			case Typeof:
				nextToken();
				if (!match(OpenParen)) {
					return IdentifierKind.Type;
				}

				auto lookahead = trange.getLookahead();
				lookahead.popFront();

				if (lookahead.front.type == Return) {
					nextToken();
					nextToken();
					nextToken();
				} else {
					parseArgumentList();
				}

				return IdentifierKind.Type;

			case Bool:
			case Byte, Ubyte:
			case Short, Ushort:
			case Int, Uint:
			case Long, Ulong:
			case Cent, Ucent:
			case Char, Wchar, Dchar:
			case Float, Double, Real:
			case Void:
				nextToken();
				return IdentifierKind.Type;

			// Type qualifiers
			case Const, Immutable, Inout, Shared:
				nextToken();
				if (!match(OpenParen)) {
					space();
					return parseBaseIdentifier(kind);
				}

				nextToken();
				parseType();
				runOnType!(CloseParen, nextToken)();
				return IdentifierKind.Type;

			default:
				return IdentifierKind.None;
		}
	}

	IdentifierKind parseIdentifierSuffix(IdentifierKind kind) {
		const tryDeclaration = canBeDeclaration;
		const skipParentheses = expectParameters;
		canBeDeclaration = false;
		expectParameters = false;

		kind =
			parseNonDotIdentifierSuffix(kind, tryDeclaration, skipParentheses);
		if (!match(TokenType.Dot)) {
			return kind;
		}

		auto guard = spliceSpan!ListSpan();
		while (match(TokenType.Dot)) {
			split();
			guard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			nextToken();

			if (!match(TokenType.Identifier)) {
				return IdentifierKind.None;
			}

			kind = IdentifierKind.Symbol;
			nextToken();

			kind = parseNonDotIdentifierSuffix(kind, tryDeclaration,
			                                   skipParentheses);
		}

		return kind;
	}

	IdentifierKind parseNonDotIdentifierSuffix(
		IdentifierKind kind,
		bool tryDeclaration,
		bool skipParentheses,
	) {
		while (true) {
			switch (token.type) with (TokenType) {
				case Star:
					auto lookahead = trange.getLookahead();
					lookahead.popFront();

					IdentifierStarLookahead: while (true) {
						switch (lookahead.front.type) {
							case Identifier:
								// Lean toward Indentifier* Identifier being a delcaration.
								if (tryDeclaration
									    || kind == IdentifierKind.Type) {
									goto IdentifierStarType;
								}

								goto IdentifierStarExpression;

							case Comma, CloseParen, CloseBracket, Semicolon:
								// This indicates some kind of termination, so assume a type.
								goto IdentifierStarType;

							case Function, Delegate:
								goto IdentifierStarType;

							IdentifierStarType:
								kind = IdentifierKind.Type;
								nextToken();
								break IdentifierStarLookahead;

							case This:
							case Super:
							case True:
							case False:
							case Null:
							case IntegerLiteral:
							case FloatLiteral:
							case StringLiteral:
							case CharacterLiteral:
							case __File__:
							case __Line__:
							case Dollar:
								goto IdentifierStarExpression;

							IdentifierStarExpression:
								return IdentifierKind.Expression;

							case Star:
								lookahead.popFront();
								continue;

							case OpenBracket:
								import source.parserutil;
								lookahead.popMatchingDelimiter!OpenBracket();
								continue;

							default:
								if (kind == IdentifierKind.Type) {
									goto IdentifierStarType;
								}

								return kind;
						}
					}

					break;

				case Function, Delegate:
					kind = IdentifierKind.Type;
					space();
					nextToken();
					parseParameterList();
					space();
					if (!parseStorageClasses(true)) {
						// Not sure how this will fare in the presence of comments,
						// but this will have to do for now.
						clearSeparator();
					}

					break;

				case Bang:
					if (isBangIsOrIn()) {
						// This is a binary expression.
						return IdentifierKind.Expression;
					}

					// Template instance.
					kind = IdentifierKind.Symbol;
					nextToken();
					if (!parseAliasList()) {
						parseBaseIdentifier(IdentifierKind.Symbol);
					}

					break;

				case PlusPlus, MinusMinus:
					kind = IdentifierKind.Expression;
					nextToken();
					break;

				case OpenParen:
					if (skipParentheses) {
						return kind;
					}

					// FIXME: customize based on kind.
					kind = IdentifierKind.Expression;
					parseArgumentList();
					break;

				case OpenBracket:
					// FIXME: customize based on kind.
					// Technically, this is not an array literal,
					// but this should do for now.
					parseArrayLiteral();
					break;

				default:
					return kind;
			}
		}

		assert(0, "DMD is not smart enough to figure out this is unreachable.");
	}

	bool parseMixin() {
		if (!match(TokenType.Mixin)) {
			return false;
		}

		nextToken();

		switch (token.type) with (TokenType) {
			case Template:
				space();
				parseTemplate();
				break;

			case OpenParen:
				parseArgumentList();
				break;

			default:
				space();
				parseIdentifier();

				if (match(Identifier)) {
					space();
					nextToken();
				}

				break;
		}

		return true;
	}

	/**
	 * Statements
	 */
	bool parseInlineBlock(Mode m) {
		auto oldNeedDoubleIndent = needDoubleIndent;
		scope(exit) {
			needDoubleIndent = oldNeedDoubleIndent;
		}

		needDoubleIndent = false;
		if (parseBlock(m)) {
			clearSeparator();
			return true;
		}

		return false;
	}

	bool parseEmptyBlock(uint openBraceLine) {
		if (!match(TokenType.CloseBrace) && !match(TokenType.End)) {
			return false;
		}

		if (hasComments() && openBraceLine != getLineNumber()) {
			return false;
		}

		{
			// Flush comments so that they have the proper indentation.
			auto guard = indent();
			flushComments();
		}

		nextToken();
		newline();
		return true;
	}

	bool parseBlock(alias fun = parseBlockContent, T...)(T args) {
		if (!match(TokenType.OpenBrace)) {
			return false;
		}

		auto openBraceLine = getLineNumber();
		nextToken();
		if (parseEmptyBlock(openBraceLine)) {
			return true;
		}

		{
			// We have an actual block.
			clearSeparator();
			newline(1);

			auto blockGuard = block();
			fun(args);
		}

		if (match(TokenType.CloseBrace)) {
			nextToken();
			newline(2);
		}

		return true;
	}

	void parseBlockContent(Mode m) {
		auto indentGuard = indent(1 + needDoubleIndent);
		auto modeGuard = changeMode(m);

		auto oldNeedDoubleIndent = needDoubleIndent;
		auto oldDoubleIndentBlock = doubleIndentBlock;
		scope(exit) {
			needDoubleIndent = oldNeedDoubleIndent;
			doubleIndentBlock = oldDoubleIndentBlock;
		}

		doubleIndentBlock = needDoubleIndent;
		needDoubleIndent = false;

		split();

		while (!match(TokenType.CloseBrace) && !match(TokenType.End)) {
			parseStructuralElement();
		}

		// Flush comments so that they have the proper indentation.
		flushComments();
	}

	static isBasicBlockEntry(ref TokenRange r) {
		auto t = r.front.type;
		if (t == TokenType.Case || t == TokenType.Default) {
			return true;
		}

		if (t != TokenType.Identifier) {
			return false;
		}

		// Check for labeled statements.
		r.popFront();
		return r.front.type == TokenType.Colon;
	}

	static isBasicBlockTerminator(TokenType t) {
		return t == TokenType.CloseBrace || t == TokenType.Return
			|| t == TokenType.Break || t == TokenType.Continue
			|| t == TokenType.Goto || t == TokenType.Throw;
	}

	static isBasicBlockBoundary(ref TokenRange r) {
		return isBasicBlockTerminator(r.front.type) || isBasicBlockEntry(r);
	}

	void parseColonBlock() {
		runOnType!(TokenType.Colon, nextToken)();

		if (match(TokenType.CloseBrace)) {
			// Empty colon block.
			return;
		}

		if (!match(TokenType.OpenBrace)) {
			newline();
			parseStructuralElement();
			return;
		}

		import source.parserutil;
		auto lookahead = trange.getLookahead();
		lookahead.popMatchingDelimiter!(TokenType.OpenBrace)();
		if (!isBasicBlockBoundary(lookahead)) {
			newline(1);
			return;
		}

		auto guard = unindent();
		space();
		parseBlock(mode);
	}

	bool parseControlFlowBlock(bool forceNewLine = true) {
		if (parseBlock(mode)) {
			return true;
		}

		auto guard = span();

		// Carry indentation just like blocks.
		auto indentGuard = indent(needDoubleIndent);

		auto oldNeedDoubleIndent = needDoubleIndent;
		auto oldDoubleIndentBlock = doubleIndentBlock;
		scope(exit) {
			needDoubleIndent = oldNeedDoubleIndent;
			doubleIndentBlock = oldDoubleIndentBlock;
		}

		doubleIndentBlock = needDoubleIndent;
		needDoubleIndent = false;

		if (forceNewLine) {
			newline(1);
		} else {
			space();
		}

		split(false, false, true);
		parseStructuralElement();
		return false;
	}

	void emitPostControlFlowWhitespace(bool isBlock) {
		flushComments();
		clearSeparator();
		if (isBlock) {
			space();
		} else {
			newline(1);
		}
	}

	void parseElsableBlock() {
		if (match(TokenType.Colon)) {
			parseColonBlock();
			return;
		}

		space();

		bool isBlock = parseControlFlowBlock();
		if (!match(TokenType.Else)) {
			return;
		}

		emitPostControlFlowWhitespace(isBlock);
		parseElse();
	}

	void parseCondition(bool glued = false) {
		if (!match(TokenType.OpenParen)) {
			return;
		}

		nextToken();

		auto guard = span!AlignedSpan();
		split(glued);

		guard.registerFix(function(AlignedSpan s, size_t i) {
			s.alignOn(i);
		});

		auto modeGuard = changeMode(Mode.Parameter);

		parseStructuralElement();
		runOnType!(TokenType.CloseParen, nextToken)();
	}

	void parseIf() in(match(TokenType.If)) {
		nextToken();
		space();

		parseCondition();
		parseElsableBlock();
	}

	void parseVersion() in(match(TokenType.Version) || match(TokenType.Debug)) {
		nextToken();

		switch (token.type) with (TokenType) {
			case OpenParen:
				nextToken();

				if (match(Identifier) || match(IntegerLiteral)
					    || match(Unittest) || match(Assert)) {
					nextToken();
				}

				runOnType!(CloseParen, nextToken)();
				goto default;

			case Equal:
				auto guard = span();
				space();
				nextToken();
				space();
				split();

				if (match(Identifier) || match(IntegerLiteral)) {
					nextToken();
				}

				runOnType!(Semicolon, nextToken)();
				break;

			default:
				parseElsableBlock();
				break;
		}
	}

	void parseElse() in(match(TokenType.Else)) {
		space();
		nextToken();
		space();

		switch (token.type) with (TokenType) {
			case If:
				parseIf();
				break;

			case Version, Debug:
				parseVersion();
				break;

			case While:
				parseWhile();
				break;

			case Do:
				parseDoWhile();
				break;

			case For:
				parseFor();
				break;

			case Foreach, ForeachReverse:
				parseForeach();
				break;

			case Static:
				auto lookahead = trange.getLookahead();
				lookahead.popFront();

				auto t = lookahead.front.type;
				if (t == If || t == Foreach || t == ForeachReverse) {
					parseStatic();
					break;
				}

				goto default;

			default:
				parseControlFlowBlock();
				break;
		}
	}

	void parseWhile() in(match(TokenType.While)) {
		nextToken();
		space();

		parseCondition();

		space();
		parseControlFlowBlock();
	}

	void parseDoWhile() in(match(TokenType.Do)) {
		nextToken();
		space();
		bool isBlock = parseControlFlowBlock();

		if (!match(TokenType.While)) {
			return;
		}

		emitPostControlFlowWhitespace(isBlock);
		nextToken();

		space();
		parseCondition();

		runOnType!(TokenType.Semicolon, nextToken)();
		newline(2);
	}

	void parseFor() in(match(TokenType.For)) {
		nextToken();
		space();

		if (match(TokenType.OpenParen)) {
			nextToken();
			parseForArguments();
			runOnType!(TokenType.CloseParen, nextToken)();
		}

		space();
		parseControlFlowBlock();
	}

	void parseForArguments() {
		auto guard = span!ListSpan();

		if (match(TokenType.Semicolon)) {
			nextToken();
		} else {
			split();
			guard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			parseStructuralElement();
			clearSeparator();
		}

		if (match(TokenType.Semicolon)) {
			nextToken();
		} else {
			space();
			split();
			guard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			parseCommaExpression();
			runOnType!(TokenType.Semicolon, nextToken)();
		}

		if (match(TokenType.CloseParen)) {
			nextToken();
		} else {
			space();
			split();
			guard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			parseCommaExpression();
		}
	}

	void parseForeach()
			in(match(TokenType.Foreach) || match(TokenType.ForeachReverse)) {
		nextToken();
		space();

		if (match(TokenType.OpenParen)) {
			nextToken();
			auto modeGuard = changeMode(Mode.Parameter);
			auto listGuard = span!ListSpan();

			split();
			listGuard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			parseList!parseStructuralElement(TokenType.Semicolon);

			split();
			listGuard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			space();
			parseList!parseArrayElement(TokenType.CloseParen);
		}

		space();
		parseControlFlowBlock();
	}

	void parseReturn() in(match(TokenType.Return) || match(TokenType.Throw)) {
		nextToken();
		if (token.type == TokenType.Semicolon) {
			nextToken();
			return;
		}

		auto guard = span!PrefixSpan();

		space();
		split();

		parseExpression();
	}

	void parseWith() in(match(TokenType.With)) {
		nextToken();
		space();

		parseCondition();
		space();

		parseStructuralElement();
	}

	void parseSwitch() in(match(TokenType.Switch)) {
		nextToken();
		space();

		parseCondition();
		space();
		split();

		// Request the next nested block to be double indented.
		auto oldNeedDoubleIndent = needDoubleIndent;
		scope(exit) {
			needDoubleIndent = oldNeedDoubleIndent;
		}

		needDoubleIndent = true;
		parseStructuralElement();
	}

	auto withCaseLevelIndent(alias fun)() {
		// There is nothing special to do in this case, just move on.
		if (!isCaseLevelStatement()) {
			return fun();
		}

		// Request the next nested block to be double indented.
		auto oldNeedDoubleIndent = needDoubleIndent;
		scope(exit) {
			needDoubleIndent = oldNeedDoubleIndent;
		}

		needDoubleIndent = true;

		auto guard = unindent();
		split();

		return fun();
	}

	bool isCaseLevelStatement() {
		if (!doubleIndentBlock) {
			// No case level statement if we are not in
			// switch style block.
			return false;
		}

		static void skip(ref TokenRange r) {
			while (true) {
				switch (r.front.type) with (TokenType) {
					case CloseBrace, End:
						return;

					case Semicolon:
						r.popFront();
						return;

					case OpenBrace:
						import source.parserutil;
						r.popMatchingDelimiter!OpenBrace();
						return;

					case OpenParen:
						// Make sure we don't stop on `for (;;)`
						// so skip over parentheses.
						import source.parserutil;
						r.popMatchingDelimiter!OpenParen();
						continue;

					default:
						r.popFront();
						continue;
				}
			}
		}

		static bool isCaseBlock()(ref TokenRange r) {
			if (r.front.type != TokenType.OpenBrace) {
				return containsCase(r);
			}

			r.popFront();
			while (r.front.type != TokenType.End) {
				if (containsCase(r)) {
					return true;
				}

				if (r.front.type == TokenType.CloseBrace) {
					r.popFront();
					break;
				}
			}

			return false;
		}

		static bool containsCase(ref TokenRange r, bool doSkip = true) {
			// Pop labels.
			while (r.front.type == TokenType.Identifier) {
				r.popFront();
				if (r.front.type != TokenType.Colon) {
					goto Skip;
				}

				r.popFront();
			}

			switch (r.front.type) with (TokenType) {
				case Case, Default:
					return true;

				case Static:
					r.popFront();

					auto t = r.front.type;
					if (t == If || t == Foreach || t == ForeachReverse) {
						goto CheckBlock;
					}

					break;

				case Foreach, ForeachReverse:
					goto CheckBlock;

				CheckBlock:
					// As far as we are concenred here, foreach and
					// static if have the same syntax.
					r.popFront();
					if (r.front.type == OpenParen) {
						import source.parserutil;
						r.popMatchingDelimiter!OpenParen();
					}

					return isCaseBlock(r);

				default:
					break;
			}

		Skip:
			if (doSkip) {
				skip(r);
			}

			return false;
		}

		auto lookahead = trange.getLookahead();
		return containsCase(lookahead, false);
	}

	void parseTry() in(match(TokenType.Try)) {
		nextToken();
		space();
		bool isBlock = parseControlFlowBlock();

		while (true) {
			while (match(TokenType.Catch)) {
				emitPostControlFlowWhitespace(isBlock);
				isBlock = parseCatch();
			}

			if (!match(TokenType.Finally)) {
				break;
			}

			emitPostControlFlowWhitespace(isBlock);
			isBlock = parseFinally();
		}
	}

	bool parseCatch() in(match(TokenType.Catch)) {
		nextToken();
		space();
		parseParameterList();
		space();
		return parseControlFlowBlock();
	}

	bool parseFinally() in(match(TokenType.Finally)) {
		nextToken();
		space();
		return parseControlFlowBlock();
	}

	void parseScope() in(match(TokenType.Scope)) {
		auto lookahead = trange.getLookahead();
		lookahead.popFront();

		if (lookahead.front.type != TokenType.OpenParen) {
			parseStorageClassDeclaration();
			return;
		}

		nextToken();
		parseArgumentList();

		space();
		parseControlFlowBlock(false);
	}

	/**
	 * Types
	 */
	bool parseType() {
		return parseIdentifier(IdentifierKind.Type);
	}

	/**
	 * Expressions
	 */
	void parseExpression() {
		canBeDeclaration = false;
		parseBaseExpression();
		parseAssignExpressionSuffix();
	}

	bool parseBaseExpression() {
		return parseIdentifier(IdentifierKind.Expression);
	}

	void parseCommaExpression() {
		parseBaseExpression();
		parseCommaExpressionSuffix();
	}

	void parseCommaExpressionSuffix() {
		parseAssignExpressionSuffix();

		if (!match(TokenType.Comma)) {
			return;
		}

		auto guard = spliceSpan();
		do {
			nextToken();
			split();
			space();

			parseExpression();
		} while (match(TokenType.Comma));
	}

	void parseAssignExpressionSuffix() {
		parseConditionalExpressionSuffix();

		static bool isAssignExpression(TokenType t) {
			return t == TokenType.Equal || t == TokenType.PlusEqual
				|| t == TokenType.MinusEqual || t == TokenType.StarEqual
				|| t == TokenType.SlashEqual || t == TokenType.PercentEqual
				|| t == TokenType.AmpersandEqual || t == TokenType.PipeEqual
				|| t == TokenType.CaretEqual || t == TokenType.TildeEqual
				|| t == TokenType.LessLessEqual || t == TokenType.MoreMoreEqual
				|| t == TokenType.MoreMoreMoreEqual
				|| t == TokenType.CaretCaretEqual;
		}

		if (!isAssignExpression(token.type)) {
			return;
		}

		auto guard = spliceSpan();
		do {
			space();
			nextToken();
			split();
			space();

			parseBaseExpression();
			parseConditionalExpressionSuffix();
		} while (isAssignExpression(token.type));
	}

	void parseConditionalExpressionSuffix() {
		parseBinaryExpressionSuffix();

		if (!match(TokenType.QuestionMark)) {
			return;
		}

		auto guard = spliceSpan!ConditionalSpan();

		space();
		split();

		guard.registerFix(function(ConditionalSpan s, size_t i) {
			s.setQuestionMarkIndex(i);
		});

		nextToken();
		space();

		parseExpression();

		space();
		split();

		runOnType!(TokenType.Comma, nextToken)();
		guard.registerFix(function(ConditionalSpan s, size_t i) {
			s.setColonIndex(i);
		});

		nextToken();
		space();

		parseBaseExpression();
		parseConditionalExpressionSuffix();
	}

	bool isBangIsOrIn() in(match(TokenType.Bang)) {
		auto lookahead = trange.getLookahead();
		lookahead.popFront();
		auto t = lookahead.front.type;
		return t == TokenType.Is || t == TokenType.In;
	}

	uint getPrecedence() {
		switch (token.type) with (TokenType) {
			case PipePipe:
				return 1;

			case AmpersandAmpersand:
				return 2;

			case Pipe:
				return 3;

			case Caret:
				return 4;

			case Ampersand:
				return 5;

			case Is:
			case In:
				return 6;

			case Bang:
				return isBangIsOrIn() ? 6 : 0;

			case EqualEqual:
			case BangEqual:
				return 6;

			case GreaterThan:
			case GreaterEqual:
			case SmallerThan:
			case SmallerEqual:
				return 6;

			case LessLess:
			case MoreMore:
			case MoreMoreMore:
				return 7;

			case BangLessMoreEqual:
			case BangLessMore:
			case LessMore:
			case LessMoreEqual:
			case BangMore:
			case BangMoreEqual:
			case BangLess:
			case BangLessEqual:
				return 7;

			case Plus:
			case Minus:
				return 8;

			case Slash:
			case Star:
			case Percent:
				return 9;

			case Tilde:
				return 10;

			default:
				return 0;
		}
	}

	void parseBinaryExpressionSuffix(uint minPrecedence = 0) {
		auto currentPrecedence = getPrecedence();

		while (currentPrecedence > minPrecedence) {
			auto previousPrecedence = currentPrecedence;
			auto guard = spliceSpan();

			while (previousPrecedence == currentPrecedence) {
				scope(success) {
					currentPrecedence = getPrecedence();
					if (currentPrecedence > previousPrecedence) {
						parseBinaryExpressionSuffix(previousPrecedence);
						currentPrecedence = getPrecedence();
					}

					assert(currentPrecedence <= previousPrecedence);
				}

				space();
				split();
				if (match(TokenType.Bang)) {
					nextToken();
				}

				nextToken();
				space();

				parseBaseExpression();
			}
		}
	}

	bool parseArgumentList() {
		if (!match(TokenType.OpenParen)) {
			return false;
		}

		nextToken();
		parseList!parseExpression(TokenType.CloseParen);
		return true;
	}

	void parseArrayLiteral() {
		if (!match(TokenType.OpenBracket)) {
			return;
		}

		nextToken();
		parseList!parseArrayElement(TokenType.CloseBracket);
	}

	void parseArrayElement() {
		parseExpression();

		switch (token.type) with (TokenType) {
			case Colon: {
				auto guard = spliceSpan();
				nextToken();
				space();
				split();
				parseExpression();
				break;
			}

			case DotDot: {
				auto guard = spliceSpan();
				space();
				split();
				nextToken();
				space();
				parseExpression();
				break;
			}

			default:
				break;
		}
	}

	void parseIsExpression() in(match(TokenType.Is)) {
		auto modeGuard = changeMode(Mode.Parameter);
		nextToken();
		runOnType!(TokenType.OpenParen, nextToken)();
		parseList!parseIsExpressionElement(TokenType.CloseParen, false, false);
	}

	void parseIsExpressionElement() {
		parseType();
		if (match(TokenType.Identifier)) {
			space();
			nextToken();
		}

		if (!match(TokenType.EqualEqual) && !match(TokenType.Colon)) {
			return;
		}

		auto sGuard = span!ListSpan();
		space();
		split();
		sGuard.registerFix(function(ListSpan s, size_t i) {
			s.registerHeaderSplit(i);
		});

		nextToken();
		space();
		split(true);
		sGuard.registerFix(function(ListSpan s, size_t i) {
			s.registerElement(i);
		});

		static bool isTypeSpecialization(TokenType t) {
			return t == TokenType.Struct || t == TokenType.Union
				|| t == TokenType.Class || t == TokenType.Interface
				|| t == TokenType.Enum || t == TokenType.__Vector
				|| t == TokenType.Function || t == TokenType.Delegate
				|| t == TokenType.Super || t == TokenType.Return
				|| t == TokenType.__Parameters || t == TokenType.Module
				|| t == TokenType.Package;
		}

		if (isTypeSpecialization(token.type)) {
			nextToken();
		} else {
			parseType();
		}

		clearSeparator();

		while (match(TokenType.Comma)) {
			nextToken();
			space();
			split();

			sGuard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			parseStructuralElement();
		}
	}

	void parseStructLiteral() {
		parseBlock!parseStructLiteralContent();
		clearSeparator();
	}

	void parseStructLiteralContent() {
		auto indentGuard = indent();

		split();

		while (!match(TokenType.CloseBrace) && !match(TokenType.End)) {
			parseMapEntry();
			runOnType!(TokenType.Comma, nextToken)();
			newline(1);
		}

		// Flush comments so that they have the proper indentation.
		flushComments();
	}

	void parseMapEntry() {
		auto guard = span();
		runOnType!(TokenType.Identifier, nextToken)();
		runOnType!(TokenType.Colon, nextToken)();

		split();
		space();
		parseExpression();
	}

	/**
	 * Declarations
	 */
	void parseParameterPacks() {
		auto guard = changeMode(Mode.Parameter);

		while (match(TokenType.OpenParen)) {
			nextToken();
			parseList!parseStructuralElement(TokenType.CloseParen);
		}
	}

	void parseTypedDeclaration() in(match(TokenType.Identifier)) {
		bool isParameter = mode == Mode.Parameter;
		while (true) {
			auto guard = span!PrefixSpan();
			split();
			space();
			runOnType!(TokenType.Identifier, nextToken)();

			parseParameterPacks();

			// Variable, template parameters, whatever.
			if (match(TokenType.Equal) || match(TokenType.Colon)) {
				auto valueGuard = spliceSpan();

				space();
				nextToken();
				space();
				split();

				parseExpression();
			}

			if (isParameter) {
				if (match(TokenType.DotDotDot)) {
					nextToken();
				}

				break;
			}

			if (!match(TokenType.Comma)) {
				break;
			}

			nextToken();
		}

		parseFunctionBody();
	}

	void parseConstructor() in(match(TokenType.This)) {
		nextToken();
		parseParameterPacks();
		parseFunctionBody();
	}

	void parseDestructor() in(match(TokenType.Tilde)) {
		nextToken();
		parseConstructor();
	}

	void parseFunctionBody() {
		if (!parseFunctionPostfix()) {
			return;
		}

		// ShortenedFunctionBody
		if (match(TokenType.FatArrow)) {
			parseShortenedFunctionBody();
			return;
		}

		space();
		parseBlock(Mode.Statement);
	}

	bool parseFunctionPostfix() {
		auto guard = span!IndentSpan(2);

		while (true) {
			clearSeparator();
			space();

			switch (token.type) with (TokenType) {
				case OpenBrace, FatArrow:
					// Function declaration.
					return true;

				case Do:
					split();
					nextToken();
					return true;

				case In:
					auto lookahead = trange.getLookahead();
					lookahead.popFront();

					if (lookahead.front.type == OpenBrace) {
						nextToken();
						goto ContractBlock;
					}

					split();
					nextToken();
					parseArgumentList();
					break;

				case Out:
					auto lookahead = trange.getLookahead();
					lookahead.popFront();

					if (lookahead.front.type == OpenBrace) {
						nextToken();
						goto ContractBlock;
					}

					split();
					nextToken();

					runOnType!(OpenParen, nextToken)();
					runOnType!(Identifier, nextToken)();

					if (match(CloseParen)) {
						nextToken();
						goto ContractBlock;
					}

					auto outGuard = span();
					runOnType!(Semicolon, nextToken)();

					space();
					split();

					parseList!parseExpression(CloseParen);
					break;

				ContractBlock:
					space();
					parseBlock(Mode.Statement);
					break;

				case If:
					parseConstraint();
					break;

				default:
					if (!parseStorageClasses(true)) {
						clearSeparator();
						return false;
					}

					break;
			}
		}

		assert(0);
	}

	void parseShortenedFunctionBody() in(match(TokenType.FatArrow)) {
		auto spanGuard = spliceSpan();
		split();
		nextToken();
		space();
		parseExpression();
		if (match(TokenType.Semicolon)) {
			nextToken();
		}

		newline(2);
	}

	void parseConstraint() {
		if (!match(TokenType.If)) {
			return;
		}

		split();
		nextToken();
		space();
		parseCondition(true);
	}

	void parseTemplate() in(match(TokenType.Template)) {
		nextToken();
		space();
		runOnType!(TokenType.Identifier, nextToken)();
		parseParameterList();
		space();

		if (match(TokenType.If)) {
			auto guard = span!IndentSpan(2);
			parseConstraint();
			space();
		}

		parseBlock(Mode.Declaration);
	}

	void parseTemplateParameter() in(token.type == TokenType.Identifier) {
		nextToken();

		if (match(TokenType.DotDotDot)) {
			nextToken();
		}

		while (match(TokenType.Colon) || match(TokenType.Equal)) {
			space();
			nextToken();
			space();
			parseType();
		}
	}

	bool parseParameterList() {
		if (!match(TokenType.OpenParen)) {
			return false;
		}

		auto guard = changeMode(Mode.Parameter);
		nextToken();

		parseList!parseStructuralElement(TokenType.CloseParen);
		return true;
	}

	void parseImport() in(match(TokenType.Import)) {
		nextToken();

		auto guard = span!PrefixSpan();

		while (true) {
			space();
			split();
			parseIdentifier();

			if (!match(TokenType.Comma)) {
				break;
			}

			nextToken();
		}

		parseColonList!parseImportBind();
	}

	void parseImportBind() {
		parseIdentifier();

		if (!match(TokenType.Equal)) {
			return;
		}

		auto guard = spliceSpan();
		space();
		nextToken();
		space();
		split();

		parseIdentifier();
	}

	bool parseAttribute() {
		if (!match(TokenType.At)) {
			return false;
		}

		nextToken();
		if (parseAliasList()) {
			return true;
		}

		if (!match(TokenType.Identifier)) {
			parseIdentifier();
			return true;
		}

		nextToken();
		parseIdentifierSuffix(IdentifierKind.Symbol);
		return true;
	}

	bool parseAttributes() {
		if (!parseAttribute()) {
			return false;
		}

		while (match(TokenType.At)) {
			space();
			split();
			parseAttribute();
		}

		space();
		return true;
	}

	static popDeclarator(ref TokenRange lookahead) {
		lookahead.popFront();

		if (lookahead.front.type == TokenType.Identifier) {
			lookahead.popFront();
		}

		if (lookahead.front.type == TokenType.OpenParen) {
			import source.parserutil;
			lookahead.popMatchingDelimiter!(TokenType.OpenParen)();
		}

		return lookahead.front.type;
	}

	TokenType getStorageClassTokenType() {
		auto lookahead = trange.getLookahead();
		return getStorageClassTokenType(lookahead);
	}

	static getStorageClassTokenType(ref TokenRange lookahead) {
		while (true) {
			auto t = lookahead.front.type;
			switch (t) with (TokenType) {
				case Const, Immutable, Inout, Shared, Scope:
					lookahead.popFront();
					if (lookahead.front.type == OpenParen) {
						// This is a type.
						return t;
					}

					break;

				case Abstract, Auto, Export, Final, In, Lazy, Nothrow, Out,
				     Override, Private, Protected, Pure, Ref, Return, __Gshared:
					lookahead.popFront();
					break;

				case Align, Deprecated, Extern, Package, Pragma, Synchronized:
					lookahead.popFront();
					if (lookahead.front.type == OpenParen) {
						import source.parserutil;
						lookahead.popMatchingDelimiter!OpenParen();
					}

					break;

				case At:
					// FIXME: A declarator is not apropriate here.
					popDeclarator(lookahead);
					break;

				case Public:
					auto l2 = lookahead.getLookahead();
					l2.popFront();

					if (l2.front.type == Import) {
						// This is a public import.
						return t;
					}

					lookahead.popFront();
					break;

				case Static:
					auto l2 = lookahead.getLookahead();
					l2.popFront();

					auto t2 = l2.front.type;
					if (t2 == Assert || t2 == Import || t2 == If
						    || t2 == Foreach || t2 == ForeachReverse) {
						// This is a static something.
						return t;
					}

					lookahead.popFront();
					break;

				case Enum:
					auto l2 = lookahead.getLookahead();
					popDeclarator(l2);

					auto t2 = l2.front.type;
					if (t2 == Colon || t2 == OpenBrace) {
						// This is an enum declaration.
						return t;
					}

					lookahead.popFront();
					break;

				case Alias:
					auto l2 = lookahead.getLookahead();
					popDeclarator(l2);

					auto t2 = l2.front.type;
					if (t2 == This || t2 == Identifier) {
						// This is an alias declaration.
						return t;
					}

					lookahead.popFront();
					break;

				default:
					return t;
			}
		}
	}

	bool parseStorageClasses(bool isPostfix = false) {
		bool foundStorageClass = false;
		while (true) {
			scope(success) {
				// This will be true after the first loop iterration.
				foundStorageClass = true;
			}

			switch (token.type) with (TokenType) {
				case Const, Immutable, Inout, Shared, Scope:
					auto lookahead = trange.getLookahead();
					lookahead.popFront();
					if (lookahead.front.type == OpenParen) {
						// This is a type.
						goto default;
					}

					nextToken();
					break;

				case In, Out:
					// Make sure we deambiguate with contracts.
					if (isPostfix) {
						goto default;
					}

					nextToken();
					break;

				case Abstract, Auto, Export, Final, Lazy, Nothrow, Override,
				     Private, Protected, Pure, Ref, Return, __Gshared:
					nextToken();
					break;

				case Align, Deprecated, Extern, Package, Synchronized:
					nextToken();
					parseArgumentList();
					break;

				case Pragma:
					nextToken();
					parseArgumentList();
					if (!isPostfix && !match(Colon)) {
						newline(1);
					}

					break;

				case At:
					parseAttributes();
					if (!isPostfix && !foundStorageClass
						    && mode != Mode.Parameter && !match(Colon)) {
						newline(1);
					}

					break;

				case Public:
					auto lookahead = trange.getLookahead();
					lookahead.popFront();

					if (lookahead.front.type == Import) {
						// This is a public import.
						goto default;
					}

					nextToken();
					break;

				case Static:
					auto lookahead = trange.getLookahead();
					lookahead.popFront();

					auto t = lookahead.front.type;
					if (t == Assert || t == Import || t == If || t == Foreach
						    || t == ForeachReverse) {
						// This is a static something.
						goto default;
					}

					nextToken();
					break;

				case Enum:
					auto lookahead = trange.getLookahead();
					popDeclarator(lookahead);

					auto t = lookahead.front.type;
					if (t == Colon || t == OpenBrace) {
						// This is an enum declaration.
						goto default;
					}

					nextToken();
					break;

				case Alias:
					auto lookahead = trange.getLookahead();
					popDeclarator(lookahead);

					auto t = lookahead.front.type;
					if (t == This || t == Identifier) {
						// This is an alias declaration.
						goto default;
					}

					nextToken();
					break;

				default:
					return foundStorageClass;
			}

			if (match(TokenType.Colon) || match(TokenType.Semicolon)) {
				clearSeparator();
			} else {
				if (!isPostfix && !match(TokenType.Identifier)) {
					split();
				}

				space();
			}
		}

		return foundStorageClass;
	}

	bool parseStorageClassDeclaration() {
		auto guard = span!StorageClassSpan();

		bool isColonBlock = getStorageClassTokenType() == TokenType.Colon;
		bool foundStorageClass = false;

		{
			auto indentGuard = unindent(isColonBlock);
			foundStorageClass = parseStorageClasses();
		}

		// Before bailing, try storage class looking declarations.
		switch (token.type) with (TokenType) {
			case Public:
				return parsePublic();

			case Enum:
				return parseEnum();

			case Alias:
				return parseAlias();

			default:
				break;
		}

		if (!foundStorageClass) {
			return false;
		}

		switch (token.type) with (TokenType) {
			case Colon:
				clearSeparator();
				parseColonBlock();
				break;

			case Semicolon:
				clearSeparator();
				nextToken();
				break;

			case OpenBrace:
				parseBlock(mode);
				break;

			case Identifier:
				auto lookahead = trange.getLookahead();
				lookahead.popFront();

				auto t = lookahead.front.type;
				if (t == Equal || t == OpenParen) {
					split();
					parseTypedDeclaration();
					break;
				}

				goto default;

			default:
				split();
				parseStructuralElement();
				break;
		}

		return true;
	}

	bool parsePublic() {
		if (!match(TokenType.Public)) {
			return false;
		}

		auto lookahead = trange.getLookahead();
		lookahead.popFront();

		if (lookahead.front.type == TokenType.Import) {
			nextToken();
			space();
			parseImport();
		} else {
			parseStorageClassDeclaration();
		}

		return true;
	}

	bool parseStatic() {
		if (!match(TokenType.Static)) {
			return false;
		}

		auto lookahead = trange.getLookahead();
		lookahead.popFront();

		auto t = lookahead.front.type;
		switch (t) with (TokenType) {
			case If:
				nextToken();
				space();
				parseIf();
				break;

			case Foreach, ForeachReverse:
				nextToken();
				space();
				parseForeach();
				break;

			case Assert:
				nextToken();
				space();
				parseExpression();
				break;

			case Import:
				nextToken();
				space();
				parseImport();
				break;

			default:
				parseStorageClassDeclaration();
				break;
		}

		return true;
	}

	bool parseEnum() {
		if (!match(TokenType.Enum)) {
			return false;
		}

		nextToken();
		if (match(TokenType.Identifier)) {
			space();
			nextToken();
		}

		if (match(TokenType.Colon)) {
			space();
			nextToken();
			space();
			parseType();
		}

		if (match(TokenType.OpenBrace)) {
			space();
			nextToken();
			parseList!parseEnumEntry(TokenType.CloseBrace, true);
			newline(2);
		}

		return true;
	}

	void parseEnumEntry() {
		if (parseAttributes()) {
			newline(1);
		}

		parseExpression();
	}

	bool parseAlias() {
		if (!match(TokenType.Alias)) {
			return false;
		}

		nextToken();
		space();

		parseIdentifier();

		if (match(TokenType.Identifier) || match(TokenType.This)) {
			space();
			nextToken();
		}

		return true;
	}

	void parseAliasEntry() {
		// FIXME: This is wrong because identifier * identifier shouldn't be
		// parsed as a declaration here, but provide the right entry point for the
		// rest of the code.
		parseType();
		parseAssignExpressionSuffix();
	}

	bool parseAliasList() {
		if (!match(TokenType.OpenParen)) {
			return false;
		}

		nextToken();
		parseList!parseAliasEntry(TokenType.CloseParen);
		return true;
	}

	void parseAggregate() in(
		match(TokenType.Struct) || match(TokenType.Union)
			|| match(TokenType.Class) || match(TokenType.Interface)) {
		nextToken();
		space();

		runOnType!(TokenType.Identifier, nextToken)();

		parseParameterList();

		while (true) {
			space();

			switch (token.type) with (TokenType) {
				case Colon:
					parseColonList!parseIdentifier();
					break;

				case If: {
					auto guard = span!IndentSpan(2);
					parseConstraint();
					break;
				}

				default:
					parseBlock(Mode.Declaration);
					return;
			}
		}
	}

	/**
	 * Parsing utilities
	 */
	void parseList(alias fun)(
		TokenType closingTokenType,
		bool addNewLines = false,
		bool addNaturalbreak = true
	) {
		if (match(closingTokenType)) {
			auto guard = builder.virtualSpan();
			nextToken();
			return;
		}

		auto guard = span!ListSpan();

		while (!match(closingTokenType)) {
			if (addNewLines) {
				newline(1);
			}

			split(false, false, addNaturalbreak);
			guard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			fun();

			if (!match(TokenType.Comma)) {
				break;
			}

			nextToken();
			space();
		}

		if (match(closingTokenType)) {
			if (addNewLines) {
				newline(1);
			}

			split();
			guard.registerFix(function(ListSpan s, size_t i) {
				s.registerTrailingSplit(i);
			});

			nextToken();
		}
	}

	bool parseColonList(alias fun)() {
		if (!match(TokenType.Colon)) {
			return false;
		}

		auto guard = span!ListSpan();
		space();
		split();
		guard.registerFix(function(ListSpan s, size_t i) {
			s.registerHeaderSplit(i);
		});

		nextToken();
		space();
		split(true);
		guard.registerFix(function(ListSpan s, size_t i) {
			s.registerElement(i);
		});

		fun();

		while (match(TokenType.Comma)) {
			nextToken();
			space();
			split();

			guard.registerFix(function(ListSpan s, size_t i) {
				s.registerElement(i);
			});

			fun();
		}

		return true;
	}
}
