# SDC Architecture

# Purpose

The purpose of this document is to provide a high level overview of the constructs which make up the SDC compiler.  Additionally, we will discuss how data flows through, and is transformed by the compiler.

# Data Flow within the compiler

In order to understand the various sections of the compiler, and their functioning, it is best to thing of them in terms of a pipeline of data transforms.  With that said, it is imported to note that within SDC some of these stages can occur in parallel and out of sequqnce when processing multiple files.

When the compiler first opens a file, it produces a stream of characters.  Attempting to write code which takes high-level character streams and directly produce machine-code results in extremely hairy code for all but the simplest languages (e.g. Assembly).  Therefore, the character stream is first transformed into a Token stream.  The token stream generally omits whitespace, comments, and other information which is not useful to ultimately producing an object file.

These sorts of data transforms continue in several stages.  They are are follows, with more details given in further sections:

(Character Streams) -> Lexer -> (Token Stream) -> Parser -> (AST) -> Semantic Pass -> (SDIR) -> Code Gen -> (LLVM IR) -> LLVM -> (Machine Code)

# Constructs

## Lexer 
(entrypoint: libd/src/d/lexer.d:lex)

The general purpose of a lexer is to normalize whitespaces and character sequqnces for easy consumption by a parser.  The SDC lexer is made up of some maps from strings of characters, to the function which should handle their lexing.  These are contained within `getOperatorsMap`, `getKeywordsMap`, and finally `getLexerMap`.  The `getOperatorsMap`, and `getKeywordsMap` functions map directly to tokens, but are transformed into function calls within `getLexerMap`.

The map produced by `getLexerMap` is untlimately used to generate a giant nested switch statement by `lexerMixin` and is thus relatively fast.

Although the lexer is the first stage of transforming character streams, this is actually invoked by the semantic pass from within `libd/src/d/semantic/dmodule.d:parse` where the modules are added to the SemanticPass by `import` statements in code, and by the SDC command line handler in `sdc/src/sdc/sdc.d`.  

This inversion of control is necessary because D does not use a pre-processor.  This means, that additionally compilation units can be added via `import` statements unlike in C where these would have already been handled by the pre-processor.  While this makes for a more complex compiler, it allows D to compile much faster due to not needing to re-process the same headers repeatedly.

## Parser
(entrypoint: libd/src/d/parser/dmodule.d:parseModule)
The parser is invoked shortly after the lexer within `libd/src/d/semantic/dmodule.d:parse`.  The parser takes the token stream, and produces a [Abstract Syntax Tree](https://en.wikipedia.org/wiki/Abstract_syntax_tree) (AST) which is used by the semantic pass.  The transformation from a stream of tokens, to a tree, allows for processing of algabraic expressions, operator precendence handling, scope handling, and various other procedures which would be difficult on a list of tokens.

The AST is made up of various Statements and Expressions.  A statement is anything can make up a line of code, whereas an expression is a type of statement which has associated type information.

Types information in D is made of qualfiers, type info, and procides a way to tell if one expression is legally assignable to an identifier.  (See the D specification for more information)

#### Locations + Errors
	+ Another nice feature is that SDC threads location data throughout the ast and ir so that the compiler can generate errors telling the user precisely where the mistake was made!

## Semantic Pass (incl. Scheduler)
	+ Operates on the Ast provided by the parser to generate SDIR.  Is started at the root each module being compiled.
	+ Scheduler provides arbitrary look-ahead without needing to use continuation-passing style through the use of fibers (effectively coroutines)
	+ Allows for type inference.
	+ May reduce some higher level Ast concepts into easier concepts to express in the IR.
	+ *** Need to cover visitors, and require, scheduler, etc.
	+ Cover how visitors work -- Equivalent to functional programming concept of parameter specialization
	+ Operates in multiple passes over the AST/IR (Ew that it modifies the IR/AST?)

### Passes

+ Need to determine what passes are made.  

### SDIR 

## Code Generation
	+ Operates on the IR produced by the semantic pass

## Runtime (libsdrt)
	+ Some of the features implemented in the D programming languages are best implemented through a library.  This library is called the runtime, and the compiler emits references to symbols which are expected to be resolved by the linker.  The runtime library makes up the allocator, gc, and various other low level language features.
