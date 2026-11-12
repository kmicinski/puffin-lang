# Puffin runtime build.
#
# Produces libpuffin.a: a universal (arm64 + x86_64) static archive
# containing the runtime core, every stdlib module, and the vendored
# Boehm GC (vendor/gc, built universal). Linking a Puffin program is
# then exactly:
#
#   clang [-target <triple>] output.o libpuffin.a -o output
#
# which works for both backends on both kinds of mac (x86-64 code
# runs under Rosetta on Apple Silicon).

CC      := clang
CFLAGS  := -Wall -Wextra -O2 -Ivendor/gc/include
ARCHES  := arm64 x86_64

# Linux (no lipo/libtool, and the vendored libgc.a is a Mach-O fat
# archive): build for the host architecture against the system Boehm
# GC (Debian/Ubuntu: libgc-dev) and fold its static libgc.a into
# libpuffin.a, so `clang output.o libpuffin.a` stays the whole link
# and the VM's Makefile needs no change. SYSTEM_LIBGC overrides where
# that archive is found.
UNAME := $(shell uname -s)
ifeq ($(UNAME),Linux)
LINUX_CFLAGS := -Wall -Wextra -O2 -D_GNU_SOURCE
SYSTEM_LIBGC ?= $(firstword $(wildcard /usr/lib/*-linux-gnu/libgc.a /usr/lib64/libgc.a /usr/lib/libgc.a))
endif

CORE_SRCS := core.c
LIB_SRCS  := lib/pairs.c lib/vectors.c lib/strings.c lib/table.c lib/hashes.c lib/sets.c lib/hamt.c lib/adt.c lib/cast.c lib/arith.c lib/predicates.c lib/io.c lib/foreign.c lib/stdlib_init.c
SRCS      := $(CORE_SRCS) $(LIB_SRCS)

BUILD := build

all: libpuffin.a

# Per-arch objects and thin archives (the vendored libgc.a is fat;
# slice out the matching architecture before merging)
define ARCH_RULES
$(BUILD)/$(1)/%.o: %.c puffin.h lib/table.h
	@mkdir -p $$(dir $$@)
	$(CC) -arch $(1) $(CFLAGS) -c $$< -o $$@

$(BUILD)/libgc-$(1).a: vendor/gc/lib/libgc.a
	@mkdir -p $(BUILD)
	lipo vendor/gc/lib/libgc.a -thin $(1) -output $$@

$(BUILD)/libpuffin-$(1).a: $(patsubst %.c,$(BUILD)/$(1)/%.o,$(SRCS)) $(BUILD)/libgc-$(1).a
	libtool -static -o $$@ $$^
endef

$(foreach arch,$(ARCHES),$(eval $(call ARCH_RULES,$(arch))))

ifeq ($(UNAME),Linux)
$(BUILD)/host/%.o: %.c puffin.h lib/table.h
	@mkdir -p $(dir $@)
	$(CC) $(LINUX_CFLAGS) -c $< -o $@

libpuffin.a: $(patsubst %.c,$(BUILD)/host/%.o,$(SRCS))
	@test -n "$(SYSTEM_LIBGC)" || { echo "no system libgc.a (install libgc-dev, or set SYSTEM_LIBGC)" >&2; exit 1; }
	rm -f $@
	printf 'create $@\naddlib $(SYSTEM_LIBGC)\n$(foreach o,$^,addmod $(o)\n)save\nend\n' | ar -M
else
libpuffin.a: $(foreach arch,$(ARCHES),$(BUILD)/libpuffin-$(arch).a)
	lipo -create $^ -output $@
endif

clean:
	rm -rf $(BUILD) libpuffin.a

.PHONY: all clean
