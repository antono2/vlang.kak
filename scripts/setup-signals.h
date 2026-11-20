/* Only record signals in the handler. Setup restores the snapshot synchronously. */
#include <signal.h>

static volatile sig_atomic_t kak_setup_interrupted;

static void kak_setup_interrupt(int signum) {
    (void)signum;
    kak_setup_interrupted = 1;
}

static int kak_setup_track_signals(void) {
    struct sigaction action = {0};
    action.sa_handler = kak_setup_interrupt;
    action.sa_flags = SA_RESTART;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGHUP, &action, 0) || sigaction(SIGINT, &action, 0) ||
        sigaction(SIGTERM, &action, 0);
}

static int kak_setup_was_interrupted(void) {
    return kak_setup_interrupted;
}
