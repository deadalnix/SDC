module driver.sdfmt;

int main(string[] args) {
	bool dbg = false;
	bool inPlace = false;
	string assumeFilename;

	import std.getopt;
	try {
		auto help_info = getopt(
			// sdfmt off
			args, std.getopt.config.caseSensitive,
			"debug", "Enable debug",          &dbg,
			"i",     "Format files in place", &inPlace,
			"assume-filename", `Fake filename to use for stdin input, used for config file lookup and -i`, &assumeFilename,
			// sdfmt on
		);

		if (help_info.helpWanted) {
			import std.stdio;
			writeln("The Snazzy D Compiler - Code Formatter");
			writeln("Usage: sdfmt [options] [file.d ...]");
			writeln("Options:");

			foreach (option; help_info.options) {
				writefln(
					"  %-16s %s",
					// bug : optShort is empty if there is no long version
					option.optShort.length
						? option.optShort
						: (option.optLong.length == 3)
							? option.optLong[1 .. $]
							: option.optLong,
					option.help
				);
			}

			return 0;
		}
	} catch (GetOptException ex) {
		import std.stdio;
		writefln("%s", ex.msg);
		writeln("Please use -h to get a list of valid options.");
		return 1;
	}

	import source.context;
	auto context = new Context();

	void processFile(string filename, bool readFromStdin = false) {
		import format.config;
		Config conf;

		import config.build;
		conf.buildLocalConfig("sdfmt", context, filename);

		import source.location;
		Position base;
		if (readFromStdin) {
			import std.array, std.stdio;
			const stdinData = stdin.byChunk(4096).join;

			import source.util.utf8;
			const sanitizedData = convertToUTF8(stdinData);

			base = context
				.registerFile(Location.init, filename, "", sanitizedData);
		} else {
			base = context.registerFile(Location.init, filename, "");
		}

		import format.parser;
		auto chunks = Parser(base, context).parse();

		if (dbg) {
			import std.stdio;
			writeln(chunks);
		}

		import format.writer;
		auto o = chunks.write(conf);

		if (inPlace) {
			// Remove the null terminator.
			auto s = base.getFullPosition(context).getSource();
			if (o != s.getContent()) {
				import std.file;
				filename.write(o);
			}
		} else {
			import std.stdio;
			write(o);
		}
	}

	const files = args[1 .. $];
	if (files.length == 0) {
		// read from stdin
		const fakeFilename = assumeFilename.length ? assumeFilename : "stdin";
		processFile(fakeFilename, true);
	} else {
		foreach (filename; files)
			processFile(filename);
	}

	return 0;
}
