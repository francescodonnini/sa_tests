// Test di fork() con lo shadow stack.
//
// Ogni caso verifica che il figlio possa:
//   - chiamare funzioni strumentate (nuovi frame sullo shadow copiato),
//   - tornare dai frame che esistevano PRIMA della fork (il loro indirizzo
//     di ritorno sta nello shadow del padre, copiato da sa_fork).
// Exit code: 0 = tutto ok, altrimenti il numero del primo caso fallito.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static int fib(int n)
{
	if (n < 2)
		return n;
	return fib(n - 1) + fib(n - 2);
}

// Attende il figlio e controlla che sia uscito con `expected`.
static int wait_child(pid_t pid, int expected, const char *what)
{
	int status;

	if (waitpid(pid, &status, 0) < 0) {
		perror("waitpid");
		return 0;
	}
	if (WIFSIGNALED(status)) {
		printf("  %s: figlio ucciso dal segnale %d\n", what, WTERMSIG(status));
		return 0;
	}
	if (WEXITSTATUS(status) != expected) {
		printf("  %s: exit %d, atteso %d\n", what, WEXITSTATUS(status), expected);
		return 0;
	}
	return 1;
}

static volatile int sink;

// fork annidata dentro qualche frame: il figlio deve tornare fino a qui
// passando per depth livelli creati prima della fork.
// noinline e la scrittura dopo la chiamata impediscono inlining e tail call,
// altrimenti i frame sparirebbero.
static __attribute__((noinline)) pid_t fork_deep(int depth)
{
	if (depth == 0)
		return fork();
	pid_t pid = fork_deep(depth - 1);
	sink = depth;
	return pid;
}

// Caso 1: fork semplice dal main thread.
static int test_simple(void)
{
	pid_t pid = fork();
	if (pid < 0)
		return 0;
	if (pid == 0)
		_exit(fib(10) == 55 ? 0 : 1);
	return wait_child(pid, 0, "simple");
}

// Caso 2: il figlio torna attraverso 20 frame creati prima della fork.
static int test_deep(void)
{
	pid_t pid = fork_deep(20);
	if (pid < 0)
		return 0;
	if (pid == 0)
		_exit(fib(15) == 610 ? 0 : 1);
	return wait_child(pid, 0, "deep");
}

// Caso 3: il figlio fa a sua volta una fork (nipote).
static int test_nested(void)
{
	pid_t pid = fork();
	if (pid < 0)
		return 0;
	if (pid == 0) {
		pid_t grandchild = fork();
		if (grandchild < 0)
			_exit(2);
		if (grandchild == 0)
			_exit(fib(12) == 144 ? 0 : 1);
		_exit(wait_child(grandchild, 0, "nested (nipote)") ? 0 : 1);
	}
	return wait_child(pid, 0, "nested");
}

// Caso 4: molte fork di seguito (allocazione/rilascio ripetuti nel modulo).
static int test_many(void)
{
	for (int i = 0; i < 50; i++) {
		pid_t pid = fork();
		if (pid < 0)
			return 0;
		if (pid == 0)
			_exit(fib(i % 15) == fib(i % 15) ? 0 : 1);
		if (!wait_child(pid, 0, "many"))
			return 0;
	}
	return 1;
}

// Caso 5: fork da un thread secondario (lo stack del figlio è quello del thread).
static void *fork_from_thread(void *arg)
{
	(void)arg;
	pid_t pid = fork();
	if (pid < 0)
		return (void *)0;
	if (pid == 0)
		_exit(fib(10) == 55 ? 0 : 1);
	return (void *)(long)wait_child(pid, 0, "thread");
}

static int test_thread(void)
{
	pthread_t t;
	void *ok;

	if (pthread_create(&t, NULL, fork_from_thread, NULL))
		return 0;
	if (pthread_join(t, &ok))
		return 0;
	return (long)ok;
}

int main(void)
{
	static const struct {
		const char *name;
		int (*fn)(void);
	} tests[] = {
		{ "fork semplice", test_simple },
		{ "fork dentro 20 frame", test_deep },
		{ "fork annidata", test_nested },
		{ "50 fork di seguito", test_many },
		{ "fork da un thread", test_thread },
	};

	for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
		int ok = tests[i].fn();
		printf("%d. %-24s %s\n", (int)i + 1, tests[i].name, ok ? "ok" : "FALLITO");
		fflush(stdout);
		if (!ok)
			return (int)i + 1;
	}
	return 0;
}