// Prova dinamica: una funzione sovrascrive il proprio indirizzo di ritorno.
//   protetto     -> l'epilogo lo ripristina dallo shadow e si torna nel main
//   non protetto -> si "ritorna" in hijacked()
// Compilare con -fno-omit-frame-pointer: l'indirizzo di ritorno sta a rbp + 8.
#include <stdio.h>
#include <unistd.h>

static void hijacked(void)
{
        puts("NON protetto: l'indirizzo di ritorno sovrascritto è stato usato");
        _exit(1);
}

static volatile int sink;

// victim deve contenere una call vera (non leaf), altrimenti il pass x86 non la
// strumenta; la scrittura su sink dopo puts impedisce che diventi una tail call (jmp).
static __attribute__((noinline)) void victim(void)
{
        void *volatile *ret = (void *volatile *)__builtin_frame_address(0) + 1;

        *ret = (void *)hijacked;   // come farebbe un buffer overflow
        puts("victim: indirizzo di ritorno sovrascritto");
        sink = 1;
}

int main(void)
{
        setvbuf(stdout, NULL, _IONBF, 0);   /* senza buffer: _exit non svuota stdout */
        victim();
        puts("protetto: victim è tornata nel main");
        return 0;
}