#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdatomic.h>
#include <compression.h>
#include <time.h>

static _Atomic unsigned long calls[2][4], bytes[2];
static _Atomic unsigned long encode_calls, encode_cpu_ns, encode_wall_ns, encode_input;
static size_t count_encode(uint8_t *dst, size_t dst_size, const uint8_t *src, size_t src_size, void *scratch, compression_algorithm algorithm) {
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    uint64_t wall = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    size_t result = compression_encode_buffer(dst, dst_size, src, src_size, scratch, algorithm);
    encode_cpu_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu;
    encode_wall_ns += clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - wall;
    encode_calls++; encode_input += src_size;
    return result;
}
static ssize_t count_write(int fd, const void *data, size_t size) {
    int main = pthread_main_np() != 0;
    if (fd > 2) { calls[main][0]++; bytes[main] += size; }
    return write(fd, data, size);
}
static int count_lstat(const char *path, struct stat *info) {
    calls[pthread_main_np() != 0][1]++;
    return lstat(path, info);
}
static int count_fstat(int fd, struct stat *info) {
    calls[pthread_main_np() != 0][2]++;
    return fstat(fd, info);
}
static ssize_t count_read(int fd, void *data, size_t size) {
    calls[pthread_main_np() != 0][3]++;
    return read(fd, data, size);
}
#define INTERPOSE(new, old) __attribute__((used)) static struct { const void *replacement; const void *original; } ip_##old __attribute__((section("__DATA,__interpose"))) = {(const void *)&new, (const void *)&old};
INTERPOSE(count_write, write)
INTERPOSE(count_lstat, lstat)
INTERPOSE(count_fstat, fstat)
INTERPOSE(count_read, read)
INTERPOSE(count_encode, compression_encode_buffer)
__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "compression-profile calls=%lu input_bytes=%lu cpu_s=%.6f sum_wall_s=%.6f\n", encode_calls, encode_input, encode_cpu_ns / 1e9, encode_wall_ns / 1e9);
    for (int main = 0; main <= 1; ++main)
        fprintf(stderr, "io-counts main=%d write=%lu lstat=%lu fstat=%lu read=%lu write_bytes=%lu\n", main,
                calls[main][0], calls[main][1], calls[main][2], calls[main][3], bytes[main]);
}
