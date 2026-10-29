#include <pthread.h>
#include <stdio.h>

static int fib(int n)
{
	if (n < 2)
		return n;
	return fib(n - 1) + fib(n - 2);
}

static void *worker(void *arg)
{
	long n = (long)arg;
	printf("thread: fib(%ld) = %d\n", n, fib(n));
	return (void *)(long)fib(n);
}

int main(void)
{
	pthread_t t;
	void *ret;

	printf("main: fib(20) = %d\n", fib(20));
	if (pthread_create(&t, NULL, worker, (void *)15))
		return 2;
	if (pthread_join(t, &ret))
		return 3;

	return (long)ret == 610 ? 0 : 1;
}