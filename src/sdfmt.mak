LIBSDFMT_SRC = $(wildcard src/format/*.d)

SDFMT = bin/sdfmt

LIBSDFMT = lib/libsdfmt.a

obj/format.o: $(LIBSDFMT_SRC)
	@mkdir -p lib obj
	$(DMD) -c -ofobj/format.o -makedeps="$@.deps" $(LIBSDFMT_SRC) $(DFLAGS)

$(LIBSDFMT): obj/format.o
	ar rcs $(LIBSDFMT) obj/format.o

$(SDFMT): obj/driver/sdfmt.o $(LIBSDFMT) $(LIBCONFIG) $(LIBSOURCE)
	@mkdir -p bin
	$(DMD) -of"$@" $^ $(DFLAGS) $(addprefix -Xcc=,$(LDFLAGS))

check-libfmt: $(LIBSDFMT_SRC)
	$(RDMD) $(DFLAGS) -unittest -i $(addprefix --extra-file=, $^) --eval="/* Do nothing */"

check-sdfmt: $(SDFMT)
	test/runner/checkformat.d

check: check-libfmt check-sdfmt
.PHONY: check-libfmt check-sdfmt
