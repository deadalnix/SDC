LIBSDFMT_SRC = $(wildcard src/format/*.d)

SDFMT = bin/sdfmt

LIBSDFMT = lib/libsdfmt.a

obj/format.o: $(LIBSDFMT_SRC)
	@mkdir -p lib obj
	$(DMD) -c -of"$@" $(LIBSDFMT_SRC) -makedeps="$@.deps" $(DFLAGS)

$(LIBSDFMT): obj/format.o
	ar rcs "$@" $^

$(SDFMT): obj/driver/sdfmt.o $(LIBSDFMT) $(LIBCONFIG) $(LIBSOURCE) $(LIBUTIL)
	@mkdir -p bin
	$(DMD) -of"$@" $+ $(DFLAGS) $(addprefix -Xcc=,$(LDFLAGS))

check-libfmt: $(LIBSDFMT_SRC)
	$(DMD) $(DFLAGS) -unittest -i -main -run $^

check-sdfmt: $(SDFMT)
	test/runner/checkformat.d

check: check-libfmt check-sdfmt
.PHONY: check-libfmt check-sdfmt
