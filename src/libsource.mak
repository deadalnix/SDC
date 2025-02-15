LIBSOURCE_SRC = $(wildcard src/source/*.d) $(wildcard src/source/swar/*.d) $(wildcard src/source/util/*.d)

LIBSOURCE = lib/libsource.a

obj/source.o: $(LIBSOURCE_SRC)
	@mkdir -p lib obj
	$(DMD) -c -of"$@" $(LIBSOURCE_SRC) -makedeps="$@.deps" $(DFLAGS)

$(LIBSOURCE): obj/source.o
	ar rcs "$@" $^

check-source: $(LIBSOURCE_SRC)
	$(DMD) $(DFLAGS) -unittest -i -main -run $^

check: check-source
.PHONY: check-source
