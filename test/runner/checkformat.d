#!/usr/bin/env -S sh -c 'rdmd -I`dirname "$0"` "$0" "$@"'
/**
 * Copyright 2010-2011 Bernard Helyer
 * Copyright 2011 Jakob Ovrum
 */
module checkformat;

import util;

immutable SDFMT = "bin/sdfmt";

// tests a file on disk
struct Task {
	string name;
	string formatter;

	TestResult run() {
		import std.file;
		string original = cast(string) read(name);

		import std.process;
		auto result = execute([formatter, name]);

		return check(name, original, result.status, result.output);
	}
}

// tests a file by passing its contents manually in stdin (and specifying the original path via --assume-filename)
struct StdinTask {
	string name;
	string formatter;

	TestResult run() {
		import std.file;
		string original = cast(string) read(name);

		import std.process;
		auto pipes = pipeProcess(
			[formatter, "--assume-filename", name],
			Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout
		);

		pipes.stdin.write(original);
		pipes.stdin.close();

		const status = pipes.pid.wait;

		import std.array;
		const output = cast(string) pipes.stdout.byChunk(4096).join;

		return check(name, original, status, output);
	}
}

private TestResult check(string filename, string originalData,
                         int processStatus, string processOutput) {
	import std.stdio;
	if (processStatus != 0) {
		stderr.writefln("%s: sdfmt expected to format, did not (%d).", filename,
		                processStatus);
		return TestResult(filename, false, true);
	}

	import std.encoding;
	auto bom = getBOM(cast(const(ubyte)[]) originalData).schema;
	if (bom == BOM.none && processOutput != originalData) {
		stderr.writefln("%s: sdfmt did not format as expected.", filename);
		return TestResult(filename, false, true);
	}

	return TestResult(filename, true, true);
}

struct CheckFormat(TaskType) {
	enum Name = "Formatter Test Runner";
	enum XtraDoc = "specific test";

	import std.meta;
	alias ExtraArgs =
		AliasSeq!("formatter", "The formatter executable to use.", string);

	string formatter;

	void processArgs(string formatter) {
		this.formatter = getAbsolutePath(formatter);
	}

	auto getTasks(string[] args) {
		if (formatter == "") {
			formatter = getAbsolutePath(SDFMT);
		}

		import std.algorithm, std.array, std.file;
		return [
			"test/compilable", "test/format", "test/invalid", "test/runner",
			"test/unit", "test/valid", "sdlib/d", "src",
		].map!(d => dirEntries(d, "*.d", SpanMode.breadth)).join()
		 .filter!(f => f.isFile()).map!(t => TaskType(t, formatter));
	}
}

int main(string[] args) {
	// 2 passes: from disk first, then (if successful) via stdin
	if (const diskStatus = runUtility(CheckFormat!Task(), args))
		return diskStatus;
	const stdinStatus = runUtility(CheckFormat!StdinTask(), args);
	return stdinStatus;
}
