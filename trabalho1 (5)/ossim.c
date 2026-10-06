#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>

#include "scheduler.h"
#include "msg.h"
#include "queue.h"

static volatile sig_atomic_t keep_running = 1;

void handle_signal(int sig) {
    printf("\n[Signal] Caught signal %d — stopping scheduler...\n", sig);
    keep_running = 0;
}

int parse_args(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--sched") == 0) {
            if (i + 1 < argc) {
                if (set_sched_algo(argv[++i]) < 0) {
                    fprintf(stderr, "Error: invalid scheduler: %s (use FIFO, SJF, RR or MLFQ)\n", argv[i]);
                    return -1;
                }
            } else {
                fprintf(stderr, "Error: --sched requires an algorithm name\n");
                return -1;
            }   
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("Usage: %s [--sched FIFO|SJF|RR|MLFQ]\n", argv[0]);
            return 1;
        } else {
            fprintf(stderr, "Unknown option: %s\nTry --help\n", argv[i]);
            return -1;
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    int res = parse_args(argc, argv);
    if (res > 0) return EXIT_SUCCESS;
    if (res < 0) return EXIT_FAILURE;

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    printf("OSSIM scheduler configured with algorithm %s\n", get_sched_algo_str());

    // Three queues:
    // - COMMAND: PCBs waiting for (new) instructions from their application
    // - READY:   PCBs ready to run on the CPU
    // - BLOCKED: PCBs waiting for I/O
    queue_t command_queue = {0};
    queue_t ready_queue   = {0};
    queue_t blocked_queue = {0};

    int server_fd = setup_server_socket(SOCKET_PATH);
    if (server_fd < 0) {
        fprintf(stderr, "Failed to set up server socket\n");
        return EXIT_FAILURE;
    }
    printf("Scheduler server listening on %s...\n", SOCKET_PATH);
    reset_time();

    pcb_t *cpu_task = NULL;   // single CPU

    while (keep_running) {
        uint32_t now = now_ms();
        check_new_commands(&command_queue, &blocked_queue, &ready_queue, server_fd, now);
        check_blocked_queue(&blocked_queue, &command_queue, now);
        scheduler(now, &ready_queue, &command_queue, &cpu_task);
        usleep(TICKS_MS * 1000);
    }

    printf("[Scheduler] Cleaning up and shutting down...\n");
    close(server_fd);
    unlink(SOCKET_PATH);
    printf("[Scheduler] Shutdown complete.\n");
    return 0;
}
