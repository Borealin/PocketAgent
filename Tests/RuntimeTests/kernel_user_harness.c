// Host-side exercise of two patched iSH user-side files, compiled for the Mac
// by test_kernel_user.py; prints one JSON object.
//
//   startup: arch/ish/kernel/setup_user.c wait_for_startup_bounded gives up
//            when the kernel never reports startup and returns promptly when
//            it does; with argument "panic", a panic during the wait ends it
//            promptly as a failure.
//   egress:  arch/ish/kernel/syscalls_user.c pocket_destination_allowed, the
//            check host_connect/host_sendmsg run on the guest's (Linux layout)
//            sockaddr before converting it.
#include <arpa/inet.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int notify_startup(void);
void pocket_startup_failed(void);
int wait_for_startup_bounded(unsigned seconds);
int pocket_destination_allowed(const void *name, unsigned name_len);
void pocket_set_blocked_hosts(const uint32_t *addresses_network_order, unsigned count);

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void *notify_later(void *panic) {
    usleep(200 * 1000);
    if (panic) pocket_startup_failed();
    else notify_startup();
    return NULL;
}

// struct sockaddr_in as the Linux guest lays it out: u16 family, be16 port, be32 address.
static int allowed(const char *address, unsigned port) {
    unsigned char name[16] = {0};
    uint16_t family = 2, be_port = htons(port);
    uint32_t be_address = inet_addr(address);
    memcpy(name, &family, 2);
    memcpy(name + 2, &be_port, 2);
    memcpy(name + 4, &be_address, 4);
    return pocket_destination_allowed(name, sizeof name);
}

int main(int argc, char **argv) {
    pthread_t thread;
    double start = now();
    if (argc > 1 && strcmp(argv[1], "panic") == 0) {
        pthread_create(&thread, NULL, notify_later, "panic");
        int result = wait_for_startup_bounded(10);
        printf("{\"panicResult\": %d, \"panicSeconds\": %.3f}\n", result, now() - start);
        pthread_join(thread, NULL);
        return 0;
    }
    // Startup never reported: the bounded wait returns after its bound.
    int neverResult = wait_for_startup_bounded(1);
    double neverSeconds = now() - start;
    // Reported while waiting: returns promptly with success.
    pthread_create(&thread, NULL, notify_later, NULL);
    start = now();
    int laterResult = wait_for_startup_bounded(10);
    double laterSeconds = now() - start;
    pthread_join(thread, NULL);
    int againResult = wait_for_startup_bounded(0);

    uint32_t blocked = inet_addr("203.0.113.7");
    int beforeList = allowed("203.0.113.7", 443);
    pocket_set_blocked_hosts(&blocked, 1);
    int listed = allowed("203.0.113.7", 443);
    pocket_set_blocked_hosts(NULL, 0);
    int afterClear = allowed("203.0.113.7", 443);

    printf("{\"neverResult\": %d, \"neverSeconds\": %.3f, \"laterResult\": %d, \"laterSeconds\": %.3f, "
           "\"againResult\": %d, "
           "\"publicHTTPS\": %d, \"publicDNS\": %d, \"connectedSocket\": %d, \"shortName\": %d, "
           "\"public8100\": %d, \"public62078\": %d, \"public8101\": %d, "
           "\"loopback\": %d, \"private10\": %d, \"private192\": %d, \"cgnat\": %d, \"linkLocal\": %d, \"multicast\": %d, "
           "\"beforeList\": %d, \"listed\": %d, \"afterClear\": %d}\n",
           neverResult, neverSeconds, laterResult, laterSeconds, againResult,
           allowed("1.1.1.1", 443), allowed("8.8.8.8", 53), pocket_destination_allowed(NULL, 0),
           pocket_destination_allowed("\x02\x00\x01\xbb", 4),
           allowed("1.1.1.1", 8100), allowed("17.253.144.10", 62078), allowed("1.1.1.1", 8101),
           allowed("127.0.0.1", 443), allowed("10.0.0.2", 443), allowed("192.168.1.2", 443),
           allowed("100.64.0.1", 443), allowed("169.254.1.1", 443), allowed("224.0.0.251", 5353),
           beforeList, listed, afterClear);
    return 0;
}
