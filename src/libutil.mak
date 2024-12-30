LIBUTIL_SRC = $(wildcard src/util/*.d)

LIBUTIL = lib/libutil.a

obj/util.o: $(LIBUTIL_SRC)
	@mkdir -p obj
	$(DMD) -c -of"$@" $(LIBUTIL_SRC) -makedeps="$@.deps" $(DFLAGS)

$(LIBUTIL): obj/util.o
	ar rcs "$@" $^

check-util: $(LIBUTIL_SRC)
	$(DMD) $(DFLAGS) -unittest -i -main -run $^

check: check-util
.PHONY: check-util
