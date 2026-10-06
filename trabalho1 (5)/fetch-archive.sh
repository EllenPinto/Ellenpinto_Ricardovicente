#!/usr/bin/env bash
# fetch-archive.sh — compila o alvo `archive` no DOLOS (remoto) e traz o
# entrega.zip resultante para este PC, numa só ligação SSH.
#
# Com a toolchain SSH/Remote Host do CLion (ver README.md, secção
# "CLion — deployment remoto"), `cmake --build build --target archive` corre
# dentro do contentor DOLOS, não neste computador — por isso não chega
# correr esse comando no CLion; o entrega.zip fica lá dentro. Este script
# faz as duas coisas de uma só vez: compila-o de novo no DOLOS e despeja-o
# diretamente para aqui.
#
# A compilação usa uma pasta de build própria, descartável, dentro de /tmp
# no lado remoto — nunca a pasta "build" real do projeto (a que o CLion usa
# para os builds a sério). O zip em si não fica dentro dessa pasta de
# build: vai diretamente para /tmp com um nome único por execução (via
# -DOSSIM_ARCHIVE_NAME=... -DOSSIM_ARCHIVE_DIR=/tmp, ver CMakeLists.txt),
# pelo que o caminho final é sempre conhecido de antemão — não depende de
# qual pasta de build foi usada, nem é preciso procurá-lo. Tanto o zip como
# a pasta de build descartável são apagados no final.
#
# Onde é que isto corre no lado remoto? Por ordem de prioridade:
#   1. O argumento da linha de comandos, se o der.
#   2. O mapping REAL configurado no CLion para este projeto — lido de
#      .idea/deployment.xml, casado pelo hostId da toolchain SSH (de
#      .../JetBrains/CLion*/options/{mac,linux}/toolchains.xml) para saber
#      exatamente qual mapping é o do CMake, caso haja mais que um — mais
#      o "root path" desse servidor, se estiver definido, em
#      .../JetBrains/CLion*/options/webServers.xml. É o que o CLion está
#      mesmo a usar, não uma adivinhação.
#   3. Se não houver nada disso (projeto nunca aberto no CLion com
#      deployment configurado): /tmp/<nome da pasta do projeto>, que é o
#      valor por omissão do CLion quando ninguém personalizou um "Root
#      path" / "Deployment path" (ver README.md).
# Em qualquer dos casos, se a pasta não existir ou não tiver este projeto
# (sem CMakeLists.txt), o cmake remoto falha logo e o script pára com erro
# — nunca "adivinha em silêncio" um resultado errado.
#
# Uso:
#   ./fetch-archive.sh [pasta-remota] [caminho-local]
#
#   pasta-remota   caminho absoluto (ex.: /tmp/o-meu-projeto) ou, se não
#                  começar por "/", um nome relativo à home do utilizador
#                  remoto (ex.: trabalho1 -> /home/aluno/trabalho1).
#   caminho-local  onde gravar o zip aqui (por omissão: ./entrega.zip)
#
# Ligação (por omissão do DOLOS — ver ../DOLOS/README.md): localhost:2222,
# utilizador aluno, palavra-passe aluno (ou chave SSH em
# /home/aluno/.ssh/authorized_keys dentro do contentor). Para mudar, defina
# as variáveis de ambiente DOLOS_SSH_HOST / DOLOS_SSH_PORT / DOLOS_SSH_USER.

set -euo pipefail

REMOTE_HOST="${DOLOS_SSH_HOST:-localhost}"
REMOTE_PORT="${DOLOS_SSH_PORT:-2222}"
REMOTE_USER="${DOLOS_SSH_USER:-aluno}"

# Localizações possíveis dos ficheiros globais do CLion (por versão/SO) de
# que precisamos: webServers.xml guarda o "root path" de cada servidor SSH
# configurado; toolchains.xml diz qual servidor (hostId) é usado por uma
# toolchain SSH. O script só corre em macOS/Linux, tal como o resto do
# projeto.
WEBSERVERS_GLOBS=(
    "$HOME/Library/Application Support/JetBrains"/CLion*/options/webServers.xml
    "$HOME/.config/JetBrains"/CLion*/options/webServers.xml
)
TOOLCHAINS_GLOBS=(
    "$HOME/Library/Application Support/JetBrains"/CLion*/options/mac/toolchains.xml
    "$HOME/Library/Application Support/JetBrains"/CLion*/options/toolchains.xml
    "$HOME/.config/JetBrains"/CLion*/options/linux/toolchains.xml
    "$HOME/.config/JetBrains"/CLion*/options/toolchains.xml
)

# Ficheiro mais recentemente modificado de uma lista de padrões glob (para
# quando há várias versões do CLion instaladas, usar a que está mesmo a
# ser usada agora). Imprime "" se nenhum existir.
newest_file() {
    local f best="" best_mtime=-1 mtime
    for f in "$@"; do
        [ -f "$f" ] || continue
        mtime=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)
        if [ "$mtime" -gt "$best_mtime" ]; then
            best_mtime="$mtime"
            best="$f"
        fi
    done
    printf '%s' "$best"
}

# Extrai o "root path" (rootFolder) do <webServer id="...">, se estiver
# definido — vazio (raiz "/") caso contrário.
root_folder_for_host() {
    local hostid="$1" ws
    ws="$(newest_file "${WEBSERVERS_GLOBS[@]}")"
    [ -n "$ws" ] || return
    awk -v h="$hostid" 'BEGIN{RS="</webServer>"} index($0, "id=\"" h "\"")' "$ws" 2>/dev/null \
        | grep -o 'rootFolder="[^"]*"' | head -n1 | sed -E 's/rootFolder="([^"]*)"/\1/'
}

# hostId de qualquer toolchain SSH configurada no CLion (global, não por
# projeto) — é isto que identifica exatamente qual mapping em
# deployment.xml pertence à toolchain que compila o projeto, em vez de
# assumir que é o primeiro mapping listado (pode haver mais que um, ex.:
# um "Deployment" para SFTP genérico ao lado do usado pelo CMake).
ssh_toolchain_hostids() {
    local tc
    tc="$(newest_file "${TOOLCHAINS_GLOBS[@]}")"
    [ -n "$tc" ] || return
    grep -o '<toolchain[^>]*toolSetKind="SSH"[^>]*>' "$tc" 2>/dev/null \
        | grep -o 'hostId="[^"]*"' | sed -E 's/hostId="([^"]*)"/\1/'
}

# Lê o mapping configurado no CLion para este projeto (o .idea/ do topo do
# repositório git), se existir. Imprime o caminho remoto completo, ou nada
# se não houver deployment.xml / mapping.
detect_from_clion() {
    local toplevel dep hostid deploy server_name root
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -z "$toplevel" ] && return
    dep="$toplevel/.idea/deployment.xml"
    [ -f "$dep" ] || return

    # Caminho preciso: casar pelo hostId da toolchain SSH, para o caso de
    # deployment.xml ter mais que um <paths> (ex.: um "localhost" genérico
    # ao lado do "Remote Host" que o CMake usa mesmo).
    for hostid in $(ssh_toolchain_hostids); do
        deploy="$(awk -v h="$hostid" 'BEGIN{RS="</paths>"} index($0, h)' "$dep" 2>/dev/null \
                  | grep -o 'deploy="[^"]*"' | head -n1 | sed -E 's/deploy="([^"]*)"/\1/')"
        if [ -n "$deploy" ]; then
            root="$(root_folder_for_host "$hostid")"
            printf '%s%s' "$root" "$deploy"
            return
        fi
    done

    # Nenhuma toolchain SSH encontrada/casada (ex.: toolchains.xml
    # ilegível): cai no primeiro mapping listado, como antes.
    deploy="$(grep -o 'deploy="[^"]*"' "$dep" | head -n1 | sed -E 's/deploy="([^"]*)"/\1/')"
    [ -z "$deploy" ] && return
    server_name="$(grep -o '<paths name="[^"]*"' "$dep" | head -n1 | sed -E 's/<paths name="([^"]*)"/\1/')"
    root=""
    if [ -n "$server_name" ]; then
        ws="$(newest_file "${WEBSERVERS_GLOBS[@]}")"
        [ -n "$ws" ] && root="$(awk -v n="$server_name" 'BEGIN{RS="</webServer>"} index($0, "name=\"" n "\"")' "$ws" 2>/dev/null \
              | grep -o 'rootFolder="[^"]*"' | head -n1 | sed -E 's/rootFolder="([^"]*)"/\1/')"
    fi
    printf '%s%s' "$root" "$deploy"
}

RAW_PATH="${1:-}"
if [ -z "$RAW_PATH" ]; then
    RAW_PATH="$(detect_from_clion || true)"
fi
if [ -z "$RAW_PATH" ]; then
    # Nem argumento, nem deployment.xml: cai no valor por omissão do CLion.
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    RAW_PATH="/tmp/$(basename "${toplevel:-$PWD}")"
fi

case "$RAW_PATH" in
    /*) REMOTE_PATH="$RAW_PATH" ;;
    *)  REMOTE_PATH="/home/${REMOTE_USER}/${RAW_PATH}" ;;
esac

LOCAL_PATH="${2:-entrega.zip}"

# Identificador único desta execução: nomeia tanto a pasta de build
# descartável (usada só para configurar/compilar, nunca a "build" real do
# projeto) como o zip, para nunca haver dúvida (nem colisão com outra
# execução concorrente) sobre qual ficheiro é o nosso. O zip em si vai
# para /tmp diretamente (-DOSSIM_ARCHIVE_DIR=/tmp) — não fica dentro da
# pasta de build, por isso o caminho final não depende dela.
TOKEN="$(date +%Y%m%d%H%M%S)-$$"
ARCHIVE_NAME="entrega-${TOKEN}.zip"
BUILD_DIR="/tmp/ossim-fetch-${TOKEN}"
ARCHIVE_PATH="/tmp/${ARCHIVE_NAME}"

# Modelo do comando remoto, com marcadores __PLACEHOLDER__ substituídos a
# seguir (heredoc de aspas simples: nada aqui é expandido por este shell,
# por isso não há escapes de $ ou " a gerir). O caminho do zip resultante
# é conhecido de antemão (fixo em /tmp) — não é preciso procurá-lo.
read -r -d '' REMOTE_TEMPLATE <<'EOF' || true
set -e
cd '__REMOTE_PATH__' || {
    echo "Nao encontrei __REMOTE_PATH__ no DOLOS." >&2
    echo "Indique a pasta certa: ./fetch-archive.sh <pasta-remota>" >&2
    exit 1
}
cmake -S . -B '__BUILD_DIR__' -DOSSIM_ARCHIVE_NAME='__ARCHIVE_NAME__' -DOSSIM_ARCHIVE_DIR=/tmp >&2
cmake --build '__BUILD_DIR__' --target archive >&2
if [ ! -f '__ARCHIVE_PATH__' ]; then
    echo "O build nao criou __ARCHIVE_PATH__." >&2
    exit 1
fi
cat '__ARCHIVE_PATH__'
rm -rf '__BUILD_DIR__' '__ARCHIVE_PATH__'
EOF

REMOTE_CMD="${REMOTE_TEMPLATE//__REMOTE_PATH__/$REMOTE_PATH}"
REMOTE_CMD="${REMOTE_CMD//__BUILD_DIR__/$BUILD_DIR}"
REMOTE_CMD="${REMOTE_CMD//__ARCHIVE_NAME__/$ARCHIVE_NAME}"
REMOTE_CMD="${REMOTE_CMD//__ARCHIVE_PATH__/$ARCHIVE_PATH}"

TMP_PATH="$(mktemp)"
trap 'rm -f "$TMP_PATH"' EXIT

echo "A ligar a ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT} (pasta remota: ${REMOTE_PATH})..." >&2
ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "$REMOTE_CMD" > "$TMP_PATH"

mv "$TMP_PATH" "$LOCAL_PATH"
trap - EXIT
echo "OK: $LOCAL_PATH"
