# STAGE=0  baseline: no protection
# STAGE=1  pivot+runtime
# STAGE=2  pivot+runtime+IR
# STAGE=3  pivot+runtime+IR+x86
-include local.mk

STAGE       ?= 3
REPOS       ?= $(HOME)
LLVM_CONFIG ?= llvm-config
SQLITE_VER  ?= 3500400
SQLITE_YEAR ?= 2025
SQLITE_TAG  ?= version-3.50.4

LLVM_BIN  := $(shell $(LLVM_CONFIG) --bindir)
CC        := $(LLVM_BIN)/clang
LLC       := $(LLVM_BIN)/llc

RUNTIME   := $(REPOS)/runtime/build
IR_PASS   := $(REPOS)/shadow_stack/build/ShadowStack.so
X86_PASS  := $(REPOS)/shadow_stack_x86/build/libX86ShadowStack.so
X86_RUN   ?= $(LLC) -load $(X86_PASS) -run-pass=x86-shadow-stack

SRC_DIR   := src
BUILD     := build/stage$(STAGE)
BIN       := $(BUILD)/speedtest1
SOURCES   := sqlite3.c speedtest1.c
OBJS      := $(SOURCES:%.c=$(BUILD)/%.o)

OPT       ?= -O2
CFLAGS    := $(OPT) -fPIE -I$(SRC_DIR) -DSQLITE_OMIT_LOAD_EXTENSION
LLCFLAGS  := $(OPT) -relocation-model=pic
LDLIBS    := -lm -lpthread

ifeq ($(STAGE),0)
ENTRY_OBJ :=
LDFLAGS   :=
else
ENTRY_OBJ ?= $(RUNTIME)/stckcpy.o
LDFLAGS   := -Wl,-e,relocate_stack -L$(RUNTIME) -Wl,-rpath,$(RUNTIME)
LDLIBS    := -lruntime $(LDLIBS)
endif

ifneq ($(filter 2 3,$(STAGE)),)
CFLAGS    += -fpass-plugin=$(IR_PASS)
endif

# speedtest1
SIZE      ?= 100
BENCH_ARGS ?= --size $(SIZE) --memdb

all: $(BIN)

$(BIN): $(OBJS) $(ENTRY_OBJ)
	$(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@

ifeq ($(STAGE),3)
$(BUILD)/%.ll: $(SRC_DIR)/%.c | $(BUILD)
	$(CC) $(CFLAGS) -S -emit-llvm $< -o $@

# fixmir.pl (dopo ogni llc che scrive MIR) aggira un bug del parser MIR: le costanti '<N x T> zeroinitializer'
# del constant pool vengono scritte ma non rilette ("expected a constant value")
$(BUILD)/%.mir: $(BUILD)/%.ll
	$(LLC) $(LLCFLAGS) -stop-after=prologepilog $< -o $@.tmp
	perl -p fixmir.pl $@.tmp > $@
	rm $@.tmp

$(BUILD)/%.ss.mir: $(BUILD)/%.mir
	$(X86_RUN) $< -o $@.tmp
	perl -p fixmir.pl $@.tmp > $@
	rm $@.tmp

$(BUILD)/%.o: $(BUILD)/%.ss.mir
	$(LLC) $(LLCFLAGS) -start-after=prologepilog -filetype=obj $< -o $@
else
$(BUILD)/%.o: $(SRC_DIR)/%.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@
endif

$(BUILD):
	mkdir -p $@

fetch:
	mkdir -p $(SRC_DIR)
	curl -fL -o sqlite.zip \
		https://www.sqlite.org/$(SQLITE_YEAR)/sqlite-amalgamation-$(SQLITE_VER).zip
	unzip -j -o sqlite.zip '*/sqlite3.c' '*/sqlite3.h' -d $(SRC_DIR)
	rm sqlite.zip
	curl -fL -o $(SRC_DIR)/speedtest1.c \
		https://raw.githubusercontent.com/sqlite/sqlite/$(SQLITE_TAG)/test/speedtest1.c

run: $(BIN)
	$(BIN) $(BENCH_ARGS); echo "exit code: $$?"

bench:
	mkdir -p results
	for s in 0 1 2 3; do \
		$(MAKE) --no-print-directory STAGE=$$s all || exit 1; \
		echo "== stage $$s"; \
		build/stage$$s/speedtest1 $(BENCH_ARGS) > results/stage$$s.txt || exit 1; \
		tail -1 results/stage$$s.txt; \
	done

clean:
	rm -rf build

.SECONDARY:

.PHONY: all fetch run bench clean