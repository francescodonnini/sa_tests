# STAGE=1  nessun pass (solo pivot + runtime)
# STAGE=2  solo pass IR (mascheramento store)
# STAGE=3  pipeline completa (pass IR + pass x86)
STAGE       ?= 3
PROG        ?= fib
REPOS       ?= $(HOME)
LLVM_CONFIG ?= llvm-config

LLVM_BIN  := $(shell $(LLVM_CONFIG) --bindir)
CC        := $(LLVM_BIN)/clang
LLC       := $(LLVM_BIN)/llc

RUNTIME   := $(REPOS)/runtime/build
IR_PASS   := $(REPOS)/shadow_stack/build/ShadowStack.so
X86_PASS  := $(REPOS)/shadow_stack_x86/build/libX86ShadowStack.so

OPT       := -O1
CFLAGS    := $(OPT) -fPIE
LLCFLAGS  := $(OPT) -relocation-model=pic
LDFLAGS   := -Wl,-e,relocate_stack -L$(RUNTIME) -Wl,-rpath,$(RUNTIME)
LDLIBS    := -lruntime -lpthread

ifneq ($(STAGE),1)
CFLAGS    += -fpass-plugin=$(IR_PASS)
endif

all: $(PROG)

$(PROG): $(PROG).o $(RUNTIME)/stckcpy.o
	$(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@

ifeq ($(STAGE),3)
$(PROG).ll: $(PROG).c
	$(CC) $(CFLAGS) -S -emit-llvm $< -o $@

$(PROG).mir: $(PROG).ll
	$(LLC) $(LLCFLAGS) -stop-after=prologepilog $< -o $@

$(PROG).ss.mir: $(PROG).mir
	$(LLC) -load $(X86_PASS) -run-pass=x86-shadow-stack $< -o $@

$(PROG).o: $(PROG).ss.mir
	$(LLC) $(LLCFLAGS) -start-after=prologepilog -filetype=obj $< -o $@
else
$(PROG).o: $(PROG).c
	$(CC) $(CFLAGS) -c $< -o $@
endif

run: $(PROG)
	./$(PROG); echo "exit code: $$?"

disasm: $(PROG)
	objdump -d --no-show-raw-insn $(PROG) | less

clean:
	rm -f $(PROG) $(PROG).o $(PROG).ll $(PROG).mir $(PROG).ss.mir

.SECONDARY:

.PHONY: all run disasm clean