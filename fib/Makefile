# STAGE=1  pivot+runtime
# STAGE=2  IR
# STAGE=3  IR+x86
STAGE       ?= 3
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

all: fib

fib: fib.o $(RUNTIME)/stckcpy.o
	$(CC) $^ $(LDFLAGS) $(LDLIBS) -o $@

ifeq ($(STAGE),3)
fib.ll: fib.c
	$(CC) $(CFLAGS) -S -emit-llvm $< -o $@

fib.mir: fib.ll
	$(LLC) $(LLCFLAGS) -stop-after=prologepilog $< -o $@

fib.ss.mir: fib.mir
	$(LLC) -load $(X86_PASS) -run-pass=x86-shadow-stack $< -o $@

fib.o: fib.ss.mir
	$(LLC) $(LLCFLAGS) -start-after=prologepilog -filetype=obj $< -o $@
else
fib.o: fib.c
	$(CC) $(CFLAGS) -c $< -o $@
endif

run: fib
	./fib; echo "exit code: $$?"

disasm: fib
	objdump -d --no-show-raw-insn fib | less

clean:
	rm -f fib fib.o fib.ll fib.mir fib.ss.mir

.PHONY: all run disasm clean