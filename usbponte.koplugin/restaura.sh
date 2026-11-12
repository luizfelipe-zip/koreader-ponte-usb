#!/bin/sh
#
# Restaura dados de leitura do último backup da Ponte USB.
#
#   restaura.sh auto [arquivo_estado]  -> só o que está corrompido (e settings.reader.lua ausente)
#   restaura.sh faltando               -> também o progresso que sumiu de livros que ainda existem
#
# Nunca apaga nada: a versão quebrada fica ao lado como *.quebrado.
#

MODO="${1:-auto}"
ESTADO="${2:-}"
AQUI="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
DADOS="/var/local/usbponte"
BK="${DADOS}/backups/bk1"
KO="/mnt/us/koreader"
LISTA="/var/tmp/usbponte_lista.txt"
RUINS="/var/tmp/usbponte_ruins.txt"

echo "restaura.sh ${MODO}: $(date '+%Y-%m-%d %H:%M:%S')"

if [ ! -d "${BK}" ]; then
    echo "sem backup em ${BK}"
    echo "RESTAURADOS=0"
    exit 0
fi

# O backup espelha os caminhos absolutos: bk1/mnt/us/... -> /mnt/us/...
(cd "${BK}" && find . -type f -name '*.lua') | sed 's#^\.##' >"${LISTA}"

# O LuaJIT do próprio KOReader confere se cada arquivo ainda carrega
(cd "${KO}" && ./luajit "${AQUI}/checa.lua" "${MODO}" <"${LISTA}" >"${RUINS}")

n=0
while IFS= read -r arquivo; do
    [ -n "${arquivo}" ] || continue
    [ -f "${BK}${arquivo}" ] || continue
    # Igual ao backup: não há o que restaurar
    if [ -f "${arquivo}" ] && cmp -s "${arquivo}" "${BK}${arquivo}"; then
        continue
    fi
    if [ -f "${arquivo}" ]; then
        cp -p "${arquivo}" "${arquivo}.quebrado" 2>/dev/null
    fi
    mkdir -p "$(dirname "${arquivo}")"
    if cp -p "${BK}${arquivo}" "${arquivo}.ponte_tmp" && mv -f "${arquivo}.ponte_tmp" "${arquivo}"; then
        n=$((n + 1))
        echo "restaurado: ${arquivo}"
        [ -n "${ESTADO}" ] && printf 'restaurado\t%s\n' "${arquivo}" >>"${ESTADO}"
    else
        echo "FALHA ao restaurar: ${arquivo}"
        rm -f "${arquivo}.ponte_tmp"
    fi
done <"${RUINS}"

rm -f "${LISTA}" "${RUINS}"
sync
echo "RESTAURADOS=${n}"
