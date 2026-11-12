#!/bin/sh
#
# Vigia da Ponte USB.
# Roda a partir de /var/tmp/usbponte (memória RAM), nunca de /mnt/us, porque a partição
# de arquivos some enquanto o Kindle está em modo USB.
#
# Etapas:
#   1. espera o KOReader fechar;
#   2. espera o Kindle entrar em modo USB (a partição de arquivos é solta);
#   3. espera o modo USB terminar (ejetar ou puxar o cabo: a partição volta);
#   4. confere a partição, restaura dados de leitura corrompidos e reabre o KOReader.
#
# Modo rápido: o plugin pausou o koreader.sh (SIGSTOP) e fechou o KOReader com o código de
# reinício. Aqui só soltamos o volumd para o modo USB começar; a tela continua na página do
# livro, porque nada do Kindle é redesenhado. Na volta, pausamos o volumd de novo e retomamos
# o koreader.sh, que reabre o KOReader na hora.
#
# Modo compatível: o koreader.sh termina normalmente; mantemos a página na tela por cima do
# Kindle ("tela congelada") e abrimos o koreader.sh de novo no fim.
#

AQUI="/var/tmp/usbponte"
DADOS="/var/local/usbponte"
LOG="${DADOS}/vigia.log"
KO="/mnt/us/koreader"
PIDFILE="${AQUI}/vigia.pid"
CANCELAR="${AQUI}/cancelar"
TELA="${AQUI}/tela.raw"
REGISTRO_VISIVEL="${KO}/usbponte-registro.txt"

mkdir -p "${DADOS}"

MODO="$(cat "${DADOS}/modo" 2>/dev/null)"
LEITOR="$(cat "${DADOS}/leitor" 2>/dev/null)"
PAI="$(cat "${DADOS}/pai" 2>/dev/null)"
if [ "${MODO}" != "rapido" ] || [ -z "${PAI}" ]; then
    MODO="compat"
fi

# Modo escuro do KOReader = inversão de hardware; repete a inversão em tudo que desenhamos
FB_OPC=""
[ "$(cat "${DADOS}/noturno" 2>/dev/null)" = "1" ] && FB_OPC="-H"
# Se o KOReader rodava com o awesome congelado, podemos congelá-lo também (sem tela inicial)
PODE_PARAR_AWESOME="no"
[ "$(cat "${DADOS}/awesome" 2>/dev/null)" = "yes" ] && PODE_PARAR_AWESOME="yes"

AWESOME_PARADO="no"    # compatível: nós congelamos o awesome
PAI_PARADO="no"        # rápido: o koreader.sh está pausado esperando por nós
VOLUMD_RETOMADO="no"   # rápido: soltamos o volumd e precisamos pausá-lo de novo

log() {
    read -r up _ </proc/uptime
    echo "$(date '+%Y-%m-%d %H:%M:%S') t=${up} [vigia] $*" >>"${LOG}"
}

tela() {
    if [ -x "${AQUI}/fbink" ]; then
        # shellcheck disable=SC2086
        "${AQUI}/fbink" -qpm ${FB_OPC} -y -6 "$1" >/dev/null 2>&1
    else
        eips 0 0 "$1" >/dev/null 2>&1
    fi
}

# Modo compatível: redesenha a página guardada antes de fechar o KOReader, com a faixa de
# aviso. Atualização sem piscar: a página é a mesma que já estava na tela.
congelar() {
    if [ -f "${TELA}" ] && [ -x "${AQUI}/fbink" ]; then
        cat "${TELA}" >/dev/fb0 2>/dev/null
        # shellcheck disable=SC2086
        "${AQUI}/fbink" -q -s ${FB_OPC} >/dev/null 2>&1
    fi
    tela "$1"
}

# Estado de um processo (R, S, T = pausado, Z = encerrado esperando o pai; X = não existe)
estado_proc() {
    linha=""
    read -r linha <"/proc/$1/stat" 2>/dev/null || { echo X; return; }
    linha="${linha##*) }"
    echo "${linha%% *}"
}

leitor_ativo() {
    [ -n "${LEITOR}" ] || return 1
    e="$(estado_proc "${LEITOR}")"
    [ "${e}" != "X" ] && [ "${e}" != "Z" ]
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

# Modo rápido: devolve o Kindle ao estado em que o koreader.sh espera encontrá-lo
devolver_ao_koreader() {
    if [ "${VOLUMD_RETOMADO}" = "yes" ]; then
        killall -STOP volumd 2>/dev/null
        VOLUMD_RETOMADO="no"
    fi
    if [ "${PAI_PARADO}" = "yes" ]; then
        kill -CONT "${PAI}" 2>/dev/null
        PAI_PARADO="no"
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
    log "--- diagnóstico (modo ${MODO}, ponto vigiado: ${PONTO}) ---"
    grep -E ' /mnt/(us|base-us) ' /proc/mounts >>"${LOG}" 2>&1
    for d in /sys/class/power_supply/*; do
        [ -d "${d}" ] || continue
        log "${d}: online=$(cat "${d}/online" 2>/dev/null) status=$(cat "${d}/status" 2>/dev/null)"
    done
    ps 2>/dev/null | grep -i -E 'mtp|volumd|usb|awesome|koreader' | grep -v grep >>"${LOG}" 2>&1
    if [ "${MODO}" = "rapido" ]; then
        log "koreader.sh (pid ${PAI}): estado $(estado_proc "${PAI}"), pasta $(readlink "/proc/${PAI}/cwd" 2>/dev/null)"
        ls -l "/proc/${PAI}/fd" >>"${LOG}" 2>&1
    fi
    log "--- fim do diagnóstico ---"
}

# Copia o registro para a área visível pelo PC (koreader/usbponte-registro.txt)
espelhar_registro() {
    [ -d "${KO}" ] && cp -f "${LOG}" "${REGISTRO_VISIVEL}" 2>/dev/null
}

# Modo compatível (e reserva do rápido): abre o koreader.sh de novo
reabrir_compat() {
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
    # O plugin ajustou o KOReader para voltar direto no último livro
    log "reabrindo o KOReader (koreader.sh ${opcoes})"
    espelhar_registro
    sync
    # shellcheck disable=SC2086
    exec sh "${KO}/koreader.sh" ${opcoes}
}

# Modo rápido: retoma o koreader.sh e confere se o KOReader voltou
reabrir_rapido() {
    espelhar_registro
    sync
    devolver_ao_koreader
    log "koreader.sh retomado; o KOReader está abrindo"
    n=0
    while [ ${n} -lt 150 ]; do
        if [ ! -d "/proc/${PAI}" ]; then
            # O koreader.sh terminou em vez de reabrir: usa o jeito antigo daqui para a frente
            log "o koreader.sh terminou em vez de reabrir o KOReader; reabrindo pelo modo compatível"
            echo "1" >"${DADOS}/forcar_compat"
            n=0
            while [ -e /var/tmp/koreader.sh ] && [ ${n} -lt 300 ]; do
                n=$((n + 1))
                usleep 100000
            done
            reabrir_compat
        fi
        for p in $(pidof reader.lua 2>/dev/null); do
            if [ "${p}" != "${LEITOR}" ]; then
                log "KOReader em execução (pid ${p})"
                exit 0
            fi
        done
        n=$((n + 1))
        usleep 100000
    done
    log "o KOReader ainda não apareceu depois de 15 s"
    diagnostico
    exit 0
}

reabrir() {
    if [ "${MODO}" = "rapido" ]; then
        reabrir_rapido
    else
        reabrir_compat
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

[ "${MODO}" = "rapido" ] && PAI_PARADO="yes"
# Em qualquer saída inesperada, devolve o Kindle a um estado utilizável
sair() {
    if [ "${MODO}" = "rapido" ]; then
        devolver_ao_koreader
    else
        soltar_awesome
    fi
    rm -f "${PIDFILE}"
}
trap sair EXIT
trap 'exit 1' TERM INT HUP

log "iniciado (pid $$, modo ${MODO}, ponto vigiado: ${PONTO})"

# --- 1. Espera o KOReader fechar ---------------------------------------------------------
n=0
while :; do
    if [ -f "${CANCELAR}" ]; then
        rm -f "${CANCELAR}"
        log "cancelado pelo plugin"
        exit 0
    fi
    if [ "${MODO}" = "rapido" ]; then
        leitor_ativo || break
    else
        # O koreader.sh roda como /var/tmp/koreader.sh e apaga esse arquivo no fim da limpeza,
        # depois de descongelar o volumd.
        [ -e /var/tmp/koreader.sh ] || pidof reader.lua >/dev/null 2>&1 || break
    fi
    n=$((n + 1))
    if [ ${n} -gt 1200 ]; then
        log "o KOReader não fechou em 2 minutos; desistindo"
        tela "Ponte USB: o KOReader nao fechou. Reinicie o Kindle se travar."
        exit 1
    fi
    usleep 100000
done

if [ "${MODO}" = "rapido" ] && [ "$(estado_proc "${PAI}")" != "T" ]; then
    # O plugin não chegou a pausar o koreader.sh (KOReader fechou de outro jeito)
    log "o koreader.sh não está pausado; seguindo pelo modo compatível"
    MODO="compat"
    PAI_PARADO="no"
    n=0
    while [ -e /var/tmp/koreader.sh ] && [ ${n} -lt 1200 ]; do
        n=$((n + 1))
        usleep 100000
    done
fi
log "KOReader fechado"

if [ "${MODO}" = "rapido" ]; then
    # Se o KOReader soltou o awesome ao sair (aparelhos com ofertas), congela de novo
    [ "${PODE_PARAR_AWESOME}" = "yes" ] && killall -STOP awesome 2>/dev/null
    tela "Ponte USB: aguardando o PC..."
    VP="$(pidof volumd 2>/dev/null)"
    VP="${VP%% *}"
    if [ -n "${VP}" ] && [ "$(estado_proc "${VP}")" = "T" ]; then
        killall -CONT volumd 2>/dev/null
        VOLUMD_RETOMADO="yes"
        log "volumd solto"
    fi
else
    congelar "Ponte USB: aguardando o PC..."
fi

# --- 2. Espera o modo USB começar -------------------------------------------------------
n=0
while particao_ok; do
    n=$((n + 1))
    if [ ${n} -eq 75 ]; then
        log "modo USB ainda não começou após 15 s"
        diagnostico
        tela "Ponte USB: se o PC nao reconhecer, desconecte e conecte o cabo de novo"
    fi
    if [ ${n} -gt 450 ]; then
        log "modo USB não começou em 90 s; voltando ao livro"
        diagnostico
        echo "usb_nao_iniciou" >>"${DADOS}/estado"
        tela "Ponte USB: o PC nao reconheceu o Kindle. Voltando ao livro..."
        reabrir
    fi
    usleep 200000
done
log "modo USB ativo (${PONTO} solto)"

if [ "${MODO}" = "rapido" ]; then
    tela "Modo USB: copie os arquivos e ejete no PC antes de desconectar"
else
    parar_awesome
    congelar "Modo USB: copie os arquivos e ejete no PC antes de desconectar"
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
fi

# --- 3. Espera o modo USB terminar (ejetado ou cabo puxado) ----------------------------
n=0
while ! particao_ok; do
    n=$((n + 1))
    # Limite de segurança no modo compatível: 12 horas. No rápido o koreader.sh está pausado
    # esperando por nós, então o vigia espera o tempo que for preciso.
    if [ "${MODO}" = "compat" ] && [ ${n} -gt 86400 ]; then
        log "modo USB durou mais de 12 h; vigia encerrado sem reabrir o KOReader"
        exit 0
    fi
    usleep 500000
done
log "modo USB terminou (${PONTO} montado de novo)"
if [ "${MODO}" = "rapido" ] || [ "${AWESOME_PARADO}" = "yes" ]; then
    # A página continua na tela; só troca a faixa de aviso
    tela "Ponte USB: voltando ao livro..."
else
    congelar "Ponte USB: voltando ao livro..."
fi

# Espera a partição aceitar escrita (normalmente é imediato; no máximo 5 s)
n=0
until touch /mnt/us/.usbponte_teste 2>/dev/null && rm -f /mnt/us/.usbponte_teste; do
    n=$((n + 1))
    [ ${n} -ge 25 ] && break
    usleep 200000
done

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
if [ "${MODO}" = "rapido" ]; then
    # Dá um instante para o volumd terminar de remontar antes de pausá-lo de novo
    usleep 200000
fi

# --- 5. Reabre o KOReader no mesmo livro -----------------------------------------------
reabrir
