module d.llvm.backend;

import d.llvm.codegen;
import d.llvm.evaluator;
import d.llvm.datalayout;

import d.ir.symbol;

import llvm.c.core;
import llvm.c.target;
import llvm.c.targetMachine;

final class LLVMBackend {
private:
	import d.llvm.global;
	GlobalGen globalGen;

	@property
	auto pass() {
		return globalGen.pass;
	}

	import d.llvm.config;
	LLVMConfig _config;

	LLVMEvaluator evaluator;
	LLVMDataLayout dataLayout;

	LLVMTargetMachineRef targetMachine;

public:
	@property
	auto config() const {
		return _config;
	}

	import d.semantic.semantic;
	this(SemanticPass sema, LLVMConfig config, Module main) {
		this._config = config;

		import llvm.c.executionEngine;
		LLVMLinkInMCJIT();

		LLVMInitializeX86TargetInfo();
		LLVMInitializeX86Target();
		LLVMInitializeX86TargetMC();
		LLVMInitializeX86AsmPrinter();

		version(OSX) {
			auto triple = "x86_64-apple-darwin9".ptr;
		} else version(FreeBSD) {
			auto triple = "x86_64-unknown-freebsd".ptr;
		} else {
			auto triple = "x86_64-pc-linux-gnu".ptr;
		}

		version(linux) {
			enum Reloc = LLVMRelocMode.PIC;
		} else {
			enum Reloc = LLVMRelocMode.Default;
		}

		targetMachine = LLVMCreateTargetMachine(
			LLVMGetFirstTarget(), triple, "x86-64", "",
			LLVMCodeGenOptLevel.Default, Reloc, LLVMCodeModel.Default);

		auto pass = new CodeGen(sema, main, targetMachine, config.debugBuild);
		globalGen = GlobalGen(pass);
		dataLayout = new LLVMDataLayout(pass, pass.targetData);
	}

	~this() {
		LLVMDisposeTargetMachine(targetMachine);
	}

	auto getEvaluator() {
		if (evaluator is null) {
			evaluator = new LLVMEvaluator(pass);
		}

		return evaluator;
	}

	auto getDataLayout() {
		return dataLayout;
	}

	void define(Function f) {
		globalGen.define(f);
	}

	private void runLLVMPasses() {
		import llvm.c.transforms.passBuilder;
		auto opts = LLVMCreatePassBuilderOptions();
		scope(exit) LLVMDisposePassBuilderOptions(opts);

		char[12] passes = "default<O?>\0";
		passes[9] = cast(char) ('0' + config.optLevel);

		LLVMRunPasses(globalGen.dmodule, passes.ptr, targetMachine, opts);
	}

	private void emitModules(Module[] modules) {
		foreach (m; modules) {
			globalGen.define(m);
		}

		runLLVMPasses();
	}

	void emitObject(Module[] modules, string objFile) {
		emitModules(modules);

		import std.string;
		auto cobjFile = objFile.toStringz();

		char* errorPtr;
		if (!LLVMTargetMachineEmitToFile(
			    targetMachine, globalGen.dmodule, cobjFile,
			    LLVMCodeGenFileType.Object, &errorPtr)) {
			return;
		}

		scope(exit) LLVMDisposeMessage(errorPtr);

		import core.stdc.string;
		auto error = errorPtr[0 .. strlen(errorPtr)].idup;
		throw new Exception(error);
	}

	void emitAsm(Module[] modules, string filename) {
		emitModules(modules);

		import std.string;
		auto cfilename = filename.toStringz();

		char* errorPtr;
		if (!LLVMTargetMachineEmitToFile(
			    targetMachine, globalGen.dmodule, cfilename,
			    LLVMCodeGenFileType.Assembly, &errorPtr)) {
			return;
		}

		scope(exit) LLVMDisposeMessage(errorPtr);

		import core.stdc.string;
		auto error = errorPtr[0 .. strlen(errorPtr)].idup;
		throw new Exception(error);
	}

	void emitLLVMAsm(Module[] modules, string filename) {
		emitModules(modules);

		import std.string;
		auto cfilename = filename.toStringz();

		char* errorPtr;
		if (!LLVMPrintModuleToFile(globalGen.dmodule, cfilename, &errorPtr)) {
			return;
		}

		scope(exit) LLVMDisposeMessage(errorPtr);

		import core.stdc.string;
		auto error = errorPtr[0 .. strlen(errorPtr)].idup;
		throw new Exception(error);
	}

	void emitLLVMBitcode(Module[] modules, string filename) {
		emitModules(modules);

		import std.string;
		auto cfilename = filename.toStringz();

		import llvm.c.bitWriter;
		if (!LLVMWriteBitcodeToFile(globalGen.dmodule, filename.toStringz())) {
			return;
		}

		throw new Exception("Failed to output LLVM bitcode file.");
	}

	void link(string objFile, string executable) {
		import std.algorithm, std.array;
		auto params =
			config.linkerPaths.map!(path => " -L" ~ (cast(string) path)).join();

		import std.process;
		auto linkCommand = "gcc -o " ~ escapeShellFileName(executable) ~ " "
			~ escapeShellFileName(objFile) ~ params
			~ " -lsdrt -lphobos -lpthread -ldl";

		wait(spawnShell(linkCommand));
	}

	auto runUnittests(Module[] modules) {
		// In a first step, we do all the codegen.
		// We need to do it in a first step so that we can reuse
		// one instance of MCJIT.
		auto e = getEvaluator();

		struct Test {
			Function unit;
			LLVMValueRef stub;

			this(LLVMEvaluator e, Function t) {
				unit = t;
				stub = e.createTestStub(t);
			}
		}

		Test[] tests;
		foreach (m; modules) {
			foreach (t; m.tests) {
				import source.name;
				tests ~= Test(e, t);
			}
		}

		runLLVMPasses();

		// Now that we generated the IR, we run the unittests.
		auto ee = createExecutionEngine(globalGen.dmodule);
		scope(exit) destroyExecutionEngine(ee, globalGen.dmodule);

		struct Result {
			import std.bitmanip;
			mixin(taggedClassRef!(
				// sdfmt off
				Function, "test",
				bool, "pass", 1,
				// sdfmt on
			));

			this(Function test, bool pass) {
				this.test = test;
				this.pass = pass;
			}
		}

		Result[] results;

		foreach (t; tests) {
			import llvm.c.executionEngine;
			auto result = LLVMRunFunction(ee, t.stub, 0, null);
			scope(exit) LLVMDisposeGenericValue(result);

			// Check the return value and report.
			// TODO: We need to make a specific report of the failure
			// if indeed there is failure.
			bool pass = !LLVMGenericValueToInt(result, false);
			results ~= Result(t.unit, pass);
		}

		return results;
	}
}
