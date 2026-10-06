# OSSIM — Simulador de Escalonamento

Sistemas Operativos 2026/2027 — Universidade Lusófona.

Simulador de um sistema operativo simplificado. Dois programas comunicam por
*socket* UNIX:

- **`application`** — processo de utilizador. Lê um perfil de *bursts* de um
  ficheiro `.csv` e envia pedidos `RUN` / `BLOCK` ao simulador.
- **`ossim`** — o "SO": servidor de *sockets*, filas de processos e escalonador.

O enunciado deste trabalho está em **[`enunciado.md`](enunciado.md)**; o formato
dos ficheiros de dados em **[`FORMATO_CSV.md`](FORMATO_CSV.md)**.

## Compilar

```sh
cmake -S . -B build && cmake --build build
```

## CLion — *deployment* remoto

Por omissão o CLion sincroniza e compila numa pasta temporária do servidor
(`/tmp/...`). Para usar antes uma subpasta de `/home/aluno`:

1. **Settings → Build, Execution, Deployment → Deployment**, selecionar o servidor
   SSH/SFTP:
   - separador **Connection** → *Root path*: `/home/aluno` (botão *Autodetect*);
   - separador **Mappings** → *Deployment path*: `trabalho1` (fica relativo ao
     *Root path*), ou seja `/home/aluno/trabalho1`.
2. **Settings → Build, Execution, Deployment → CMake**, no perfil que usa a
   *toolchain* remota, pôr *Build directory* = `build` (caminho **relativo**, não
   absoluto nem em `/tmp`).

Resultado: fontes em `/home/aluno/trabalho1` e binários em
`/home/aluno/trabalho1/build`.

## Executar

Num terminal, o simulador (algoritmo de escalonamento por omissão: FIFO):

```sh
./build/ossim                 # FIFO
./build/ossim --sched RR      # FIFO | SJF | RR | MLFQ
```

Noutro terminal, uma `application` por cada perfil `.csv` que queira correr em
simultâneo (o simulador tem de estar já a correr):

```sh
./build/application scenarios/1/A.csv &
./build/application scenarios/1/B.csv &
./build/application scenarios/1/C.csv &
wait
```

Há perfis prontos em `scenarios/` (`1/` e `2/` só com CPU; `3/` e `4/` com E/S,
úteis para o MLFQ). Pode criar os seus.

Cada `application` imprime `Elapsed`, `CPU` e `BLOCKED` (segundos) quando termina.
`Ctrl-C` termina o simulador.

## Entrega

Gerar o `entrega.zip` (fontes, `CMakeLists.txt` e cenários) e submeter esse
ficheiro no Moodle:

```sh
cmake -S . -B build
cmake --build build --target archive     # cria build/entrega.zip
```

Se estiver a compilar com uma *toolchain* remota do CLion (SSH / Remote
Host — por exemplo o DOLOS), este comando corre no servidor remoto, pelo que
o `entrega.zip` fica lá, não neste computador. Traga-o para aqui com:

```sh
./fetch-archive.sh
```

## Protocolo `application` ⇄ `ossim`

```
Simulador                           Aplicações
   |                                    |
   | <---- App1 RUN (tempo) ----------- |
   | ----- App1 ACK (relógio) --------> |
   | <---- App2 RUN (tempo) ----------- |
   | ----- App2 ACK (relógio) --------> |
   | ----- App1 DONE (relógio) -------> |
   | <---- App1 BLOCK (tempo) --------- |
   | ----- App1 ACK (relógio) --------> |
   | ----- App2 DONE (relógio) -------> |
   | <---- App2 BLOCK (tempo) --------- |
   | ----- App2 ACK (relógio) --------> |
```
