// RUN: %sdc %s -O2 -S --emit-llvm -o - | FileCheck %s
module intrinsics;

import sdc.intrinsics;

void doAlloca(size_t s) {
	auto a = alloca(s);

	static void consume(void*);
	consume(a);
	// CHECK-LABEL: _D10intrinsics8doAllocaFMmZv
	// CHECK: [[PTR:%[a-z0-9\.]+]] = alloca i8, i64 %arg.s, align 16
	// CHECK: call void @_D10intrinsics8doAlloca7consumeFMPvZv(ptr nonnull [[PTR]])
	// CHECK: ret void
}

ulong doPopCount(ubyte n1, ushort n2, uint n3, ulong n4) {
	return popCount(n1) + popCount(n2) + popCount(n3) + popCount(n4);
	// CHECK-LABEL: _D10intrinsics10doPopCountFMhtkmZm
	// CHECK: call range(i8 0, 9) i8 @llvm.ctpop.i8(i8 {{.*}})
	// CHECK: call range(i16 0, 17) i16 @llvm.ctpop.i16(i16 {{.*}})
	// CHECK: call range(i32 0, 33) i32 @llvm.ctpop.i32(i32 {{.*}})
	// CHECK: call range(i64 0, 65) i64 @llvm.ctpop.i64(i64 {{.*}})
}

ulong doCountLeadingZeros(ubyte n1, ushort n2, uint n3, ulong n4) {
	auto a = countLeadingZeros(n1) + countLeadingZeros(n2);
	auto b = countLeadingZeros(n3) + countLeadingZeros(n4);
	return a + b;
	// CHECK-LABEL: _D10intrinsics19doCountLeadingZerosFMhtkmZm
	// CHECK: call range(i8 0, 9) i8 @llvm.ctlz.i8(i8 {{.*}})
	// CHECK: call range(i16 0, 17) i16 @llvm.ctlz.i16(i16 {{.*}})
	// CHECK: call range(i32 0, 33) i32 @llvm.ctlz.i32(i32 {{.*}})
	// CHECK: call range(i64 0, 65) i64 @llvm.ctlz.i64(i64 {{.*}})
}

ulong doCountTrailingZeros(ubyte n1, ushort n2, uint n3, ulong n4) {
	auto a = countTrailingZeros(n1) + countTrailingZeros(n2);
	auto b = countTrailingZeros(n3) + countTrailingZeros(n4);
	return a + b;
	// CHECK-LABEL: _D10intrinsics20doCountTrailingZerosFMhtkmZm
	// CHECK: call range(i8 0, 9) i8 @llvm.cttz.i8(i8 {{.*}})
	// CHECK: call range(i16 0, 17) i16 @llvm.cttz.i16(i16 {{.*}})
	// CHECK: call range(i32 0, 33) i32 @llvm.cttz.i32(i32 {{.*}})
	// CHECK: call range(i64 0, 65) i64 @llvm.cttz.i64(i64 {{.*}})
}

ulong doBswap(ushort n1, uint n2, ulong n3) {
	return bswap(n1) + bswap(n2) + bswap(n3);
	// CHECK-LABEL: _D10intrinsics7doBswapFMtkmZm
	// CHECK: call i16 @llvm.bswap.i16(i16 {{.*}})
	// CHECK: call i32 @llvm.bswap.i32(i32 {{.*}})
	// CHECK: call i64 @llvm.bswap.i64(i64 {{.*}})
}

bool doCas(uint* ptr, uint old, uint val) {
	auto cr = cas(ptr, old, val);
	return cr.success;
	// CHECK-LABEL: _D10intrinsics5doCasFMPkkkZb
	// CHECK: [[CMPXCHG:%[a-z0-9\.]+]] = cmpxchg ptr %arg.ptr, i32 %arg.old, i32 %arg.val seq_cst seq_cst, align 4
	// CHECK: [[RET:%[a-z0-9\.]+]] = extractvalue { i32, i1 } [[CMPXCHG]], 1
	// CHECK: ret i1 [[RET]]
}

bool doCasWeak(uint* ptr, uint old, uint val) {
	auto cr = casWeak(ptr, old, val);
	return cr.success;
	// CHECK-LABEL: _D10intrinsics9doCasWeakFMPkkkZb
	// CHECK: [[CMPXCHG:%[a-z0-9\.]+]] = cmpxchg weak ptr %arg.ptr, i32 %arg.old, i32 %arg.val seq_cst seq_cst, align 4
	// CHECK: [[RET:%[a-z0-9\.]+]] = extractvalue { i32, i1 } [[CMPXCHG]], 1
	// CHECK: ret i1 [[RET]]
}

ulong doReadCycleCounter() {
	// CHECK-LABEL: _D10intrinsics18doReadCycleCounterFMZm
	// CHECK:[[RET:%[a-z0-9\.]+]] = tail call i64 @llvm.readcyclecounter()
	// CHECK: ret i64 [[RET]]
	return readCycleCounter();
}

void* doReadFramePointer() {
	// CHECK-LABEL: _D10intrinsics18doReadFramePointerFMZPv
	// CHECK:[[RET:%[a-z0-9\.]+]] = tail call ptr @llvm.frameaddress.p0(i32 0)
	// CHECK: ret ptr [[RET]]
	return readFramePointer();
}
