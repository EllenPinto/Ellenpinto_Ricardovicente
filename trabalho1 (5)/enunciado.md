# Sistemas Operativos 2026/2027 — Trabalho Prático 1

## Simulador de Escalonamento

---

## 1. Descrição

Este projeto simula um sistema de escalonamento de processos e é composto por dois
programas que comunicam entre si através de um *socket* UNIX:

- **`application`** — representa uma aplicação de utilizador. Lê de um ficheiro `.csv` a
  sequência de *bursts* (períodos de CPU e, opcionalmente, de bloqueio em E/S) e vai
  pedindo ao simulador que os execute.
- **`ossim`** — o simulador (o "SO"). Recebe os pedidos das aplicações, coloca-os em filas
  e decide a ordem de execução aplicando um **algoritmo de escalonamento**.

Quando uma aplicação termina, escreve na sua saída:

- **`Elapsed`** — tempo real decorrido desde o primeiro *burst* até ao fim;
- **`CPU`** — tempo que esteve efetivamente a usar o CPU;
- **`BLOCKED`** — tempo que esteve bloqueada (à espera de E/S).

O simulador já implementa o algoritmo **FIFO**. Os alunos devem acrescentar:

| Algoritmo | Descrição | *Time-slice* |
|---|---|---|
| **FIFO** (First-In, First-Out) | Fornecido. Não preemptivo: cada processo corre até terminar o *burst*. | — |
| **SJF** (Shortest Job First) | Não preemptivo. Escolhe da *ready queue* o processo com menor *burst* de CPU. | — |
| **RR** (Round-Robin) | Preemptivo. Cada processo corre no máximo um *time-slice* e volta para o fim da fila. | 500 ms |
| **MLFQ** (Multi-Level Feedback Queue) | Várias filas de prioridade; um processo que gasta todo o *time-slice* desce de nível; processos que bloqueiam cedo mantêm prioridade. Reforço periódico (*boost*). | 500 ms |

---

## 2. Estrutura do código

| Ficheiro | Função |
|---|---|
| `application.c` | Aplicação de utilizador: lê o `.csv` de *bursts* e envia `RUN` / `BLOCK` ao simulador. **Não deve ser alterado.** |
| `ossim.c` | Programa principal do simulador: *parsing* de argumentos, *socket* servidor, ciclo principal (um *tick* de `TICKS_MS`), gestão das filas. |
| `scheduler.c` / `.h` | O escalonador. Contém o **FIFO**; é aqui que os alunos acrescentam SJF, RR e MLFQ. |
| `queue.c` / `.h` | Filas de PCBs (`COMMAND`, `READY`, `BLOCKED`), *socket* servidor, receção de mensagens. |
| `burst_queue.c` / `.h` | *Parsing* dos ficheiros `.csv` de *bursts*. |
| `pcb.h` | Definição do *Process Control Block*. |
| `msg.h` | Formato das mensagens `application` ⇄ `ossim` e constante `TICKS_MS`. |

### Fluxo de execução

**`application`** — para cada linha do `.csv`:

1. envia `RUN` com o tempo de CPU do *burst*;
2. espera `ACK` (pedido aceite) e `DONE` (*burst* terminado);
3. se a linha tiver tempo de bloqueio, envia `BLOCK` e espera de novo `ACK` + `DONE`.

**`ossim`** — em cada *tick* (`TICKS_MS = 10 ms`):

1. `check_new_commands()` — aceita novas ligações e lê mensagens da `COMMAND queue`,
   movendo cada PCB para `READY` (`RUN`) ou `BLOCKED` (`BLOCK`) e respondendo `ACK`;
2. `check_blocked_queue()` — desconta o tempo de E/S; quando chega a zero envia `DONE` e
   devolve o PCB à `COMMAND queue`;
3. `scheduler()` — um passo de escalonamento: eventualmente coloca um novo PCB no CPU e,
   quando um *burst* termina, envia `DONE` e liberta o CPU.

---

## 3. Formato dos ficheiros de *bursts* (`.csv`)

Uma linha por *burst*. Linhas começadas por `#` são ignoradas.

```
tempo_cpu_ms , tempo_bloqueio_ms , nice , [lista_de_paginas]
```

No Trabalho 1 só interessam:

- **`tempo_cpu_ms`** — obrigatório;
- **`tempo_bloqueio_ms`** — usado nos cenários 3 e 4 (com E/S); `0` nos cenários 1 e 2;
- **`nice`** — só o **MLFQ** o usa (nível de prioridade inicial); deixar a `0` nos restantes.

As colunas `tempo_bloqueio_ms`, `nice` e `[lista_de_paginas]` são **opcionais** — a lista de
páginas só será usada no Trabalho 2. O mesmo `application.c` serve os três trabalhos.

---

## 4. Cenários de simulação

| Cenário | Script | Aplicações | Observações |
|---|---|---|---|
| 1 | `run_apps.sh` | A=10 s, B=15 s, C=20 s (só CPU) | Todos os algoritmos. |
| 2 | `run_apps2.sh` | A=5 s, B=10 s, C=4 s, D=2 s, E=3 s, F=15 s (só CPU) | Todos os algoritmos. |
| 3 | `run_appsio.sh` | 3 aplicações com CPU + E/S (`scenarios/3/`) | Só **MLFQ**. |
| 4 | `run_appsio2.sh` | 3 aplicações, maior contenção, com E/S (`scenarios/4/`) | Só **MLFQ**. |

Os ficheiros `.csv` estão em `scenarios/`. Podem (e devem) ser ajustados/criados novos
cenários para evidenciar as diferenças entre algoritmos.

### Como executar

```sh
cmake -S . -B build && cmake --build build

# terminal 1
./build/ossim --sched RR

# terminal 2
./run_apps.sh
```

`--sched` aceita `FIFO` (por omissão), `SJF`, `RR` ou `MLFQ`. Terminar o simulador com `Ctrl-C`.

---

## 5. Relatório

O relatório deve conter:

1. **Identificação dos autores** e do **repositório GitHub**.
2. Para cada cenário, uma tabela com o **tempo de execução** e o **tempo de resposta** de
   cada aplicação, por algoritmo:

   | Aplicação | Métrica (s) | FIFO | SJF | RR | MLFQ |
   |---|---|---|---|---|---|
   | A | Tempo de execução | | | | |
   | A | Tempo de resposta | | | | |
   | … | … | | | | |

   Cada algoritmo deve ser corrido **pelo menos 3 vezes** por cenário; regista-se a média.
   Nos cenários 3 e 4 só há valores para MLFQ (os restantes: *n.d.*).

3. **Tabela resumo** com o tempo médio de execução e de resposta por cenário e algoritmo.
4. **Análise** comparando o comportamento dos algoritmos (ordem de execução, *starvation*,
   tempo de resposta de processos interativos vs. CPU-bound, efeito do *time-slice*).

---

## 6. Entrega

- Trabalho individual ou em grupo de 2.
- Código no repositório GitHub do grupo (convidar os professores como colaboradores).
- Entrega no Moodle. Defesa na aula prática da semana seguinte.
