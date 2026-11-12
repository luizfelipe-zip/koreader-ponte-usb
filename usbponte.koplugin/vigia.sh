#!/bin/sh
#
# Vigia da Ponte USB.
# Roda a partir de /var/tmp/usbponte (memória RAM), nunca de /mnt/us, porque a partição
# de arquivos some enquanto o Kindle está em modo USB.
#
# Etapas:
#   1. espera o KOReader terminar de fechar (o koreader.sh descongela o volumd ao sair);
#   2. espera o Kindle entrar em modo USB (a partição de arquivos é solta);
#   3. espera o modo USB terminar (ejetar ou puxar o cabo: a partição volta);
#   4. confere a partição, restaura dados de leitura corrompidos e reabre o KOReader.
# Enquanto isso, mantém na tela a página em que o livro estava ("tela congelada").
#

AQUI="/var/tmp/usbponte"
DADOS="/var/local/usbponte"
LOG="${DADOS}/vigia.log"
KO="/mnt/us/koreader"
PIDFILE="${AQUI}/vigia.pid"
TELA="${AQUI}/tela.raw"
REGISTRO_VISIVEL="${KO}/usbponte-registro.txt"

mkdir -p "${DADOS}"

# Modo escuro do KOReader = inversão de hardware; repete a inversão em tudo que desenhamos
FB_OPC=""
[ "$(cat "${DADOS}/noturno" 2>/dev/null)" = "1" ] && FB_OPC="-H"
# Se o KOReader rodava com o awesome congelado, podemos congelá-lo também (sem tela inicial)
PODE_PARAR_AWESOME="no"
[ "$(cat "${DADOS}/awesome" 2>/dev/null)" = "yes" ] && PODE_PARAR_AWESOME="yes"
AWESOME_PARADO="no"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [vigia] $*" >>"${LOG}"
}

tela() {
    if [ -x "${AQUI}/fbink" ]; then
        # shellcheck disable=SC2086
        "${AQUI}/fbink" -qpm ${FB_OPC} -y -6 "$1" >/dev/null 2>&1
    else
        eips 0 0 "$1" >/dev/null 2>&1
    fi
}

# Redesenha a página do livro guardada antes de fechar o KOReader, com uma faixa de aviso
congelar() {
    if [ -f "${TELA}" ] && [ -x "${AQUI}/fbink" ]; then
        cat "${TELA}" >/dev/fb0 2>/dev/null
        # shellcheck disable=SC2086
        "${AQUI}/fbink" -q -s -f ${FB_OPC} >/dev/null 2>&1
    fi
    tela "$1"
}

# Congela o gerenciador de janelas do Kindle: assim o sistema não redesenha a própria tela
# (tela de USB, tela inicial) por cima da nossa. O koreader.sh faz o mesmo enquanto roda.
parar_awesome() {
    if [ "${PODE_PARAR_AWESOME}" = "yes" ] && [ "${AWESOME_PARADO}" = "no" ]; then
        killall -STOP awesome 2>/dev/null && AWESOME_PARADO="yes" && log "awesome congelado"
    fi
}

soltar_awesome() {
    if [ "${AWESOME_PARADO}" = "yes" ]; then
        killall -CONT awesome 2>/dev/null
        AWESOME_PARADO="no"
        log "awesome liberado"
    fi
}

# No FW 5.x a partição real é /mnt/base-us (vfat) e /mnt/us é uma camada por cima.
# No modo USB o sistema solta a partição real; /mnt/us pode continuar "montado", mas vazio.
if grep -q ' /mnt/base-us ' /proc/mounts; then
    PONTO="/mnt/base-us"
else
    PONTO="/mnt/us"
fi

particao_ok() {
    grep -q " ${PONTO} " /proc/mounts && [ -f "${KO}/koreader.sh" ]
}

diagnostico() {
    log "--- diagnóstico (ponto vigiado: ${PONTO}) ---"
    grep -E ' /mnt/(us|base-us) ' /proc/mounts >>"${LOG}" 2>&1
    for d in /sys/class/power_supply/*; do
        [ -d "${d}" ] || continue
        log "${d}: online=$(cat "${d}/online" 2>/dev/null) status=$(cat "${d}/status" 2>/dev/null)"
    done
    ps 2>/dev/null | grep -i -E 'mtp|volumd|usb' | grep -v grep >>"${LOG}" 2>&1
    log "--- fim do diagnóstico ---"
}

# Copia o registro para a área visível pelo PC (koreader/usbponte-registro.txt)
espelhar_registro() {
    [ -d "${KO}" ] && cp -f "${LOG}" "${REGISTRO_VISIVEL}" 2>/dev/null
}

reabrir() {
    livro="$(cat "${DADOS}/ultimo_livro" 2>/dev/null)"
    opcoes="$(cat "${DADOS}/opcoes" 2>/dev/null)"
    rm -f "${PIDFILE}"
    cd / || exit 1
    if [ ! -f "${KO}/koreader.sh" ]; then
        log "koreader.sh sumiu; não dá para reabrir"
        exit 1
    fi
    # Daqui em diante o koreader.sh assume o awesome (congela de novo e libera ao sair)
    trap - EXIT
    if [ "${AWESOME_PARADO}" = "yes" ]; then
        # Rede de segurança: se o KOReader não subir em 60 s, devolve a tela ao sistema
        (
            sleep 60
            if ! pidof reader.lua >/dev/null 2>&1; then
                killall -CONT awesome 2>/dev/null
                echo "$(date '+%Y-%m-%d %H:%M:%S') [vigia] KOReader não subiu em 60 s; awesome liberado" >>"${LOG}"
            fi
        ) </dev/null >/dev/null 2>&1 &
    fi
    if [ -n "${livro}" ] && [ -f "${livro}" ]; then
        log "reabrindo o KOReader em: ${livro}"
        espelhar_registro
        sync
        # shellcheck disable=SC2086
        exec sh "${KO}/koreader.sh" ${opcoes} "${livro}"
    else
        log "reabrindo o KOReader"
        espelhar_registro
        sync
        # shellcheck disable=SC2086
        exec sh "${KO}/koreader.sh" ${opcoes}
    fi
}

# Mantém o registro pequeno (últimos ~200 KB)
if [ -f "${LOG}" ] && [ "$(wc -c <"${LOG}")" -gt 300000 ]; then
    tail -c 200000 "${LOG}" >"${LOG}.novo" && mv -f "${LOG}.novo" "${LOG}"
fi

# Só um vigia por vez
if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    log "já existe um vigia rodando; saindo"
    exit 0
fi
echo $$ >"${PIDFILE}"
# Em qualquer saída que não seja reabrir o KOReader, devolve a tela ao sistema do Kindle
trap 'soltar_awesome; rm -f "${PIDFILE}"' EXIT

log "iniciado (pid $$, ponto vigiado: ${PONTO})"
diagnostico

# --- 1. Espera o KOReader fechar por completo -------------------------------------------
# O koreader.sh roda como /var/tmp/koreader.sh e apaga esse arquivo no fim da limpeza,
# depois de descongelar o volumd.
n=0
while [ -e /var/tmp/koreader.sh ] || pidof reader.lua >/dev/null 2>&1; do
    n=$((n + 1))
    if [ ${n} -gt 240 ]; then
        log "o KOReader não fechou em 2 minutos; desistindo"
        tela "Ponte USB: o KOReader nao fechou. Reinicie o Kindle se travar."
        exit 1
    fi
    usleep 500000
done
log "KOReader fechado"
congelar "Ponte USB: aguardando o PC..."

# --- 2. Espera o modo USB começar -----------------------------------------------------
n=0
while particao_ok; do
    n=$((n + 1))
    if [ ${n} -eq 30 ]; then
        log "modo USB ainda não começou após 15 s"
        congelar "Ponte USB: se o PC nao reconhecer, desconecte e conecte o cabo de novo"
    fi
    if [ ${n} -gt 180 ]; then
        log "modo USB não começou em 90 s; voltando ao livro"
        diagnostico
        echo "usb_nao_iniciou" >>"${DADOS}/estado"
        congelar "Ponte USB: o PC nao reconheceu o Kindle. Voltando ao livro..."
        reabrir
    fi
    usleep 500000
done
log "modo USB ativo (${PONTO} solto)"
parar_awesome
congelar "Modo USB: copie os arquivos e ejete no PC antes de desconectar"
diagnostico
if [ "${AWESOME_PARADO}" = "no" ]; then
    # Sem poder congelar o awesome, o sistema desenha a própria tela de USB; redesenha por cima
    (
        for espera in 1 3 6 10; do
            sleep "${espera}"
            particao_ok && break
            congelar "Modo USB: copie os arquivos e ejete no PC antes de desconectar"
        done
    ) &
fi

# --- 3. Espera o modo USB terminar (ejetado ou cabo puxado) ----------------------------
n=0
while ! particao_ok; do
    n=$((n + 1))
    # Limite de segurança: 12 horas
    if [ ${n} -gt 43200 ]; then
        log "modo USB durou mais de 12 h; vigia encerrado sem reabrir o KOReader"
        exit 0
    fi
    sleep 1
done
log "modo USB terminou (${PONTO} montado de novo)"
if [ "${AWESOME_PARADO}" = "yes" ]; then
    # A página continua na tela; só troca a faixa de aviso
    tela "Ponte USB: conferindo os arquivos e voltando ao livro..."
else
    congelar "Ponte USB: conferindo os arquivos e voltando ao livro..."
fi
sleep 3

# --- 4. Conferências de segurança ------------------------------------------------------
opcoes_montagem="$(grep " ${PONTO} " /proc/mounts | awk '{print $4}')"
if echo "${opcoes_montagem}" | grep -q -E '(^|,)ro(,|$)' \
    || ! { touch /mnt/us/.usbponte_teste 2>/dev/null && rm -f /mnt/us/.usbponte_teste; }; then
    log "ATENÇÃO: a partição voltou somente leitura (${opcoes_montagem})"
    echo "somente_leitura" >>"${DADOS}/estado"
    tela "Ponte USB: memoria em modo somente leitura! Veja o aviso no KOReader."
else
    sh "${AQUI}/restaura.sh" auto "${DADOS}/estado" >>"${LOG}" 2>&1
fi
sync

# --- 5. Reabre o KOReader no mesmo livro -----------------------------------------------
reabrir
