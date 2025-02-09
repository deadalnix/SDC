module format.span;

import format.chunk;
import format.writer;

class Span {
	Span parent = null;

	this(Span parent) {
		this.parent = parent;
	}

	ulong getState(const ref SolveState s) const {
		return 0;
	}

	uint getCost(const ref SolveState s) const {
		return 10;
	}

	// lhs < rhs => rhs.opCmp(rhs) < 0
	final int opCmp(const Span rhs) const {
		auto lhsPtr = cast(void*) this;
		auto rhsPtr = cast(void*) rhs;

		return (lhsPtr > rhsPtr) - (lhsPtr < rhsPtr);
	}

	@trusted
	final override size_t toHash() const {
		return cast(size_t) cast(void*) this;
	}

	static string print(const Span span) {
		if (span is null) {
			return "null";
		}

		return span.toString();
	}

	override string toString() const {
		import std.conv;
		return typeid(this).toString() ~ "(" ~ print(parent) ~ ")";
	}

protected:
	bool matchLevel(const Span s, size_t i) const {
		return false;
	}

	enum Split {
		No,
		Can,
		Must,
	}

	uint computeIndent(const ref SolveState s, size_t i) const {
		return s.isUsed(this) ? 1 : 0;
	}

	size_t computeAlignIndex(const ref SolveState s, size_t i) const {
		return 0;
	}

	Split computeSplit(const ref SolveState s, size_t i) const {
		return Split.Can;
	}
}

Span getTop(Span span) {
	Span top = span;

	while (span !is null) {
		top = span;
		span = span.parent;
	}

	return top;
}

bool contains(const Span span, const Span s) {
	if (span is null) {
		return false;
	}

	if (span is s) {
		return true;
	}

	return span.parent.contains(s);
}

bool isSameLevel(const Span a, const Span b, size_t i) {
	if (a is b) {
		return true;
	}

	if (a !is null && a.matchLevel(b, i)) {
		return true;
	}

	if (b !is null && b.matchLevel(a, i)) {
		return true;
	}

	return false;
}

uint getIndent(const Span span, const ref SolveState s, size_t i) {
	if (span is null) {
		return 0;
	}

	return span.computeIndent(s, i) + span.parent.getIndent(s, i);
}

uint getExtraIndent(const Span span, const Span base, const ref SolveState s,
                    size_t i) {
	if (base is null) {
		return span.getIndent(s, i);
	}

	if (span is null || span is base || span is base.parent) {
		return 0;
	}

	const current = span.computeIndent(s, i);
	if (current == 0) {
		return span.parent.getExtraIndent(base, s, i);
	}

	/**
	 * We have some extra indentation. We want to count only
	 * the indentation that has not already been accounted for
	 * in base. Doign so require to find the common ancestor
	 * between span and base.
	 */

	// Try to early bail.
	if (span.parent is null || span.parent is base
		    || span.parent is base.parent) {
		return current;
	}

	static uint getDepth(const Span s) {
		return s is null ? 0 : 1 + getDepth(s.parent);
	}

	auto baseDepth = getDepth(base);
	auto depth = getDepth(span);

	static const(Span) popTo(const Span s, uint sDepth, uint target) {
		return sDepth > target ? popTo(s.parent, sDepth - 1, target) : s;
	}

	const rebaseDepth = depth < baseDepth ? depth : baseDepth;
	const rebase = popTo(base, baseDepth, depth);
	if (span is rebase) {
		return 0;
	}

	static finalize(const Span a, const Span b, const ref SolveState s,
	                size_t i) {
		if (a is b) {
			return 0;
		}

		return a.computeIndent(s, i) + finalize(a.parent, b.parent, s, i);
	}

	static sum(const Span a, uint aDepth, const Span b, uint bDepth,
	           const ref SolveState s, size_t i) {
		if (aDepth == bDepth) {
			return finalize(a, b, s, i);
		}

		if (bDepth > aDepth) {
			return sum(a, aDepth, b.parent, bDepth - 1, s, i);
		}

		return a.computeIndent(s, i)
			+ sum(a.parent, aDepth - 1, b, bDepth, s, i);
	}

	return current + sum(span.parent, depth - 1, rebase, rebaseDepth, s, i);
}

size_t getAlignIndex(const Span span, const ref SolveState s, size_t i) {
	if (span is null) {
		return 0;
	}

	auto ci = span.computeAlignIndex(s, i);
	if (ci > 0 && ci != i) {
		return ci;
	}

	if (auto pi = span.parent.getAlignIndex(s, i)) {
		return pi;
	}

	return ci;
}

bool canSplit(const Span span, const ref SolveState s, size_t i) {
	if (span is null) {
		return true;
	}

	final switch (span.computeSplit(s, i)) with (Span.Split) {
		case No:
			return false;

		case Must:
			return true;

		case Can:
			break;
	}

	return span.parent.canSplit(s, i);
}

bool mustSplit(const Span span, const ref SolveState s, size_t i) {
	if (span is null) {
		return false;
	}

	final switch (span.computeSplit(s, i)) with (Span.Split) {
		case No:
			return false;

		case Must:
			return true;

		case Can:
			return span.parent.mustSplit(s, i);
	}
}

/**
 * Span state management utilities.
 */
private mixin template CachedState() {
	import format.rulevalues;
	RuleValues __cachedSolveRuleValue;
	ulong __cachedState;

	final override ulong getState(const ref SolveState s) const {
		if (__cachedSolveRuleValue == s.ruleValues) {
			return __cachedState;
		}

		auto state = computeState(s);

		auto t = cast() this;
		t.__cachedSolveRuleValue = s.ruleValues.clone();
		t.__cachedState = state;

		return state;
	}
}

/**
 * This span can indent multiple times.
 */
final class IndentSpan : Span {
	uint indent;

	this(Span parent, uint indent) {
		super(parent);

		this.indent = indent;
	}

	override uint computeIndent(const ref SolveState s, size_t i) const {
		return super.computeIndent(s, i) ? indent : 0;
	}
}

/**
 * This span only has a cost when directly broken.
 */
final class PrefixSpan : Span {
	this(Span parent) {
		super(parent);
	}

	override uint getCost(const ref SolveState s) const {
		return s.isUsed(this) ? 15 : 0;
	}
}

/**
 * Span that ensure breaks are aligned with the start of the span.
 */
final class AlignedSpan : Span {
	size_t first = size_t.max;

	this(Span parent) {
		super(parent);
	}

	void alignOn(size_t i) {
		first = i;
	}

	override size_t computeAlignIndex(const ref SolveState s, size_t i) const {
		return first;
	}
}

/**
 * Span ensuring lists of items are formatted as expected.
 */
final class ListSpan : Span {
	size_t[] elements;
	size_t headerSplit = size_t.max;
	size_t trailingSplit = size_t.max;

	bool compact = true;

	this(Span parent) {
		super(parent);
	}

	@property
	bool hasTrailingSplit() const {
		return trailingSplit != size_t.max;
	}

	void registerElement(size_t i)
			in(elements.length == 0 || elements[$ - 1] <= i)
			in(!hasTrailingSplit) {
		import std.algorithm;
		headerSplit = min(i, headerSplit);

		updateCompactness(i);
		elements ~= i;
	}

	void registerHeaderSplit(size_t i) in(elements.length == 0) {
		headerSplit = i;
	}

	void registerTrailingSplit(size_t i) in(elements.length > 0)
			in(elements[$ - 1] <= i)
			in(!hasTrailingSplit) {
		trailingSplit = i;

		if (elements.length > 1) {
			updateCompactness(i);
		}
	}

	private void updateCompactness(size_t i) {
		if (compact && elements.length > 0) {
			compact = i <= elements[$ - 1] + 1;
		}
	}

	override bool matchLevel(const Span s, size_t i) const {
		if (i < trailingSplit) {
			return false;
		}

		static bool walkParents(const Span p, const Span s, size_t i) {
			if (p is null) {
				return false;
			}

			if (cast(const(ListSpan)) p) {
				return p.isSameLevel(s, i);
			}

			return walkParents(p.parent, s, i);
		}

		return walkParents(parent, s, i);
	}

	bool mustExplode(const ref SolveState s) const {
		return getState(s) == -1;
	}

	bool mustSplit(const ref SolveState s, size_t start, size_t stop) const {
		return s.isSplit(start, stop) || mustExplode(s);
	}

	mixin CachedState;
	ulong computeState(const ref SolveState s) const {
		// If the last element is broken, expand the whole thing.
		if (!compact && hasTrailingSplit
			    && s.isSplit(elements[$ - 1] + 1, trailingSplit + 1)) {
			return -1;
		}

		const maxSplit = 1;

		ulong headSplit = s.isSplit(headerSplit);
		ulong count = 0;

		size_t previous = headerSplit;
		foreach (k, p; elements) {
			scope(success) {
				previous = p;
			}

			if (!s.isSplit(previous + 1, p + 1)) {
				continue;
			}

			count++;
			if (count > maxSplit) {
				return -1;
			}
		}

		// For length 1 and 2, we won't trip the explode state earlier,
		// so we push the trigger now if apropriate.
		auto splitCount = headSplit + count;
		if (!compact && elements.length <= splitCount) {
			return -1;
		}

		return headSplit + (count << 1);
	}

	override uint getCost(const ref SolveState s) const {
		// If there is just one element, make it slitghtly more exepensive to split.
		if (elements.length <= 1) {
			return 15;
		}

		return (getState(s) & 0x01) ? 13 : 11;
	}

	override uint computeIndent(const ref SolveState s, size_t i) const {
		if (i < headerSplit || i >= trailingSplit) {
			return 0;
		}

		return (s.isSplit(headerSplit) && s.isUsed(this)) ? 1 : 0;
	}

	override size_t computeAlignIndex(const ref SolveState s, size_t i) const {
		if (i <= elements[0] || i >= trailingSplit || !s.isUsed(this)) {
			return 0;
		}

		return elements[0];
	}

	override Split computeSplit(const ref SolveState s, size_t i) const {
		if (compact) {
			if (i == headerSplit && mustExplode(s)) {
				return Split.Must;
			}

			if (i != trailingSplit) {
				return Split.Can;
			}

			if (!s.isSplit(headerSplit)) {
				return Split.No;
			}

			return mustExplode(s) ? Split.Must : Split.Can;
		}

		if (i < headerSplit || i > trailingSplit) {
			return Split.Can;
		}

		if (i == headerSplit) {
			return mustExplode(s) ? Split.Must : Split.Can;
		}

		if (i == trailingSplit) {
			return mustExplode(s) ? Split.Must : Split.No;
		}

		size_t previous = elements[0];
		foreach (p; elements[1 .. $]) {
			if (previous > i) {
				// We went past the index we are interested in.
				break;
			}

			if (p < i) {
				// We have not reached our goal, move on to the next param.
				previous = p;
				continue;
			}

			if (p > i) {
				// We can only split within an element
				// if the element itself is split.
				return s.isSplit(previous) ? Split.Can : Split.No;
			}

			return mustSplit(s, previous + 1, p) ? Split.Must : Split.Can;
		}

		return Split.Can;
	}
}

/**
 * Span used to format Condition expression, of the form:
 *     condition ? ifTrue : ifFalse
 */
final class ConditionalSpan : Span {
	size_t questionMarkIndex = size_t.max;
	size_t colonIndex = size_t.max;

	ConditionalSpan parentConditional = null;

	this(Span parent) {
		super(parent);
	}

	void setQuestionMarkIndex(size_t i) {
		questionMarkIndex = i;

		// Use the opportinity to detect if this is a nested conditional.
		static ConditionalSpan findParentConditional(const Span s, size_t i) {
			auto p = s.parent;
			if (p is null) {
				return null;
			}

			if (auto c = cast(ConditionalSpan) p) {
				// Skip over if we are in the parent's condition rather than nested.
				if (c.questionMarkIndex < i) {
					return c;
				}
			}

			return findParentConditional(p, i);
		}

		parentConditional = findParentConditional(this, i);
	}

	void setColonIndex(size_t i) {
		colonIndex = i;
	}

	override Split computeSplit(const ref SolveState s, size_t i) const {
		if (i == questionMarkIndex && parentConditional !is null) {
			auto pi = parentConditional.questionMarkIndex;
			return s.isSplit(pi) ? Split.Can : Split.No;
		}

		if (i == colonIndex) {
			return s.isSplit(questionMarkIndex) ? Split.Must : Split.No;
		}

		return Split.Can;
	}
}

/**
 * Span that do not cause any indentation and is cheap to break.
 */
final class StorageClassSpan : Span {
	this(Span parent) {
		super(parent);
	}

	override uint getCost(const ref SolveState s) const {
		return 5;
	}

	override uint computeIndent(const ref SolveState s, size_t i) const {
		return 0;
	}

	override bool matchLevel(const Span s, size_t i) const {
		return parent.isSameLevel(s, i);
	}
}
