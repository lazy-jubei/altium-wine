/* Isolate x87 compare/pop corruption during asynchronous signals under Rosetta.
 * clang -arch x86_64 -O2 rosetta-x87-signal.c -o /tmp/x87-signal
 * /tmp/x87-signal                 compare/pop with a SIGUSR1 storm
 * /tmp/x87-signal --split         separate compare and pop
 * /tmp/x87-signal --no-signals    comparison without interruption
 * Runs for 12 seconds; exit 3 means the balanced loop corrupted x87 state.
 * No Wine, Altium, process attachment or saved files are involved. */
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static pthread_t target;
static atomic_int done, signals;
static int storm = 1;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Signal counter must be lock-free");

static void handle(int signal, siginfo_t *info, void *context)
{
    atomic_fetch_add_explicit(&signals, 1, memory_order_relaxed);
}

static void *sender(void *unused)
{
    while (!atomic_load_explicit(&done, memory_order_relaxed))
    {
        if (storm) pthread_kill(target, SIGUSR1);
        usleep(1000);
    }
    return NULL;
}

static uint64_t now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

int main(int argc, char **argv)
{
    int split = 0, failure = 0;
    for (int i = 1; i < argc; ++i)
    {
        if (!strcmp(argv[i], "--split")) split = 1;
        else if (!strcmp(argv[i], "--no-signals")) storm = 0;
        else return 64;
    }
    struct sigaction action = {.sa_sigaction = handle, .sa_flags = SA_SIGINFO};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGUSR1, &action, NULL)) return 1;
    target = pthread_self();
    pthread_t thread;
    if (pthread_create(&thread, NULL, sender, NULL)) return 1;
    __attribute__((aligned(16))) unsigned char state[512];
    __asm__ volatile("fninit");
    uint64_t end = now() + 12000000000ULL, calls = 0;
    while (now() < end)
    {
        for (int i = 0; i < 1000; ++i)
        {
            if (split)
                __asm__ volatile("fld1; fcom %%st(0); fstp %%st(0); fwait; fnstsw %%ax; sahf"
                                 ::: "st", "ax", "cc");
            else
                __asm__ volatile("fld1; fcomp %%st(0); fwait; fnstsw %%ax; sahf"
                                 ::: "st", "ax", "cc");
            ++calls;
        }
        __asm__ volatile("fxsave (%0)" :: "r"(state) : "memory");
        if (state[4] || (*(uint16_t *)(state + 2) & 0x3800))
        {
            failure = 1;
            break;
        }
    }
    atomic_store_explicit(&done, 1, memory_order_relaxed);
    pthread_join(thread, NULL);
    printf("%s calls=%llu signals=%d cw=%04x sw=%04x tag=%02x\n", failure ? "FAIL" : "PASS",
           (unsigned long long)calls, atomic_load(&signals), *(uint16_t *)state,
           *(uint16_t *)(state + 2), state[4]);
    return failure ? 3 : 0;
}
