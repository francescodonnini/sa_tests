#include <stdio.h>
#include <unistd.h>
#include <sys/auxv.h>

int main(void) {
        printf("AT_PAGESZ      %lu\n", getauxval(AT_PAGESZ));
        printf("AT_MINSIGSTKSZ %lu\n", getauxval(AT_MINSIGSTKSZ));
        printf("_SC_SIGSTKSZ   %ld\n", sysconf(_SC_SIGSTKSZ));
        printf("AT_RANDOM      %#lx\n", getauxval(AT_RANDOM));
}