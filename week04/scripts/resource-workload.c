#define _POSIX_C_SOURCE 200809L

/* 정책을 설정하지 않는 실습용 부하 프로그램: CPU 계산 또는 메모리 보유. */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define VERSION "1.1.0"
#define MAX_RUNTIME_SECONDS 600
#define INPUT_TIMEOUT_SECONDS 300
#define MAX_MEMORY_MIB 160
#define CHUNK_MIB 4
#define MIB ((size_t)1024 * 1024)
#define MAX_CHUNKS (MAX_MEMORY_MIB / CHUNK_MIB)

static volatile sig_atomic_t received_signal = 0;

/* 핸들러는 표시만 하고, 실제 정리는 일반 실행 흐름에서 처리한다. */
static void on_signal(int signum)
{
    received_signal = signum;
}

static double monotonic_seconds(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int install_signals(void)
{
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0 ||
        sigaction(SIGALRM, &action, NULL) != 0) {
        perror("sigaction");
        return -1;
    }
    return 0;
}

static int finished(double deadline)
{
    if (received_signal != 0)
        return 1;
    if (monotonic_seconds() >= deadline) {
        received_signal = SIGALRM;
        return 1;
    }
    return 0;
}

static int finish_status(void)
{
    if (received_signal == SIGALRM) {
        printf("Stopped: %d-second runtime limit reached.\n", MAX_RUNTIME_SECONDS);
        return 0;
    }
    if (received_signal == SIGINT) {
        puts("Stopped: Ctrl+C (SIGINT) received.");
        return 128 + SIGINT;
    }
    if (received_signal != 0) {
        printf("Stopped: signal %d received.\n", (int)received_signal);
        return 128 + (int)received_signal;
    }
    return 0;
}

static void pause_briefly(long nanoseconds, double deadline)
{
    struct timespec remaining = {0, nanoseconds};
    while (!finished(deadline) && nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR)
            break;
    }
}

/* 실제 시간 1초 이상인 구간의 반복 횟수 / 실제 경과 초를 출력한다. */
static int run_cpu(double started, double deadline)
{
    volatile uint64_t value = UINT64_C(1);
    uint64_t iterations = 0;
    double interval_started = monotonic_seconds();
    puts("elapsed_s,pid,iterations_per_second");

    while (!finished(deadline)) {
        unsigned int i;
        for (i = 0; i < 10000U && received_signal == 0; ++i) {
            value = value * UINT64_C(6364136223846793005) + UINT64_C(1);
            ++iterations;
        }
        {
            double now = monotonic_seconds();
            double elapsed = now - interval_started;
            if (elapsed >= 1.0) {
                printf("%.3f,%ld,%.0f\n", now - started, (long)getpid(), (double)iterations / elapsed);
                iterations = 0;
                interval_started = now;
            }
        }
    }
    return finish_status();
}

/* stdin을 유지한 채 Enter를 기다린다. EOF/시간 초과로 부하를 시작하지 않는다. */
static int wait_for_enter(void)
{
    double input_deadline = monotonic_seconds() + INPUT_TIMEOUT_SECONDS;
    printf("Press Enter to start (%d-second input timeout).\n", INPUT_TIMEOUT_SECONDS);
    while (received_signal == 0) {
        struct pollfd input;
        double left = input_deadline - monotonic_seconds();
        int result;
        int timeout_ms;
        if (left <= 0.0) {
            fputs("Not started: input timeout.\n", stderr);
            return 3;
        }
        timeout_ms = (int)(left * 1000.0) + 1;
        if (timeout_ms > 1000)
            timeout_ms = 1000;
        input.fd = STDIN_FILENO;
        input.events = POLLIN;
        input.revents = 0;
        result = poll(&input, 1, timeout_ms);
        if (result < 0) {
            if (errno == EINTR)
                continue;
            perror("poll");
            return 2;
        }
        if (result == 0)
            continue;
        if (input.revents & (POLLERR | POLLNVAL)) {
            fputs("Not started: standard input is unavailable.\n", stderr);
            return 3;
        }
        if (input.revents & (POLLIN | POLLHUP)) {
            char buffer[128];
            ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
            ssize_t i;
            if (count < 0) {
                if (errno == EINTR)
                    continue;
                perror("read");
                return 2;
            }
            if (count == 0) {
                fputs("Not started: standard input reached EOF.\n", stderr);
                return 3;
            }
            for (i = 0; i < count; ++i) {
                if (buffer[i] == '\n')
                    return 0;
            }
        }
    }
    return -1;
}

static int run_memory(unsigned int target_mib, double started, double deadline)
{
    void *chunks[MAX_CHUNKS] = {0};
    size_t chunk_count = 0;
    unsigned int allocated_mib = 0;
    long page_size = sysconf(_SC_PAGESIZE);
    int status;

    if (page_size <= 0) {
        fputs("Cannot determine the system page size.\n", stderr);
        return 2;
    }
    puts("elapsed_s,allocated_mib");
    while (allocated_mib < target_mib && !finished(deadline)) {
        unsigned int amount = target_mib - allocated_mib;
        size_t bytes;
        size_t offset;
        volatile unsigned char *data;
        if (amount > CHUNK_MIB)
            amount = CHUNK_MIB;
        bytes = (size_t)amount * MIB;
        chunks[chunk_count] = calloc(1, bytes);
        if (chunks[chunk_count] == NULL) {
            fputs("MemoryError: allocation failed. This alone does not prove an OOM kill.\n", stderr);
            status = 2;
            goto cleanup;
        }
        data = (volatile unsigned char *)chunks[chunk_count];
        ++chunk_count;
        /* 각 페이지에 실제로 써서, 빈 공간 예약만으로 끝나지 않게 한다. */
        for (offset = 0; offset < bytes && received_signal == 0; offset += (size_t)page_size)
            data[offset] = (unsigned char)(chunk_count | 1U);
        if (received_signal != 0)
            break;
        data[bytes - 1] = (unsigned char)(chunk_count | 1U);
        allocated_mib += amount;
        printf("%.3f,%u\n", monotonic_seconds() - started, allocated_mib);
        pause_briefly(250000000L, deadline);
    }
    if (!finished(deadline)) {
        printf("Holding %u MiB of requested data. Ctrl+C stops this process.\n", allocated_mib);
        while (!finished(deadline))
            pause_briefly(250000000L, deadline);
    }
    status = finish_status();

cleanup:
    while (chunk_count > 0)
        free(chunks[--chunk_count]);
    return status;
}

static void usage(FILE *stream)
{
    fprintf(stream,
        "resource-workload " VERSION "\n"
        "Usage: resource-workload cpu\n"
        "       resource-workload memory MiB\n"
        "       resource-workload --help | --version\n"
        "\n"
        "cpu: busy calculation; prints iterations per actual elapsed second.\n"
        "memory: integer MiB from 1 to 160; writes each page in up to 4 MiB steps.\n"
        "Examples: resource-workload memory 48; resource-workload memory 160\n"
        "Both modes wait for Enter, for up to %d seconds, before starting.\n"
        "Workload runtime is limited to %d seconds AFTER Enter; waiting is separate.\n"
        "Ctrl+C or SIGTERM stops the workload.\n"
        "This program does not configure resource policies or inspect cgroups.\n",
        INPUT_TIMEOUT_SECONDS, MAX_RUNTIME_SECONDS);
}

int main(int argc, char **argv)
{
    unsigned int target_mib = 0;
    double started;
    double deadline;
    int memory_mode;
    int status;

    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        usage(stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("resource-workload " VERSION);
        return 0;
    }
    memory_mode = argc == 3 && strcmp(argv[1], "memory") == 0;
    if (!(argc == 2 && strcmp(argv[1], "cpu") == 0) && !memory_mode) {
        usage(stderr);
        return 2;
    }
    if (memory_mode) {
        const char *digit;
        char *end;
        unsigned long parsed;
        if (argv[2][0] == '\0') {
            fputs("MiB must be an integer from 1 to 160.\n", stderr);
            return 2;
        }
        for (digit = argv[2]; *digit; ++digit) {
            if (*digit < '0' || *digit > '9') {
                fputs("MiB must be an integer from 1 to 160.\n", stderr);
                return 2;
            }
        }
        errno = 0;
        parsed = strtoul(argv[2], &end, 10);
        if (errno == ERANGE || *end != '\0' || parsed < 1 || parsed > MAX_MEMORY_MIB) {
            fputs("MiB must be an integer from 1 to 160.\n", stderr);
            return 2;
        }
        target_mib = (unsigned int)parsed;
    }
    if (install_signals() != 0)
        return 2;
    if (memory_mode)
        printf("mode=memory pid=%ld target_mib=%u max_runtime_s=%d\n",
               (long)getpid(), target_mib, MAX_RUNTIME_SECONDS);
    else
        printf("mode=cpu pid=%ld max_runtime_s=%d\n", (long)getpid(), MAX_RUNTIME_SECONDS);
    status = wait_for_enter();
    if (status < 0) {
        puts("Not started: cancelled while waiting for Enter.");
        return finish_status();
    }
    if (status != 0)
        return status;
    if (received_signal != 0)
        return finish_status();
    /* 입력 대기와 별도로 실제 부하 시작부터 실행 시간과 알람을 계산한다. */
    started = monotonic_seconds();
    deadline = started + MAX_RUNTIME_SECONDS;
    alarm(MAX_RUNTIME_SECONDS);
    status = memory_mode ? run_memory(target_mib, started, deadline) : run_cpu(started, deadline);
    alarm(0);
    return status;
}
