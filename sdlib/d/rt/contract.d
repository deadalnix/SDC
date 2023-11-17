module d.rt.contract;

enum DbgPrintBufferSize = 4096;

static char[DbgPrintBufferSize] _dbgPrintBuffer;

extern(C):

void __sd_assert_fail(string file, int line) {
	import core.stdc.stdlib, core.stdc.unistd, core.stdc.stdio;
	auto len = snprintf(_dbgPrintBuffer.ptr, DbgPrintBufferSize,
	                    "assert fail: %s:%d\n", file.ptr, line);
	write(STDERR_FILENO, _dbgPrintBuffer.ptr, len);
	exit(1);
}

void __sd_assert_fail_msg(string msg, string file, int line) {
	import core.stdc.stdlib, core.stdc.unistd, core.stdc.stdio;
	auto len = snprintf(_dbgPrintBuffer.ptr, DbgPrintBufferSize, "%s: %s:%d\n",
	                    msg.ptr, file.ptr, line);
	write(STDERR_FILENO, _dbgPrintBuffer.ptr, len);
	exit(1);
}
