# Compila i programmi di test con la pipeline dello shadow stack.
# Ogni .c nella cartella diventa un eseguibile a sé.
#
# STAGE=0  baseline: nessuna protezione
# STAGE=1  pivot + runtime (nessun pass)
# STAGE=2  pivot + runtime + pass IR (mascheramento store)
# STAGE=3  pivot + runtime + pass x86 (shadow stack)
# STAGE=4  pipeline completa: pass IR + pass x86 (default)
#
# Esempi:
#   make                 compila tutti i programmi (stage 4)
#   make fork_test       solo fork_test
#   make STAGE=1 run RUN=fork_test
#   make clean
#
# I percorsi che cambiano da macchina a macchina vanno in local.mk:
#   REPOS       := /home/utente
#   LLVM_CONFIG := /home/utente/llvm-project/build/bin/llvm-config
-include local.mk

STAGE       ?= 4
REPOS       ?= $(HOME)
LLVM_CONFIG ?= llvm-config

LLVM_BIN  := $(shell $(LLVM_CONFIG) --bindir)
ifeq ($(LLVM_BIN),)
$(error $(LLVM_CONFIG) non trovato: imposta LLVM_CONFIG in local.mk)
endif
CC        := $(LLVM_BIN)/clang
LLC       := $(LLVM_BIN)/llc

RUNTIME   := $(REPOS)/runtime/build
IR_PASS   := $(REPOS)/shadow_stack/build/ShadowStack.so
X86_PASS  := $(REPOS)/shadow_stack_x86/build/libX86ShadowStack.so
X86_RUN   ?= $(LLC) -load $(X86_PASS) -run-pass=x86-shadow-stack

# Un eseguibile per ogni .c nella cartella
PROGS     := $(basename $(wildcard *.c))
BUILD     := build/stage$(STAGE)
BINS      := $(addprefix $(BUILD)/,$(PROGS))

OPT       ?= -O1
CFLAGS    := $(OPT) -fPIE -Wall -Wextra
LLCFLAGS  := $(OPT) -relocation-model=pic
LDLIBS    := -lpthread

ifeq ($(STAGE),0)
ENTRY_OBJ :=
LDFLAGS   :=
else
ENTRY_OBJ := $(RUNTIME)/stckcpy.o
LDFLAGS   := -Wl,-e,relocate_stack -L$(RUNTIME) -Wl,-rpath,$(RUNTIME)
LDLIBS    := -lruntime $(LDLIBS)
endif

# pass IR negli stage 2 e 4
ifneq ($(filter 2 4,$(STAGE)),)
CFLAGS    += -fpass-plugin=$(IR_PASS)
endif

all: $(BINS)

# Nome breve: `make fork_test` costruisce lo stage corrente di fork_test
.PHONY: $(PROGS)
$(PROGS): %: $(BUILD)/%

$(BUILD)/%: $(BUILD)/%.o $(ENTRY_OBJ)
	$(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@

# giro MIR col pass x86 negli stage 3 e 4
ifneq ($(filter 3 4,$(STAGE)),)
$(BUILD)/%.ll: %.c | $(BUILD)
	$(CC) $(CFLAGS) -S -emit-llvm $< -o $@

$(BUILD)/%.mir: $(BUILD)/%.ll
	$(LLC) $(LLCFLAGS) -stop-after=prologepilog $< -o $@

$(BUILD)/%.ss.mir: $(BUILD)/%.mir
	$(X86_RUN) $< -o $@

$(BUILD)/%.o: $(BUILD)/%.ss.mir
	$(LLC) $(LLCFLAGS) -start-after=prologepilog -filetype=obj $< -o $@
else
$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@
endif

$(BUILD):
	mkdir -p $@

# Esegue un programma: make run RUN=fork_test
RUN ?= $(firstword $(PROGS))
run: $(BUILD)/$(RUN)
	$(BUILD)/$(RUN); echo "exit code: $$?"

clean:
	rm -rf build

.SECONDARY:
.PHONY: all run clean