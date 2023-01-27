module d.llvm.expression;

import d.llvm.local;
import d.llvm.type;

import d.ir.expression;
import d.ir.symbol;
import d.ir.type;

import source.location;

import util.visitor;

import llvm.c.core;

struct ExpressionGen {
	private LocalPass pass;
	alias pass this;

	this(LocalPass pass) {
		this.pass = pass;
	}

	LLVMValueRef visit(Expression e) {
		if (auto ce = cast(CompileTimeExpression) e) {
			// XXX: for some resaon, pass.pass is need as
			// alias this doesn't kick in.
			import d.llvm.constant;
			return ConstantGen(pass.pass).visit(ce);
		}

		return this.dispatch!(function LLVMValueRef(Expression e) {
			import source.exception;
			throw new CompileException(
				e.location, typeid(e).toString() ~ " is not supported");
		})(e);
	}

	private LLVMValueRef addressOf(E)(E e) if (is(E : Expression))
			in(e.isLvalue, "e must be an lvalue") {
		return AddressOfGen(pass).visit(e);
	}

	private LLVMValueRef buildLoad(LLVMValueRef ptr, TypeQualifier q) {
		auto type = LLVMGetElementType(LLVMTypeOf(ptr));
		auto l = LLVMBuildLoad2(builder, type, ptr, "");
		final switch (q) with (TypeQualifier) {
			case Mutable, Inout, Const:
				break;

			case Shared, ConstShared:
				import llvm.c.target;
				LLVMSetAlignment(l, LLVMABIAlignmentOfType(targetData, type));
				LLVMSetOrdering(l, LLVMAtomicOrdering.SequentiallyConsistent);
				break;

			case Immutable:
				// TODO: !invariant.load
				break;
		}

		return l;
	}

	private LLVMValueRef loadAddressOf(E)(E e) if (is(E : Expression))
			in(e.isLvalue, "e must be an lvalue") {
		auto q = e.type.qualifier;
		return buildLoad(addressOf(e), q);
	}

	private LLVMValueRef buildStore(LLVMValueRef ptr, LLVMValueRef val,
	                                TypeQualifier q) {
		auto s = LLVMBuildStore(builder, val, ptr);
		final switch (q) with (TypeQualifier) {
			case Mutable, Inout, Const:
				break;

			case Shared, ConstShared:
				import llvm.c.target;
				LLVMSetAlignment(
					s, LLVMABIAlignmentOfType(targetData, LLVMTypeOf(val)));
				LLVMSetOrdering(s, LLVMAtomicOrdering.SequentiallyConsistent);
				break;

			case Immutable:
				// TODO: !invariant.load
				break;
		}

		return s;
	}

	private auto handleBinaryOp(alias LLVMBuildOp)(BinaryExpression e) {
		// XXX: should be useless, but parameters's order of evaluation is bugguy.
		auto lhs = visit(e.lhs);
		auto rhs = visit(e.rhs);

		return LLVMBuildOp(builder, lhs, rhs, "");
	}

	private
	auto handleLogicalBinary(bool shortCircuitOnTrue)(BinaryExpression e) {
		auto lhs = visit(e.lhs);

		auto lhsBB = LLVMGetInsertBlock(builder);
		auto fun = LLVMGetBasicBlockParent(lhsBB);

		static if (shortCircuitOnTrue) {
			auto rhsBB = LLVMAppendBasicBlockInContext(llvmCtx, fun, "or_rhs");
			auto mergeBB =
				LLVMAppendBasicBlockInContext(llvmCtx, fun, "or_merge");
			LLVMBuildCondBr(builder, lhs, mergeBB, rhsBB);
		} else {
			auto rhsBB = LLVMAppendBasicBlockInContext(llvmCtx, fun, "and_rhs");
			auto mergeBB =
				LLVMAppendBasicBlockInContext(llvmCtx, fun, "and_merge");
			LLVMBuildCondBr(builder, lhs, rhsBB, mergeBB);
		}

		// Emit rhs
		LLVMPositionBuilderAtEnd(builder, rhsBB);

		auto rhs = visit(e.rhs);

		// Conclude that block.
		LLVMBuildBr(builder, mergeBB);

		// Codegen of lhs can change the current block, so we put everything in order.
		rhsBB = LLVMGetInsertBlock(builder);
		LLVMMoveBasicBlockAfter(mergeBB, rhsBB);
		LLVMPositionBuilderAtEnd(builder, mergeBB);

		// Generate phi to get the result.
		auto eType = TypeGen(pass.pass).visit(e.type);
		auto phiNode = LLVMBuildPhi(builder, eType, "");

		LLVMValueRef[2] incomingValues = [lhs, rhs];
		LLVMBasicBlockRef[2] incomingBlocks = [lhsBB, rhsBB];

		LLVMAddIncoming(phiNode, incomingValues.ptr, incomingBlocks.ptr,
		                incomingValues.length);

		return phiNode;
	}

	LLVMValueRef visit(BinaryExpression e) {
		final switch (e.op) with (BinaryOp) {
			case Comma:
				visit(e.lhs);
				return visit(e.rhs);

			case Assign:
				auto lhs = addressOf(e.lhs);
				auto rhs = visit(e.rhs);

				buildStore(lhs, rhs, e.lhs.type.qualifier);
				return rhs;

			case Add:
				return handleBinaryOp!LLVMBuildAdd(e);

			case Sub:
				return handleBinaryOp!LLVMBuildSub(e);

			case Mul:
				return handleBinaryOp!LLVMBuildMul(e);

			case UDiv:
				return handleBinaryOp!LLVMBuildUDiv(e);

			case SDiv:
				return handleBinaryOp!LLVMBuildSDiv(e);

			case URem:
				return handleBinaryOp!LLVMBuildURem(e);

			case SRem:
				return handleBinaryOp!LLVMBuildSRem(e);

			case Pow:
				assert(0, "Not implemented");

			case Or:
				return handleBinaryOp!LLVMBuildOr(e);

			case And:
				return handleBinaryOp!LLVMBuildAnd(e);

			case Xor:
				return handleBinaryOp!LLVMBuildXor(e);

			case LeftShift:
				return handleBinaryOp!LLVMBuildShl(e);

			case UnsignedRightShift:
				return handleBinaryOp!LLVMBuildLShr(e);

			case SignedRightShift:
				return handleBinaryOp!LLVMBuildAShr(e);

			case LogicalOr:
				return handleLogicalBinary!true(e);

			case LogicalAnd:
				return handleLogicalBinary!false(e);
		}
	}

	private
	LLVMValueRef handleComparison(ICmpExpression e, LLVMIntPredicate pred) {
		// XXX: should be useless, but parameters's order of evaluation
		// not enforced by DMD.
		auto lhs = visit(e.lhs);
		auto rhs = visit(e.rhs);

		return LLVMBuildICmp(builder, pred, lhs, rhs, "");
	}

	private LLVMValueRef handleComparison(
		ICmpExpression e,
		LLVMIntPredicate signedPredicate,
		LLVMIntPredicate unsignedPredicate,
	) {
		auto t = e.lhs.type.getCanonical();
		if (t.kind == TypeKind.Builtin) {
			return handleComparison(
				e, t.builtin.isSigned() ? signedPredicate : unsignedPredicate);
		}

		if (t.kind == TypeKind.Pointer) {
			return handleComparison(e, unsignedPredicate);
		}

		auto t1 = e.lhs.type.toString(context);
		auto t2 = e.rhs.type.toString(context);
		assert(0, "Can't compare " ~ t1 ~ " with " ~ t2);
	}

	LLVMValueRef visit(ICmpExpression e) {
		final switch (e.op) with (ICmpOp) {
			case Equal:
				return handleComparison(e, LLVMIntPredicate.EQ);

			case NotEqual:
				return handleComparison(e, LLVMIntPredicate.NE);

			case GreaterThan:
				return handleComparison(e, LLVMIntPredicate.SGT,
				                        LLVMIntPredicate.UGT);

			case GreaterEqual:
				return handleComparison(e, LLVMIntPredicate.SGE,
				                        LLVMIntPredicate.UGE);

			case SmallerThan:
				return handleComparison(e, LLVMIntPredicate.SLT,
				                        LLVMIntPredicate.ULT);

			case SmallerEqual:
				return handleComparison(e, LLVMIntPredicate.SLE,
				                        LLVMIntPredicate.ULE);
		}
	}

	private LLVMValueRef buildUnary(int Offset, bool IsPost)(Expression e) {
		auto type = e.type.getCanonical();
		auto ptr = addressOf(e);
		auto value = buildLoad(ptr, type.qualifier);
		auto postRet = value;

		auto eType = TypeGen(pass.pass).visit(type);
		if (type.kind == TypeKind.Pointer) {
			auto o =
				LLVMConstInt(LLVMInt32TypeInContext(llvmCtx), Offset, true);
			auto gepType = TypeGen(pass.pass).visit(type.element);
			value = LLVMBuildInBoundsGEP2(builder, gepType, value, &o, 1, "");
		} else {
			value = LLVMBuildAdd(builder, value,
			                     LLVMConstInt(eType, Offset, true), "");
		}

		LLVMBuildStore(builder, value, ptr);
		return IsPost ? postRet : value;
	}

	LLVMValueRef visit(UnaryExpression e) {
		final switch (e.op) with (UnaryOp) {
			case AddressOf:
				return addressOf(e.expr);

			case Dereference:
				return buildLoad(visit(e.expr), e.type.qualifier);

			case PreInc:
				return buildUnary!(1, false)(e.expr);

			case PreDec:
				return buildUnary!(-1, false)(e.expr);

			case PostInc:
				return buildUnary!(1, true)(e.expr);

			case PostDec:
				return buildUnary!(-1, true)(e.expr);

			case Plus:
				return visit(e.expr);

			case Minus:
				auto eType = TypeGen(pass.pass).visit(e.type);
				return LLVMBuildSub(builder, LLVMConstInt(eType, 0, true),
				                    visit(e.expr), "");

			case Not:
				auto eType = TypeGen(pass.pass).visit(e.type);
				return LLVMBuildICmp(
					builder, LLVMIntPredicate.EQ, LLVMConstInt(eType, 0, true),
					visit(e.expr), "");

			case Complement:
				auto eType = TypeGen(pass.pass).visit(e.type);
				return LLVMBuildXor(builder, visit(e.expr),
				                    LLVMConstInt(eType, -1, true), "");
		}
	}

	LLVMValueRef visit(TernaryExpression e) {
		auto cond = visit(e.condition);

		auto condBB = LLVMGetInsertBlock(builder);
		auto fun = LLVMGetBasicBlockParent(condBB);

		auto lhsBB = LLVMAppendBasicBlockInContext(llvmCtx, fun, "ternary_lhs");
		auto rhsBB = LLVMAppendBasicBlockInContext(llvmCtx, fun, "ternary_rhs");
		auto mergeBB =
			LLVMAppendBasicBlockInContext(llvmCtx, fun, "ternary_merge");

		LLVMBuildCondBr(builder, cond, lhsBB, rhsBB);

		// Emit lhs
		LLVMPositionBuilderAtEnd(builder, lhsBB);
		auto lhs = visit(e.lhs);
		// Conclude that block.
		LLVMBuildBr(builder, mergeBB);

		// Codegen of lhs can change the current block, so we put everything in order.
		lhsBB = LLVMGetInsertBlock(builder);
		LLVMMoveBasicBlockAfter(rhsBB, lhsBB);

		// Emit rhs
		LLVMPositionBuilderAtEnd(builder, rhsBB);
		auto rhs = visit(e.rhs);
		// Conclude that block.
		LLVMBuildBr(builder, mergeBB);

		// Codegen of rhs can change the current block, so we put everything in order.
		rhsBB = LLVMGetInsertBlock(builder);
		LLVMMoveBasicBlockAfter(mergeBB, rhsBB);

		// Generate phi to get the result.
		LLVMPositionBuilderAtEnd(builder, mergeBB);

		auto eType = TypeGen(pass.pass).visit(e.type);
		auto phiNode = LLVMBuildPhi(builder, eType, "");

		LLVMValueRef[2] incomingValues = [lhs, rhs];
		LLVMBasicBlockRef[2] incomingBlocks = [lhsBB, rhsBB];

		LLVMAddIncoming(phiNode, incomingValues.ptr, incomingBlocks.ptr,
		                incomingValues.length);

		return phiNode;
	}

	LLVMValueRef visit(VariableExpression e) {
		return (e.var.storage == Storage.Enum || e.var.isFinal)
			? declare(e.var)
			: loadAddressOf(e);
	}

	LLVMValueRef visit(FieldExpression e) {
		if (e.isLvalue) {
			return loadAddressOf(e);
		}

		assert(e.expr.type.kind != TypeKind.Union,
		       "rvalue unions not implemented.");
		return LLVMBuildExtractValue(builder, visit(e.expr), e.field.index, "");
	}

	LLVMValueRef visit(FunctionExpression e) {
		return declare(e.fun);
	}

	private
	LLVMValueRef genMethod(LLVMValueRef dg, Expression[] contexts, Function f) {
		auto m = cast(Method) f;
		if (m is null || m.isFinal) {
			return declare(f);
		}

		// Virtual dispatch.
		assert(m.hasThis);

		auto classType = contexts[m.hasContext].type.getCanonical();
		assert(classType.kind == TypeKind.Class,
		       "Virtual dispatch can only be done on classes");

		auto thisType = LLVMStructGetTypeAtIndex(LLVMTypeOf(dg), m.hasContext);
		auto metadataType =
			LLVMStructGetTypeAtIndex(LLVMGetElementType(thisType), 0);

		LLVMValueRef metadata;
		auto c = classType.dclass;
		if (c.isFinal) {
			metadata =
				LLVMBuildBitCast(builder, getTypeid(c), metadataType, "");
		} else {
			auto thisPtr = LLVMBuildExtractValue(builder, dg, m.hasContext, "");
			auto mdPtrType = LLVMPointerType(metadataType, 0);
			auto metadataPtr =
				LLVMBuildBitCast(builder, thisPtr, mdPtrType, "");
			metadata = LLVMBuildLoad2(builder, metadataType, metadataPtr, "");
		}

		auto mdStruct = LLVMGetElementType(metadataType);
		auto vtbl = LLVMBuildStructGEP2(builder, mdStruct, metadata, 1, "vtbl");
		auto vtblType = LLVMStructGetTypeAtIndex(mdStruct, 1);
		auto funPtr = LLVMBuildStructGEP2(builder, vtblType, vtbl, m.index, "");
		auto funType = LLVMStructGetTypeAtIndex(vtblType, m.index);
		return LLVMBuildLoad2(builder, funType, funPtr, "");
	}

	LLVMValueRef visit(DelegateExpression e) {
		auto type = e.type.getCanonical().asFunctionType();
		auto tCtxs = type.contexts;
		auto eCtxs = e.contexts;

		auto length = cast(uint) tCtxs.length;
		assert(eCtxs.length == length);

		auto dg = LLVMGetUndef(TypeGen(pass.pass).visit(type));

		foreach (i, c; eCtxs) {
			auto ctxValue = tCtxs[i].isRef ? addressOf(c) : visit(c);
			dg = LLVMBuildInsertValue(builder, dg, ctxValue, cast(uint) i, "");
		}

		auto m = genMethod(dg, eCtxs, e.method);
		return LLVMBuildInsertValue(builder, dg, m, length, "");
	}

	LLVMValueRef visit(NewExpression e) {
		auto ctor = declare(e.ctor);

		import std.algorithm, std.array;
		auto args = e.args.map!(a => visit(a)).array();

		auto type = TypeGen(pass.pass).visit(e.type);
		LLVMValueRef size = LLVMSizeOf(
			(e.type.kind == TypeKind.Class) ? LLVMGetElementType(type) : type);

		auto allocFun = declare(pass.object.getGCThreadLocalAllow());
		auto alloc = buildCall(allocFun, [size]);
		auto ptr = LLVMBuildPointerCast(builder, alloc, type, "");

		// XXX: This should be set on the alloc function instead of the callsite.
		LLVMAddCallSiteAttribute(alloc, LLVMAttributeReturnIndex,
		                         getAttribute("noalias"));

		auto thisArg = visit(e.dinit);
		auto thisType = LLVMTypeOf(LLVMGetFirstParam(ctor));
		bool isClass = LLVMGetTypeKind(thisType) == LLVMTypeKind.Pointer;
		if (isClass) {
			auto ptrType = LLVMPointerType(LLVMTypeOf(thisArg), 0);
			auto thisPtr = LLVMBuildBitCast(builder, ptr, ptrType, "");
			LLVMBuildStore(builder, thisArg, thisPtr);
			thisArg = LLVMBuildBitCast(builder, ptr, thisType, "");
		}

		args = thisArg ~ args;
		auto obj = buildCall(ctor, args);
		if (!isClass) {
			LLVMBuildStore(builder, obj, ptr);
		}

		return ptr;
	}

	LLVMValueRef visit(IndexExpression e)
			in(e.isLvalue, "e must be an lvalue") {
		return loadAddressOf(e);
	}

	auto genBoundCheck(Location location, LLVMValueRef condition) {
		auto fun = LLVMGetBasicBlockParent(LLVMGetInsertBlock(builder));

		auto failBB = LLVMAppendBasicBlockInContext(llvmCtx, fun, "bound_fail");
		auto okBB = LLVMAppendBasicBlockInContext(llvmCtx, fun, "bound_ok");

		auto br = LLVMBuildCondBr(builder, condition, okBB, failBB);

		// We assume that bound check fail is unlikely.
		LLVMSetMetadata(br, profKindID, unlikelyBranch);

		// Emit bound check fail code.
		LLVMPositionBuilderAtEnd(builder, failBB);

		auto floc = location.getFullLocation(context);

		LLVMValueRef[2] args = [
			buildDString(floc.getSource().getFileName().toString()),
			LLVMConstInt(LLVMInt32TypeInContext(llvmCtx),
			             floc.getStartLineNumber(), false)
		];

		buildCall(declare(pass.object.getArrayOutOfBounds()), args);

		LLVMBuildUnreachable(builder);

		// And continue regular program flow.
		LLVMPositionBuilderAtEnd(builder, okBB);
	}

	LLVMValueRef visit(SliceExpression e) {
		auto t = e.sliced.type.getCanonical();
		auto i64 = LLVMInt64TypeInContext(llvmCtx);

		LLVMValueRef length, ptr;
		if (t.kind == TypeKind.Slice) {
			auto slice = visit(e.sliced);

			length = LLVMBuildExtractValue(builder, slice, 0, ".length");
			ptr = LLVMBuildExtractValue(builder, slice, 1, ".ptr");
		} else if (t.kind == TypeKind.Pointer) {
			ptr = visit(e.sliced);
		} else if (t.kind == TypeKind.Array) {
			length = LLVMConstInt(i64, t.size, false);
			ptr = addressOf(e.sliced);

			auto eType = TypeGen(pass.pass).visit(t.element);
			auto ptrType = LLVMPointerType(eType, 0);
			ptr = LLVMBuildBitCast(builder, ptr, ptrType, "");
		} else {
			assert(0, "Don't know how to slice " ~ e.type.toString(context));
		}

		auto first = LLVMBuildZExt(builder, visit(e.first), i64, "");
		auto second = LLVMBuildZExt(builder, visit(e.second), i64, "");

		auto condition =
			LLVMBuildICmp(builder, LLVMIntPredicate.ULE, first, second, "");
		if (length) {
			auto boundCheck = LLVMBuildICmp(builder, LLVMIntPredicate.ULE,
			                                second, length, "");
			condition = LLVMBuildAnd(builder, condition, boundCheck, "");
		}

		genBoundCheck(e.location, condition);

		auto sliceType = TypeGen(pass.pass).visit(e.type);
		auto slice = LLVMGetUndef(sliceType);

		auto sub = LLVMBuildSub(builder, second, first, "");
		slice = LLVMBuildInsertValue(builder, slice, sub, 0, "");

		auto eType = LLVMGetElementType(LLVMTypeOf(ptr));
		ptr = LLVMBuildInBoundsGEP2(builder, eType, ptr, &first, 1, "");
		slice = LLVMBuildInsertValue(builder, slice, ptr, 1, "");

		return slice;
	}

	// FIXME: This is public because of intrinsic codegen.
	// Once we support sequence return, we can make that private.
	LLVMValueRef buildBitCast(LLVMValueRef v, LLVMTypeRef t) {
		auto k = LLVMGetTypeKind(t);
		if (k != LLVMTypeKind.Struct) {
			assert(k != LLVMTypeKind.Array);
			return LLVMBuildBitCast(builder, v, t, "");
		}

		auto vt = LLVMTypeOf(v);
		assert(LLVMGetTypeKind(vt) == LLVMTypeKind.Struct);

		auto count = LLVMCountStructElementTypes(t);
		assert(LLVMCountStructElementTypes(vt) == count);

		LLVMTypeRef[] types;
		types.length = count;

		LLVMGetStructElementTypes(t, types.ptr);

		auto ret = LLVMGetUndef(t);
		foreach (i; 0 .. count) {
			ret = LLVMBuildInsertValue(
				builder,
				ret,
				buildBitCast(LLVMBuildExtractValue(builder, v, i, ""),
				             types[i]),
				i,
				""
			);
		}

		return ret;
	}

	// FIXME: This should forward to a template in object.d
	// instead of reimplenting the logic.
	LLVMValueRef buildDownCast(LLVMValueRef value, Class c) {
		auto type = TypeGen(pass.pass).visit(c);
		auto bitcast = LLVMBuildBitCast(builder, value, type, "");
		auto nullcast = LLVMConstNull(type);

		auto otid = getTypeid(value);
		auto ctid = getTypeid(c);

		auto typeidType = LLVMTypeOf(ctid);
		auto typeidStruct = LLVMGetElementType(typeidType);
		auto pType = LLVMStructGetTypeAtIndex(typeidStruct, 1);
		auto dType = LLVMStructGetTypeAtIndex(pType, 0);
		auto ptrType = LLVMStructGetTypeAtIndex(pType, 1);

		if (c.isFinal) {
			auto cmp =
				LLVMBuildICmp(builder, LLVMIntPredicate.EQ, otid, ctid, "");
			return LLVMBuildSelect(builder, cmp, bitcast, nullcast, "");
		}

		// If c is deeper in the hierarchy than the value,
		// then it is impossible for the value to be of type c.
		auto oPrimitives =
			LLVMBuildStructGEP2(builder, typeidStruct, otid, 1, "");
		auto oDepthPtr =
			LLVMBuildStructGEP2(builder, pType, oPrimitives, 0, "");
		auto oDepth = LLVMBuildLoad2(builder, dType, oDepthPtr, "");

		// This should constant fold.
		auto cPrimitives =
			LLVMBuildStructGEP2(builder, typeidStruct, ctid, 1, "");
		auto cDepthPtr =
			LLVMBuildStructGEP2(builder, pType, cPrimitives, 0, "");
		auto cDepth = LLVMBuildLoad2(builder, dType, cDepthPtr, "");
		auto one = LLVMConstInt(LLVMInt64TypeInContext(llvmCtx), 1, false);
		auto index = LLVMBuildSub(builder, cDepth, one, "");

		auto depthCheck =
			LLVMBuildICmp(builder, LLVMIntPredicate.UGT, oDepth, index, "");

		auto depthCheckBB = LLVMGetInsertBlock(builder);
		auto fun = LLVMGetBasicBlockParent(depthCheckBB);

		auto downCastBB =
			LLVMAppendBasicBlockInContext(llvmCtx, fun, "downcast.check");
		auto mergeBB =
			LLVMAppendBasicBlockInContext(llvmCtx, fun, "downcast.merge");

		LLVMBuildCondBr(builder, depthCheck, downCastBB, mergeBB);

		// Check if the parent of the value at c's depth is c.
		LLVMPositionBuilderAtEnd(builder, downCastBB);
		auto primitivesPtr =
			LLVMBuildStructGEP2(builder, pType, oPrimitives, 1, "");
		auto primitives = LLVMBuildLoad2(builder, ptrType, primitivesPtr, "");
		auto parentPtr = LLVMBuildInBoundsGEP2(builder, typeidType, primitives,
		                                       &index, 1, "");
		auto parent = LLVMBuildLoad2(builder, typeidType, parentPtr, "");
		auto typeCheck =
			LLVMBuildICmp(builder, LLVMIntPredicate.EQ, parent, ctid, "");
		auto downcast =
			LLVMBuildSelect(builder, typeCheck, bitcast, nullcast, "");

		// Merge and generate Phi node.
		LLVMBuildBr(builder, mergeBB);
		LLVMPositionBuilderAtEnd(builder, mergeBB);

		auto phiNode = LLVMBuildPhi(builder, type, "");

		LLVMValueRef[2] incomingValues = [nullcast, downcast];
		LLVMBasicBlockRef[2] incomingBlocks = [depthCheckBB, downCastBB];

		LLVMAddIncoming(phiNode, incomingValues.ptr, incomingBlocks.ptr,
		                incomingValues.length);

		return phiNode;
	}

	LLVMValueRef visit(CastExpression e) {
		auto value = visit(e.expr);
		if (e.kind == CastKind.Exact || e.kind == CastKind.Qual) {
			return value;
		}

		auto t = e.type.getCanonical();
		if (e.kind == CastKind.Down) {
			return buildDownCast(value, t.dclass);
		}

		auto type = TypeGen(pass.pass).visit(t);

		final switch (e.kind) with (CastKind) {
			case Bit:
				return buildBitCast(value, type);

			case UPad:
				return LLVMBuildZExt(builder, value, type, "");

			case SPad:
				return LLVMBuildSExt(builder, value, type, "");

			case Trunc:
				return LLVMBuildTrunc(builder, value, type, "");

			case IntToPtr:
				return LLVMBuildIntToPtr(builder, value, type, "");

			case PtrToInt:
				return LLVMBuildPtrToInt(builder, value, type, "");

			case IntToBool:
				return LLVMBuildICmp(
					builder, LLVMIntPredicate.NE, value,
					LLVMConstInt(LLVMTypeOf(value), 0, false), "");

			case FloatTrunc:
				return LLVMBuildFPTrunc(builder, value, type, "");

			case FloatExtend:
				return LLVMBuildFPExt(builder, value, type, "");

			case FloatToSigned:
				return LLVMBuildFPToSI(builder, value, type, "");

			case FloatToUnsigned:
				return LLVMBuildFPToUI(builder, value, type, "");

			case SignedToFloat:
				return LLVMBuildSIToFP(builder, value, type, "");

			case UnsignedToFloat:
				return LLVMBuildUIToFP(builder, value, type, "");

			case Exact, Qual, Down:
				assert(0, "Unreachable");

			case Invalid:
				assert(0, "Invalid cast");
		}
	}

	LLVMValueRef visit(ArrayLiteral e) {
		auto t = e.type;
		auto count = cast(uint) e.values.length;

		auto eType = TypeGen(pass.pass).visit(t.element);
		auto type = LLVMArrayType(eType, count);
		auto array = LLVMGetUndef(type);

		uint i = 0;
		import std.algorithm;
		foreach (v; e.values.map!(v => visit(v))) {
			array = LLVMBuildInsertValue(builder, array, v, i++, "");
		}

		if (t.kind == TypeKind.Array) {
			return array;
		}

		auto ptrType = LLVMPointerType(type, 0);
		auto ptr = LLVMConstNull(ptrType);

		if (count > 0) {
			// We have a slice, we need to allocate.
			auto allocFun = declare(pass.object.getGCThreadLocalAllow());
			auto alloc = buildCall(allocFun, [LLVMSizeOf(type)]);
			ptr = LLVMBuildPointerCast(builder, alloc, ptrType, "");

			// XXX: This should be set on the alloc function instead of the callsite.
			LLVMAddCallSiteAttribute(alloc, LLVMAttributeReturnIndex,
			                         getAttribute("noalias"));

			// Store all the values on heap.
			LLVMBuildStore(builder, array, ptr);
		}

		// Build the slice.
		auto slice = LLVMGetUndef(TypeGen(pass.pass).visit(t));
		auto llvmCount =
			LLVMConstInt(LLVMInt64TypeInContext(llvmCtx), count, false);
		slice = LLVMBuildInsertValue(builder, slice, llvmCount, 0, "");

		auto elPtrType = LLVMPointerType(eType, 0);
		ptr = LLVMBuildPointerCast(builder, ptr, elPtrType, "");
		slice = LLVMBuildInsertValue(builder, slice, ptr, 1, "");

		return slice;
	}

	auto buildCall(LLVMValueRef callee, LLVMValueRef[] args) {
		auto funType = LLVMGetElementType(LLVMTypeOf(callee));

		// Check if we need to invoke.
		if (!lpBB) {
			return LLVMBuildCall2(builder, funType, callee, args.ptr,
			                      cast(uint) args.length, "");
		}

		auto currentBB = LLVMGetInsertBlock(builder);
		auto fun = LLVMGetBasicBlockParent(currentBB);
		auto thenBB = LLVMAppendBasicBlockInContext(llvmCtx, fun, "then");
		auto ret = LLVMBuildInvoke2(builder, funType, callee, args.ptr,
		                            cast(uint) args.length, thenBB, lpBB, "");

		LLVMMoveBasicBlockAfter(thenBB, currentBB);
		LLVMPositionBuilderAtEnd(builder, thenBB);

		return ret;
	}

	private LLVMValueRef buildCall(CallExpression c) {
		auto cType = c.callee.type.getCanonical().asFunctionType();
		auto contexts = cType.contexts;
		auto params = cType.parameters;

		LLVMValueRef[] args;
		args.length = contexts.length + c.args.length;

		auto callee = visit(c.callee);
		foreach (i, ctx; contexts) {
			args[i] = LLVMBuildExtractValue(builder, callee, cast(uint) i, "");
		}

		auto firstarg = contexts.length;
		if (firstarg) {
			callee = LLVMBuildExtractValue(builder, callee,
			                               cast(uint) contexts.length, "");
		}

		uint i = 0;
		foreach (t; params) {
			args[i + firstarg] =
				t.isRef ? addressOf(c.args[i]) : visit(c.args[i]);
			i++;
		}

		// Handle variadic functions.
		while (i < c.args.length) {
			args[i + firstarg] = visit(c.args[i]);
			i++;
		}

		return buildCall(callee, args);
	}

	LLVMValueRef visit(CallExpression c) {
		auto r = buildCall(c);
		auto isRef = c.callee.type.asFunctionType().returnType.isRef;
		if (!isRef) {
			return r;
		}

		auto returnType = TypeGen(pass.pass).visit(c.type);
		return LLVMBuildLoad2(builder, returnType, r, "");
	}

	LLVMValueRef visit(IntrinsicExpression e) {
		import d.llvm.intrinsic, d.llvm.type;
		return buildBitCast(
			IntrinsicGen(pass).build(e.intrinsic, e.args),
			// XXX: This is necessary until returning sequence is supported.
			TypeGen(pass.pass).visit(e.type)
		);
	}

	LLVMValueRef visit(TupleExpression e) {
		auto tuple = LLVMGetUndef(TypeGen(pass.pass).visit(e.type));

		uint i = 0;
		import std.algorithm;
		foreach (v; e.values.map!(v => visit(v))) {
			tuple = LLVMBuildInsertValue(builder, tuple, v, i++, "");
		}

		return tuple;
	}

	private LLVMValueRef getTypeid(LLVMValueRef value) {
		auto cType = LLVMGetElementType(LLVMTypeOf(value));
		auto tidType = LLVMStructGetTypeAtIndex(cType, 0);
		auto tid = LLVMBuildLoad2(builder, tidType, value, "");

		auto classInfo = TypeGen(pass.pass).visit(pass.object.getClassInfo());
		return LLVMBuildBitCast(builder, tid, classInfo, "");
	}

	LLVMValueRef visit(DynamicTypeidExpression e) {
		return getTypeid(visit(e.argument));
	}

	private LLVMValueRef getTypeid(Class c) {
		return TypeGen(pass.pass).getTypeInfo(c);
	}

	private LLVMValueRef getTypeid(Type t) {
		t = t.getCanonical();
		assert(t.kind == TypeKind.Class, "Not implemented");

		// Ensure that the thing is generated.
		return getTypeid(t.dclass);
	}

	LLVMValueRef visit(StaticTypeidExpression e) {
		return getTypeid(e.argument);
	}
}

struct AddressOfGen {
	private LocalPass pass;
	alias pass this;

	this(LocalPass pass) {
		this.pass = pass;
	}

	LLVMValueRef visit(Expression e)
			in(e.isLvalue, "You can only compute addresses of lvalues.") {
		return this.dispatch(e);
	}

	private LLVMValueRef valueOf(E)(E e) if (is(E : Expression)) {
		return ExpressionGen(pass).visit(e);
	}

	LLVMValueRef visit(VariableExpression e) in {
		assert(e.var.storage != Storage.Enum, "enum have no address.");
		assert(!e.var.isFinal, "finals have no address.");
	} do {
		return declare(e.var);
	}

	LLVMValueRef visit(FieldExpression e) {
		auto base = e.expr;
		auto type = base.type.getCanonical();

		LLVMValueRef ptr;
		switch (type.kind) with (TypeKind) {
			case Slice, Struct, Union:
				ptr = visit(base);
				break;

			// XXX: Remove pointer. libd do not dererefence as expected.
			case Pointer, Class:
				ptr = valueOf(base);
				break;

			default:
				assert(
					0,
					"Address of field only work on aggregate types, not "
						~ type.toString(context)
				);
		}

		// Make sure the type is not opaque.
		// XXX: Find a factorized way to load and gep that ensure
		// the indexed is not opaque and load metadata are correct.
		TypeGen(pass.pass).visit(type);

		auto baseType = LLVMGetElementType(LLVMTypeOf(ptr));
		ptr = LLVMBuildStructGEP2(builder, baseType, ptr, e.field.index, "");
		if (type.kind != TypeKind.Union) {
			return ptr;
		}

		auto eType = TypeGen(pass.pass).visit(e.type);
		return LLVMBuildBitCast(builder, ptr, LLVMPointerType(eType, 0), "");
	}

	LLVMValueRef visit(ContextExpression e)
			in(e.type.kind == TypeKind.Context,
			   "ContextExpression must be of ContextType") {
		return pass.getContext(e.type.context);
	}

	LLVMValueRef visit(UnaryExpression e) {
		if (e.op == UnaryOp.Dereference) {
			return valueOf(e.expr);
		}

		assert(0, "not an lvalue ??");
	}

	LLVMValueRef visit(CastExpression e) {
		auto type = TypeGen(pass.pass).visit(e.type);
		auto value = visit(e.expr);

		final switch (e.kind) with (CastKind) {
			case Exact, Qual:
				return value;

			case Bit:
				return LLVMBuildBitCast(builder, value,
				                        LLVMPointerType(type, 0), "");

			case Invalid, IntToPtr, PtrToInt, Down:
			case IntToBool, Trunc, SPad, UPad:
			case FloatToSigned, FloatToUnsigned:
			case UnsignedToFloat, SignedToFloat:
			case FloatExtend, FloatTrunc:
				assert(0, "Not an lvalue");
		}
	}

	LLVMValueRef visit(CallExpression c) {
		return ExpressionGen(pass).buildCall(c);
	}

	LLVMValueRef visit(IndexExpression e) {
		return computeIndexPtr(e.location, e.indexed, e.index);
	}

	auto computeIndexPtr(Location location, Expression indexed,
	                     Expression index) {
		auto t = indexed.type.getCanonical();
		switch (t.kind) with (TypeKind) {
			case Slice:
				auto slice = valueOf(indexed);
				auto ptr = LLVMBuildExtractValue(builder, slice, 1, ".ptr");
				auto i = LLVMBuildZExt(builder, valueOf(index),
				                       LLVMInt64TypeInContext(llvmCtx), "");
				auto eType = LLVMGetElementType(LLVMTypeOf(ptr));

				auto length =
					LLVMBuildExtractValue(builder, slice, 0, ".length");
				auto condition =
					LLVMBuildICmp(builder, LLVMIntPredicate.ULT, i, length, "");
				genBoundCheck(location, condition);

				return LLVMBuildInBoundsGEP2(builder, eType, ptr, &i, 1, "");

			case Pointer:
				auto ptr = valueOf(indexed);
				auto i = valueOf(index);
				auto eType = LLVMGetElementType(LLVMTypeOf(ptr));
				return LLVMBuildInBoundsGEP2(builder, eType, ptr, &i, 1, "");

			case Array:
				auto ptr = visit(indexed);
				auto i = valueOf(index);
				auto eType = LLVMGetElementType(LLVMTypeOf(ptr));

				auto i64 = LLVMInt64TypeInContext(llvmCtx);
				auto condition = LLVMBuildICmp(
					builder,
					LLVMIntPredicate.ULT,
					LLVMBuildZExt(builder, i, i64, ""),
					LLVMConstInt(i64, t.size, false),
					""
				);

				genBoundCheck(location, condition);

				LLVMValueRef[2] indices = [LLVMConstInt(i64, 0, false), i];
				return LLVMBuildInBoundsGEP2(builder, eType, ptr, indices.ptr,
				                             indices.length, "");

			default:
				break;
		}

		assert(0, "Don't know how to index " ~ indexed.type.toString(context));
	}

	auto genBoundCheck(Location location, LLVMValueRef condition) {
		return ExpressionGen(pass).genBoundCheck(location, condition);
	}
}
