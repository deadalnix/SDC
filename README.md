SDC - The Snazzy D Compiler
===========================
This is the home of a [D](http://dlang.org/) compiler.
SDC is at the moment, particularly stupid; it is a work in progress. Feel free to poke around, but don't expect it to compile your code.

This compiler is based on [libd](https://github.com/snazzy-d/SDC/tree/master/src/d) for D code analysis. It uses [LLVM](http://llvm.org/) and [libd-llvm](https://github.com/snazzy-d/SDC/tree/master/src/d/llvm) for codegen and JIT CTFE. It uses [libsdrt](https://github.com/snazzy-d/SDC/tree/master/sdlib) to support various runtime facilities required by programs compiled by SDC.

The code is released under the MIT license (see the LICENCE file for more details).
Contact me at deadalnix@gmail.com

SDC requires DMD release `2.094` to compile.

Goals
=====
Right now, SDC is a work in progress and unusable for any production work. Its intent is to provide a D compiler as a library (libd) in order to improve the overall D toolchain by enabling the possibility of developing new tools.

SDC now supports many very advanced features (static ifs, string mixins, CTFE) of D, but not many basic ones. This is a development choice to allow the architecturing of the compiler around the hardest features of the language. As a consequence, SDC has a solid base to build upon.

What Can It Compile?
====================
See the tests directory for a sample of what is/should-be working.
phobos/object.d contains the current (temporary) object.d file for SDC.

Roadmap
=======
This just me thinking outloud about what features I want, when.

0.1
---
* Compile D style (writeln) hello world.

0.2
---
* Compile itself, which imply compile most of D.

1.0
---
* Propose a stable API for 3rd party.

2.0
---
* extern (C++)


Compiling SDC on Linux
=======
You'll need `make` and the latest DMD installed.
Install LLVM 3.9.

Run `make`.

Then you can compile `runner.d` with `dmd` and run it to run the test suites. There should be no regressions.
SDC contains a lot of hardcoded PATH right now, so it's hard to integrate properly with the system. It expects object.d to be in ../libs/object.d

SDC requires LLVM 3.9 . If the default llvm-config on your system is an older version, you can specify a newer version via `LLVM_CONFIG`. For instance, on a debian system, you want to use `make LLVM_CONFIG=llvm-config-3.9` .

For detailed installing instructions please refer the [Dockerfile](https://github.com/lindt/docker-sdc/blob/master/Dockerfile).

Compiling SDC on Mac OS X
=======
You'll need `make` and the latest DMD installed. You'll also need llvm38 if you don't already have it. One way to install llvm that's been tested is to use [Homebrew](http://brew.sh/), a package manager for OS X. After installing it by following instructions from the web page, run the command  `brew install llvm39`, followed by `make LLVM_CONFIG=llvm-config-3.9` . If you are using [MacPorts](http://www.macports.org) instead, you can run `sudo port install llvm-3.9`, followed by `make LLVM_CONFIG=llvm-config-mp-3.9` .
You'll also need a recent version of `nasm`; if `nasm` does not recognise the `macho64` output format, try updating `nasm`.

Usage as Docker Image
=======
If you do not want to compile SDC on your own, you can use the [automatic generated Docker Image](https://hub.docker.com/r/dlanguage/sdc/).
Assume you have a `test.d` file in your local directory, you can compile it using the Docker image with this command:
`docker run -ti -v $(pwd):/src dlanguage/sdc test.d`

Building SDC as a Nix package
=======
On Linux, you can also use the [Nix package manager](https://nixos.org) to automatically fetch dependencies and build SDC for you.
You may need to use the unstable nix channel, to have a new enough `dmd` to build SDC. Clone or download this repository.

To build the executable, run `nix-build -E "(import <nixpkgs> {}).callPackage ./. {}"` or
`nix-build -E "(import <nixpkgs> {}).callPackage ./. {dflags=\"-O -release\";}"` from the project root directory.

### Setup
Extract the LLVM DLL binary archive to the SDC repository, then build with `make -f Makefile.windows`.
When running SDC, make sure `gcc`, `llc` and `opt` are available in your PATH.

To run the tests, execute `dmd runner.d` to build the test-runner application found in `tests/`, then run it with `runner`.
