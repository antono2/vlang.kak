/* Only record signals in the handler. Each command releases resources synchronously. */
#include <signal.h>

static volatile sig_atomic_t kak_caught_signal;

static void kak_record_signal(int signum) {
    kak_caught_signal = signum;
}

static int kak_track_maintenance_signals(void) {
    struct sigaction action = {0};
    action.sa_handler = kak_record_signal;
    action.sa_flags = SA_RESTART;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGHUP, &action, 0) || sigaction(SIGINT, &action, 0) ||
        sigaction(SIGTERM, &action, 0);
}

static int kak_maintenance_signal(void) {
    return kak_caught_signal;
}
