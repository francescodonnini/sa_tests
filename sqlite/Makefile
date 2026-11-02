# Benchmark sqlite (speedtest1) con la pipeline dello shadow stack.
#
# STAGE=0  baseline: nessuna protezione, entry point e runtime normali
# STAGE=1  solo pivot + runtime (nessun pass)
# STAGE=2  pivot + runtime + pass IR (mascheramento store)
# STAGE=3  pivot + runtime + pass x86 (shadow stack, senza mascheramento)
# STAGE=4  pipeline completa: pass IR + pass x86 (default)
#
# Tutti gli stage si compilano allo stesso modo, con un solo clang -c: cambiano
# solo le opzioni dei pass (come nella build di Postgres). Il clang deve essere
# quello con il pass x86 integrato (-mllvm -x86-shadow-stack-pass).
#
# I percorsi che cambiano da macchina a macchina vanno in local.mk (non versionato):
#   REPOS       := /home/utente
#   LLVM_CONFIG := /home/utente/llvm-project/build/bin/llvm-config
#
# Ogni stage compila in build/stageN/, quindi non serve make clean
# quando si cambia STAGE e i binari restano tutti disponibili per il confronto.
-include local.mk

STAGE       ?= 4
REPOS       ?= $(HOME)
LLVM_CONFIG ?= llvm-config
SQLITE_VER  ?= 3500400
SQLITE_YEAR ?= 2025
SQLITE_TAG  ?= version-3.50.4

LLVM_BIN  := $(shell $(LLVM_CONFIG) --bindir)
ifeq ($(LLVM_BIN),)
$(error $(LLVM_CONFIG) non trovato: imposta LLVM_CONFIG in local.mk)
endif
CC        := $(LLVM_BIN)/clang

RUNTIME   := $(REPOS)/runtime/build
IR_PASS   := $(REPOS)/shadow_stack/build/ShadowStack.so

SRC_DIR   := src
BUILD     := build/stage$(STAGE)
BIN       := $(BUILD)/speedtest1
SOURCES   := sqlite3.c speedtest1.c
OBJS      := $(SOURCES:%.c=$(BUILD)/%.o)

OPT       ?= -O2
CFLAGS    := $(OPT) -fPIE -I$(SRC_DIR) -DSQLITE_OMIT_LOAD_EXTENSION \
             -DSQLITE_ENABLE_RTREE
LDLIBS    := -lm -lpthread

ifeq ($(STAGE),0)
ENTRY_OBJ :=
LDFLAGS   :=
else
ENTRY_OBJ ?= $(RUNTIME)/stckcpy.o
LDFLAGS   := -Wl,-e,relocate_stack -L$(RUNTIME) -Wl,-rpath,$(RUNTIME)
LDLIBS    := -lruntime $(LDLIBS)
endif

# pass IR negli stage 2 e 4, pass x86 negli stage 3 e 4
ifneq ($(filter 2 4,$(STAGE)),)
CFLAGS    += -fpass-plugin=$(IR_PASS)
CFLAGS    += -fpass-plugin=$(IR_PASS) $(MASK_FLAGS)
endif
ifneq ($(filter 3 4,$(STAGE)),)
CFLAGS    += -mllvm -x86-shadow-stack-pass
endif

# Parametri del benchmark: SIZE scala il carico (100 = default di speedtest1)
SIZE      ?= 100
BENCH_ARGS ?= --size $(SIZE) --memdb

all: $(BIN)

# Dopo il link controlla che il binario sia davvero quello dello stage: il
# preambolo del pass x86 legge __ss_shadow_offset, relocate_stack ne ha pochi.
$(BIN): $(OBJS) $(ENTRY_OBJ)
        $(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@
        @n=$$(objdump -d $@ | grep -c '__ss_shadow_offset' || true); \
        case $(STAGE) in \
                3|4) ok=$$([ $$n -ge 100 ] && echo y) ;; \
                1|2) ok=$$([ $$n -lt 100 ] && echo y) ;; \
                *)   ok=$$([ $$n -eq 0 ] && echo y) ;; \
        esac; \
        echo "stage $(STAGE): $$n riferimenti a __ss_shadow_offset"; \
        [ "$$ok" = y ] || { echo "stage $(STAGE): binario non strumentato come previsto"; rm -f $@; exit 1; }

# Gli oggetti dipendono anche dal Makefile: se cambiano le opzioni, si ricompila
$(BUILD)/%.o: $(SRC_DIR)/%.c Makefile | $(BUILD)
        $(CC) $(CFLAGS) -c $< -o $@

$(BUILD):
        mkdir -p $@

# Scarica l'amalgamation e lo speedtest1.c della stessa versione
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

# Esegue tutti gli stage e salva l'output in results/
STAGES    ?= 0 1 2 3 4
bench:
        mkdir -p results
        for s in $(STAGES); do \
                $(MAKE) --no-print-directory STAGE=$$s all || exit 1; \
                echo "== stage $$s"; \
                build/stage$$s/speedtest1 $(BENCH_ARGS) > results/stage$$s.txt || exit 1; \
                tail -1 results/stage$$s.txt; \
        done

clean:
        rm -rf build

.PHONY: all fetch run bench clean