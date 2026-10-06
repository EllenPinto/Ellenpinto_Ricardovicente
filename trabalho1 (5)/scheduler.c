#include "scheduler.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "msg.h"

#ifndef TIME_SLICE_MS
#define TIME_SLICE_MS 1000
#endif

#ifndef BOOST_INTERVAL_MS
#define BOOST_INTERVAL_MS 10000
#endif

#ifndef MAX_PRIORITY
#define MAX_PRIORITY 3
#endif

// Protótipos das funções de remoção da fila para o compilador as reconhecer

// Variável global/estática para registar o último boost de prioridade
static uint32_t last_boost_time_ms = 0;

static const char *SCHED_NAMES[] = { "FIFO", "SJF", "RR", "MLFQ", NULL };
static sched_algo_en sched_algo = SCHED_FIFO;

int set_sched_algo(const char *name) {
    for (int i = 0; SCHED_NAMES[i] != NULL; i++) {
        if (strcasecmp(SCHED_NAMES[i], name) == 0) {
            sched_algo = (sched_algo_en) i;
            return sched_algo;
        }
    }
    return -1;
}

const char *get_sched_algo_str(void) {
    return SCHED_NAMES[sched_algo];
}

/**
 * Send DONE to the application and move the finished burst to the command queue.
 */
static void finish_burst(uint32_t current_time_ms, queue_t *cq, pcb_t *task) {
    // [Q3] Print do estado final do processo
    printf("Q3 - ESTADO: PID %d terminou o burst (Passa do estado RUNNING para TERMINATED/DONE) no tempo %d ms\n", task->pid, current_time_ms);
    msg_t msg = {
        .pid = task->pid,
        .request = PROCESS_REQUEST_DONE,
        .time_ms = current_time_ms
    };
    if (write(task->sockfd, &msg, sizeof(msg_t)) != sizeof(msg_t)) {
        perror("write");
    }
    enqueue_pcb(cq, task);
}

int scheduler(uint32_t current_time_ms, queue_t *rq, queue_t *cq, pcb_t **cpu_task) {

    // ---------------------------------------------------------
    // 1. ELEVAÇÃO DE PRIORIDADE (MLFQ Priority Boost)
    // ---------------------------------------------------------
    if (sched_algo == SCHED_MLFQ && (current_time_ms - last_boost_time_ms) >= BOOST_INTERVAL_MS) {
        last_boost_time_ms = current_time_ms;

        // Reinicia o valor de nice para 0 em todos os processos da Ready Queue
        queue_elem_t *curr_node = rq->head;
        while (curr_node != NULL) {
            curr_node->pcb->nice = 0;
            curr_node = curr_node->next;
        }

        // Se houver um processo no CPU, repõe também a sua prioridade
        if (*cpu_task != NULL) {
            (*cpu_task)->nice = 0;
        }

        printf("Time [ms]: %d\t*** MLFQ PRIORITY BOOST ***\n", current_time_ms);
    }

    // ---------------------------------------------------------
    // 2. GESTÃO DA TAREFA NO CPU (Fim de Execução / Preempção)
    // ---------------------------------------------------------
    if (*cpu_task != NULL) {
        (*cpu_task)->ellapsed_time_ms += TICKS_MS;

        // Caso A: O processo concluiu o burst
        if ((*cpu_task)->ellapsed_time_ms >= (*cpu_task)->time_ms) {
            printf("Q6.2 - FIM CPU: O processo PID %d terminou o seu burst no tempo %d ms\n",
                   (*cpu_task)->pid, current_time_ms);
            finish_burst(current_time_ms, cq, *cpu_task);
            *cpu_task = NULL;
        }
        // Caso B: Preempção por esgotamento do quantum (RR e MLFQ)
        else if (sched_algo == SCHED_RR || sched_algo == SCHED_MLFQ) {
            uint32_t elapsed_slice = current_time_ms - (*cpu_task)->slice_start_ms;

            if (elapsed_slice >= TIME_SLICE_MS) {
                printf("Time [ms]: %d\tPID: %d\tPREEMPTED (Quantum de %dms atingido)\n",
                       current_time_ms, (*cpu_task)->pid, TIME_SLICE_MS);

                // No MLFQ, desce de prioridade (incrementa o valor de nice)
                if (sched_algo == SCHED_MLFQ && (*cpu_task)->nice < MAX_PRIORITY) {
                    (*cpu_task)->nice++;
                }

                enqueue_pcb(rq, *cpu_task); // Regressa à fila de prontos
                *cpu_task = NULL;           // Liberta o CPU
            }
        }
    }

    // ---------------------------------------------------------
    // 3. SELEÇÃO DO PRÓXIMO PROCESSO
    // ---------------------------------------------------------
    if (*cpu_task == NULL) {
        if (sched_algo == SCHED_FIFO || sched_algo == SCHED_RR) {
            *cpu_task = dequeue_pcb(rq);
        }
        else if (sched_algo == SCHED_SJF) {
            *cpu_task = dequeue_pcb_sjf(rq);
        }
        else if (sched_algo == SCHED_MLFQ) {
            *cpu_task = dequeue_pcb_mlfq(rq);
        }
        else {
            printf("Algoritmo de escalonamento nao implementado\n");
        }

        if (*cpu_task != NULL) {
            printf("Q3 - ESTADO INICIAL: Processo PID %d transitou para RUNNING no tempo %d ms\n",
                   (*cpu_task)->pid, current_time_ms);

            if (sched_algo == SCHED_SJF) {
                printf("Q4.1 - READY QUEUE: Processo PID %d retirado com SJF\n", (*cpu_task)->pid);
            } else if (sched_algo == SCHED_MLFQ) {
                printf("Q4.1 - READY QUEUE: Processo PID %d retirado com MLFQ (nice: %d)\n",
                       (*cpu_task)->pid, (*cpu_task)->nice);
            } else {
                printf("Q4.1 - READY QUEUE: Processo PID %d retirado da cabeca da fila (FIFO)\n", (*cpu_task)->pid);
            }

            printf("Q5.1 - ESCALONADOR: CPU livre. Atribuido PID %d ao CPU\n", (*cpu_task)->pid);
            printf("Q6.1 - INICIO CPU: Processo PID %d comecou a executar no tempo %d ms\n",
                   (*cpu_task)->pid, current_time_ms);

            (*cpu_task)->slice_start_ms = current_time_ms;
            return 1;
        }
    }

    return 0;
}

// ---------------------------------------------------------
// FUNÇÕES AUXILIARES DE REMOÇÃO DA QUEUE
// ---------------------------------------------------------
pcb_t *dequeue_pcb_sjf(queue_t *q) {
    // 1. Verificacao de seguranca da fila
    if (q == NULL || q->head == NULL) {
        return NULL;
    }

    // 2. Assume inicialmente que o primeiro elemento tem o menor tempo
    queue_elem_t *min_node = q->head;
    queue_elem_t *curr = q->head->next;

    // 3. Percorre o resto da fila a procurar um tempo de burst menor
    while (curr != NULL) {
        if (curr->pcb->time_ms < min_node->pcb->time_ms) {
            min_node = curr;
        }
        curr = curr->next;
    }

    // 4. Remove o no encontrado utilizando a funcao auxiliar do projeto
    queue_elem_t *removed_elem = remove_queue_elem(q, min_node);
    if (removed_elem == NULL) {
        return NULL;
    }

    // 5. Extrai o PCB e liberta a memoria da celula da fila
    pcb_t *task = removed_elem->pcb;
    free(removed_elem);

    return task;
}

pcb_t* dequeue_pcb_mlfq(queue_t *q) {
    if (q == NULL || q->head == NULL) {
        return NULL;
    }

    queue_elem_t *curr = q->head;
    queue_elem_t *highest_prio_node = NULL;

    while (curr != NULL) {
        if (highest_prio_node == NULL || curr->pcb->nice < highest_prio_node->pcb->nice) {
            highest_prio_node = curr;
        }
        curr = curr->next;
    }

    queue_elem_t *removed_node = remove_queue_elem(q, highest_prio_node);
    pcb_t *target_pcb = removed_node->pcb;
    free(removed_node);

    return target_pcb;
}

