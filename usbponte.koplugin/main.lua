--[[--
Ponte USB para Kindle.

No Kindle, o koreader.sh congela o volumd (SIGSTOP) enquanto o KOReader roda, porque o
KOReader vive dentro da própria partição que o modo USB entrega ao PC (/mnt/us). Por isso,
ao plugar o cabo, o Kindle só carrega.

Este plugin faz a ponte:
  1. ao plugar o cabo (ou pelo menu/gesto), salva tudo, faz backup dos dados de leitura e
     tira uma "foto" da lista de livros;
  2. dispara um vigia (vigia.sh) que roda fora de /mnt/us e fecha o KOReader; o koreader.sh
     então descongela o volumd e o Kindle entra no modo USB normal;
  3. quando o PC ejeta ou o cabo é puxado, o vigia confere a partição, restaura dados de
     leitura corrompidos e reabre o KOReader no mesmo livro;
  4. ao reabrir, este plugin confere os livros novos/alterados e move os incompletos para
     /mnt/us/_incompletos (nada é apagado).

@module koplugin.UsbPonte
--]]

local Device = require("device")

if not Device:isKindle() then
    return { disabled = true, }
end

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local US = "/mnt/us"
local KO = US .. "/koreader"
local DADOS = "/var/local/usbponte"      -- fora de /mnt/us: o PC não enxerga
local TMP = "/var/tmp/usbponte"          -- tmpfs: o vigia roda daqui
local QUARENTENA = US .. "/_incompletos"

local BACKUPS_MANTIDOS = 3
local BACKUP_MAX_KB = 20 * 1024          -- nunca ocupar mais que isso por backup
local FOLGA_MINIMA_KB = 10 * 1024        -- espaço que sempre sobra em /var/local
local ARQUIVO_SETTINGS_MAX_KB = 8 * 1024

-- Pastas da raiz de /mnt/us que não têm livros
local PULAR_NA_RAIZ = {
    ["system"] = true,
    ["extensions"] = true,
    ["$RECYCLE.BIN"] = true,
    ["System Volume Information"] = true,
    [".Trashes"] = true,
    ["_incompletos"] = true,
}
-- Dentro de /mnt/us/koreader só interessam as pastas de dados de leitura
local KO_COM_METADADOS = { "docsettings", "hashdocsettings" }

local EXT_ZIP = { epub = true, kepub = true, cbz = true, zip = true, fbz = true,
                  docx = true, odt = true, xps = true, oxps = true }
local EXT_PALM = { mobi = true, azw = true, azw3 = true, prc = true, pdb = true }
local EXT_DJVU = { djvu = true, djv = true }
local EXT_LIVRO = { pdf = true, fb2 = true, txt = true, rtf = true, doc = true, cbr = true,
                    cb7 = true, chm = true, html = true, htm = true, md = true, kfx = true }
for _, t in ipairs({ EXT_ZIP, EXT_PALM, EXT_DJVU }) do
    for k in pairs(t) do EXT_LIVRO[k] = true end
end

-- Estado compartilhado entre as instâncias do plugin (leitor e gerenciador de arquivos)
local dialogo_usb = nil
local verificacao_feita = false
local entrando = false

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function existe(caminho)
    return lfs.attributes(caminho, "mode") ~= nil
end

local function escrever(caminho, conteudo)
    local f = io.open(caminho, "wb")
    if not f then return false end
    f:write(conteudo)
    f:close()
    return true
end

local function ler(caminho)
    local f = io.open(caminho, "rb")
    if not f then return nil end
    local conteudo = f:read("*a")
    f:close()
    return conteudo
end

local function log(msg)
    logger.info("UsbPonte:", msg)
    local f = io.open(DADOS .. "/vigia.log", "ab")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S"), " [plugin] ", msg, "\n")
        f:close()
    end
end

local function copiar(origem, destino)
    local fi = io.open(origem, "rb")
    if not fi then return false end
    local fo = io.open(destino, "wb")
    if not fo then
        fi:close()
        return false
    end
    while true do
        local bloco = fi:read(65536)
        if not bloco then break end
        fo:write(bloco)
    end
    fi:close()
    fo:close()
    return true
end

local function extensao(nome)
    local ext = nome:match("%.([^%.]+)$")
    return ext and ext:lower()
end

local function espacoLivreKB(dir)
    local p = io.popen("df -k " .. shq(dir) .. " 2>/dev/null")
    if not p then return nil end
    local saida = p:read("*a")
    p:close()
    -- O campo "disponível" vem logo antes da porcentagem de uso (ex.: "12%")
    local tokens = {}
    for t in saida:gmatch("%S+") do table.insert(tokens, t) end
    for i, t in ipairs(tokens) do
        if t:match("^%d+%%$") and i > 1 then
            return tonumber(tokens[i - 1])
        end
    end
    return nil
end

--- Percorre /mnt/us e devolve a lista de livros (para a foto) e de arquivos de metadados (.sdr).
local function varrer()
    local livros, metadados = {}, {}
    local function visitar(dir, profundidade)
        if profundidade > 12 then return end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return end
        local dentro_sdr = dir:match("%.sdr$") ~= nil
        for nome in iter, obj do
            if nome ~= "." and nome ~= ".." and nome:sub(1, 2) ~= "._" then
                local caminho = dir .. "/" .. nome
                local attr = lfs.attributes(caminho)
                if attr and attr.mode == "directory" then
                    if dir == US and nome == "koreader" then
                        for _, sub in ipairs(KO_COM_METADADOS) do
                            visitar(caminho .. "/" .. sub, profundidade + 1)
                        end
                    elseif not (dir == US and PULAR_NA_RAIZ[nome]) then
                        visitar(caminho, profundidade + 1)
                    end
                elseif attr and attr.mode == "file" then
                    if dentro_sdr then
                        if nome:match("^metadata%..+%.lua$") then
                            table.insert(metadados, { caminho = caminho, tamanho = attr.size })
                        end
                    elseif EXT_LIVRO[extensao(nome) or ""] then
                        livros[caminho] = attr.size .. "\t" .. attr.modification
                    end
                end
            end
        end
    end
    visitar(US, 0)
    return livros, metadados
end

local function salvarFoto(livros)
    local f = io.open(DADOS .. "/antes.txt", "wb")
    if not f then return false end
    for caminho, info in pairs(livros) do
        f:write(info, "\t", caminho, "\n")
    end
    f:close()
    return true
end

local function lerFoto()
    local foto = {}
    local f = io.open(DADOS .. "/antes.txt", "rb")
    if not f then return nil end
    for linha in f:lines() do
        local tamanho, mtime, caminho = linha:match("^(%d+)\t(%d+)\t(.+)$")
        if caminho then foto[caminho] = tamanho .. "\t" .. mtime end
    end
    f:close()
    return foto
end

--- Copia configurações e metadados de leitura para /var/local/usbponte/backups/bk1 (gira bk1..bk3).
local function fazerBackup(metadados)
    local arquivos = {}
    local total_kb = 0
    local function incluir(caminho, tamanho)
        table.insert(arquivos, caminho)
        total_kb = total_kb + math.ceil((tamanho or 0) / 1024)
    end

    for _, nome in ipairs({ "settings.reader.lua", "settings.reader.lua.old" }) do
        local tamanho = lfs.attributes(KO .. "/" .. nome, "size")
        if tamanho then incluir(KO .. "/" .. nome, tamanho) end
    end
    local ok, iter, obj = pcall(lfs.dir, KO .. "/settings")
    if ok then
        for nome in iter, obj do
            local caminho = KO .. "/settings/" .. nome
            local attr = lfs.attributes(caminho)
            if attr and attr.mode == "file" and not nome:match("^bookinfo_cache")
                    and attr.size <= ARQUIVO_SETTINGS_MAX_KB * 1024 then
                incluir(caminho, attr.size)
            end
        end
    end
    for _, m in ipairs(metadados) do
        incluir(m.caminho, m.tamanho)
    end

    if total_kb > BACKUP_MAX_KB then
        return false, string.format("backup grande demais (%d KB)", total_kb)
    end
    local livre = espacoLivreKB("/var/local")
    if not livre or livre < total_kb + FOLGA_MINIMA_KB then
        return false, string.format("pouco espaço em /var/local (%s KB livres, precisa de %d KB)",
            tostring(livre), total_kb + FOLGA_MINIMA_KB)
    end

    local pasta = DADOS .. "/backups"
    local novo = pasta .. "/novo"
    os.execute("rm -rf " .. shq(novo))
    util.makePath(novo)
    local falhas = 0
    for _, caminho in ipairs(arquivos) do
        local destino = novo .. caminho
        util.makePath(destino:match("^(.*)/"))
        if not copiar(caminho, destino) then falhas = falhas + 1 end
    end
    -- Só gira os backups antigos depois que o novo ficou pronto
    os.execute("rm -rf " .. shq(pasta .. "/bk" .. BACKUPS_MANTIDOS))
    for i = BACKUPS_MANTIDOS - 1, 1, -1 do
        os.rename(pasta .. "/bk" .. i, pasta .. "/bk" .. (i + 1))
    end
    os.rename(novo, pasta .. "/bk1")
    return true, string.format("%d arquivos, %d KB, %d falhas", #arquivos, total_kb, falhas)
end

--- Confere se um livro parece completo (detecta cópias interrompidas).
local function checarLivro(caminho, tamanho)
    local ext = extensao(caminho) or ""
    if tamanho == 0 then return false, "arquivo vazio (0 bytes)" end
    local f = io.open(caminho, "rb")
    if not f then return false, "não abre" end
    local function fim(n)
        f:seek("set", math.max(0, tamanho - n))
        return f:read(n) or ""
    end
    local function u32be(s)
        local a, b, c, d = s:byte(1, 4)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end

    local ok, motivo = true, nil
    if EXT_ZIP[ext] then
        if f:read(4) ~= "PK\3\4" then
            ok, motivo = false, "não é um ZIP válido"
        elseif not fim(65557):find("PK\5\6", 1, true) then
            ok, motivo = false, "ZIP sem o final (cópia incompleta)"
        end
    elseif ext == "pdf" then
        if not (f:read(1024) or ""):find("%PDF", 1, true) then
            ok, motivo = false, "não é um PDF válido"
        elseif not fim(4096):find("%%EOF", 1, true) then
            ok, motivo = false, "PDF sem o final (cópia incompleta)"
        end
    elseif EXT_PALM[ext] then
        f:seek("set", 60)
        local tipo = f:read(8)
        f:seek("set", 76)
        local n = f:read(2)
        if (tipo ~= "BOOKMOBI" and tipo ~= "TEXtREAd") or not n or #n < 2 then
            ok, motivo = false, "cabeçalho MOBI/AZW inválido"
        else
            local registros = n:byte(1) * 256 + n:byte(2)
            f:seek("set", 78 + (registros - 1) * 8)
            local off = f:read(4)
            if registros == 0 or not off or #off < 4 or u32be(off) >= tamanho then
                ok, motivo = false, "MOBI/AZW cortado (cópia incompleta)"
            end
        end
    elseif EXT_DJVU[ext] then
        local cab = f:read(12) or ""
        if cab:sub(1, 8) ~= "AT&TFORM" then
            ok, motivo = false, "não é um DJVU válido"
        elseif 12 + u32be(cab:sub(9, 12)) > tamanho + 1 then
            ok, motivo = false, "DJVU cortado (cópia incompleta)"
        end
    elseif ext == "fb2" then
        if not fim(1024):find("</FictionBook>", 1, true) then
            ok, motivo = false, "FB2 sem o final (cópia incompleta)"
        end
    end
    f:close()
    return ok, motivo
end

local function moverParaQuarentena(caminho)
    util.makePath(QUARENTENA)
    local nome = caminho:match("([^/]+)$")
    local destino = QUARENTENA .. "/" .. nome
    local i = 1
    while existe(destino) do
        local base, ext = nome:match("^(.*)(%.[^%.]+)$")
        destino = string.format("%s/%s (%d)%s", QUARENTENA, base or nome, i, ext or "")
        i = i + 1
    end
    local ok = os.rename(caminho, destino)
    return ok and destino or nil
end

local function prepararVigia(pasta_plugin)
    util.makePath(DADOS)
    util.makePath(TMP)
    for _, nome in ipairs({ "vigia.sh", "restaura.sh", "checa.lua" }) do
        if not copiar(pasta_plugin .. "/" .. nome, TMP .. "/" .. nome) then
            return false, "não consegui copiar " .. nome .. " para " .. TMP
        end
    end
    -- O koreader.sh apaga /var/tmp/fbink ao sair; o vigia usa a própria cópia para escrever na tela
    if not copiar("/var/tmp/fbink", TMP .. "/fbink") then
        copiar(KO .. "/fbink", TMP .. "/fbink")
    end
    os.execute("chmod 755 " .. TMP .. "/* 2>/dev/null")
    return true
end

local function lancarVigia()
    -- setsid + env -i: o vigia sobrevive ao fechamento do KOReader e não herda o ambiente dele
    local cmd = "if command -v setsid >/dev/null 2>&1; then S=setsid; else S=; fi; "
        .. "cd / && env -i PATH=\"$PATH\" $S sh " .. TMP .. "/vigia.sh </dev/null >/dev/null 2>&1 &"
    return os.execute(cmd)
end

local UsbPonte = WidgetContainer:extend{
    name = "usbponte",
    is_doc_only = false,
}

function UsbPonte:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if not verificacao_feita then
        verificacao_feita = true
        UIManager:scheduleIn(1.5, function() self:verificarAposUsb() end)
    end
end

function UsbPonte:onDispatcherRegisterActions()
    Dispatcher:registerAction("usbponte_modo_usb", {
        category = "none", event = "UsbPonteModoUsb", title = _("Ponte USB: entrar em modo USB"), general = true,
    })
end

function UsbPonte:perguntarAoConectar()
    return G_reader_settings:nilOrTrue("usbponte_perguntar")
end

function UsbPonte:addToMainMenu(menu_items)
    menu_items.usbponte = {
        text = _("Ponte USB"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Entrar em modo USB agora"),
                callback = function()
                    -- Dá tempo do menu sumir da tela antes de guardar a página
                    UIManager:scheduleIn(0.5, function() self:entrarModoUsb() end)
                end,
            },
            {
                text = _("Perguntar ao conectar o cabo"),
                checked_func = function() return self:perguntarAoConectar() end,
                callback = function()
                    G_reader_settings:saveSetting("usbponte_perguntar", not self:perguntarAoConectar())
                end,
                separator = true,
            },
            {
                text = _("Restaurar progresso que sumiu (último backup)"),
                callback = function() self:restaurarFaltando() end,
            },
            {
                text = _("Ver registro"),
                callback = function()
                    local TextViewer = require("ui/widget/textviewer")
                    local texto = ler(DADOS .. "/vigia.log") or _("Registro vazio.")
                    if #texto > 30000 then texto = texto:sub(-30000) end
                    UIManager:show(TextViewer:new{ title = _("Ponte USB: registro"), text = texto })
                end,
            },
        },
    }
end

function UsbPonte:onCharging()
    if not self:perguntarAoConectar() or dialogo_usb or entrando then return end
    dialogo_usb = ConfirmBox:new{
        text = _("Cabo USB conectado.\n\nEntrar em modo USB para copiar arquivos?\n\nO KOReader fecha agora e reabre sozinho quando você ejetar ou desconectar o cabo."),
        ok_text = _("Modo USB"),
        cancel_text = _("Só carregar"),
        ok_callback = function()
            -- Fecha o diálogo antes, para a "tela congelada" guardar só a página do livro
            local d = dialogo_usb
            dialogo_usb = nil
            UIManager:close(d)
            UIManager:scheduleIn(0.3, function() self:entrarModoUsb() end)
        end,
        cancel_callback = function()
            dialogo_usb = nil
        end,
    }
    UIManager:show(dialogo_usb)
end

function UsbPonte:onNotCharging()
    if dialogo_usb then
        UIManager:close(dialogo_usb)
        dialogo_usb = nil
    end
end

function UsbPonte:onUsbPonteModoUsb()
    self:entrarModoUsb()
    return true
end

function UsbPonte:entrarModoUsb()
    if entrando then return end
    entrando = true

    local ok, erro = prepararVigia(self.path)
    if not ok then
        entrando = false
        log("falha ao preparar o vigia: " .. tostring(erro))
        UIManager:show(InfoMessage:new{ text = _("Ponte USB: não foi possível preparar o modo USB.\n\n") .. tostring(erro) })
        return
    end

    -- Guarda a página atual: o vigia a mantém na tela durante o modo USB ("tela congelada")
    UIManager:forceRePaint()
    os.execute("cat /dev/fb0 > " .. TMP .. "/tela.raw 2>/dev/null")

    UIManager:show(InfoMessage:new{ text = _("Ponte USB: salvando e fazendo backup…"), timeout = 30 })
    UIManager:forceRePaint()

    local livro = self.ui and self.ui.document and self.ui.document.file
    -- Mesma sequência do modo USB oficial do KOReader (Kobo): grava tudo e fecha o documento
    UIManager:flushSettings()
    UIManager:broadcastEvent(Event:new("Close"))

    local livros, metadados = varrer()
    local ok_bk, resumo_bk = fazerBackup(metadados)
    log("backup " .. (ok_bk and "ok: " or "PULADO: ") .. tostring(resumo_bk))
    if salvarFoto(livros) then
        escrever(DADOS .. "/verificar", os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    end
    escrever(DADOS .. "/ultimo_livro", livro or "")
    escrever(DADOS .. "/opcoes", os.getenv("STOP_FRAMEWORK") == "yes" and "--framework_stop" or "")
    -- Modo escuro por inversão de hardware: a imagem guardada é clara, o vigia pede a inversão
    local noturno = Device.screen.getHWNightmode and Device.screen:getHWNightmode()
    escrever(DADOS .. "/noturno", noturno and "1" or "")
    -- O koreader.sh congela o gerenciador de janelas (awesome) enquanto o KOReader roda;
    -- nesse caso o vigia também pode congelá-lo para o Kindle não redesenhar a tela inicial
    escrever(DADOS .. "/awesome", os.getenv("AWESOME_STOPPED") or "")
    os.remove(DADOS .. "/estado")
    os.execute("sync")

    log("fechando o KOReader para o modo USB" .. (livro and (" (livro: " .. livro .. ")") or ""))
    lancarVigia()
    UIManager:quit(0)
end

function UsbPonte:restaurarFaltando()
    local p = io.popen("sh " .. shq(self.path .. "/restaura.sh") .. " faltando 2>&1")
    local saida = p and p:read("*a") or ""
    if p then p:close() end
    local n = tonumber(saida:match("RESTAURADOS=(%d+)")) or 0
    local texto
    if n == 0 then
        texto = _("Ponte USB: nenhum dado de leitura precisou ser restaurado.")
    else
        texto = string.format(_("Ponte USB: %d arquivo(s) de progresso restaurado(s).\n\nReinicie o KOReader para carregar os dados restaurados."), n)
    end
    UIManager:show(InfoMessage:new{ text = texto })
end

function UsbPonte:verificarAposUsb()
    -- Deixa o registro legível pelo PC em koreader/usbponte-registro.txt
    if existe(DADOS .. "/vigia.log") then
        copiar(DADOS .. "/vigia.log", KO .. "/usbponte-registro.txt")
    end
    if not existe(DADOS .. "/verificar") then return end
    local antes = lerFoto() or {}
    local agora = varrer()
    local aberto = self.ui and self.ui.document and self.ui.document.file

    local verificados, problemas = 0, {}
    for caminho, info in pairs(agora) do
        if antes[caminho] ~= info then
            verificados = verificados + 1
            local tamanho = tonumber(info:match("^(%d+)")) or 0
            local ok, motivo = checarLivro(caminho, tamanho)
            if not ok then
                local nome = caminho:match("([^/]+)$")
                local destino = (caminho ~= aberto) and moverParaQuarentena(caminho) or nil
                log(string.format("incompleto: %s (%s)%s", caminho, motivo,
                    destino and (" -> " .. destino) or " [mantido no lugar]"))
                table.insert(problemas, string.format("• %s\n  %s%s", nome, motivo,
                    destino and "" or _(" (não foi movido)")))
            end
        end
    end

    local avisos = {}
    local estado = ler(DADOS .. "/estado") or ""
    if estado:find("somente_leitura", 1, true) then
        table.insert(avisos, _("⚠ A memória do Kindle voltou em modo somente leitura. Conecte de novo no PC, deixe o Windows verificar e corrigir a unidade e ejete antes de desconectar."))
    end
    if estado:find("usb_nao_iniciou", 1, true) then
        table.insert(avisos, _("O PC não reconheceu o Kindle a tempo, então a ponte voltou ao livro. Tente de novo: conecte o cabo e escolha \"Modo USB\"."))
    end
    local restaurados = 0
    for _ in estado:gmatch("restaurado\t[^\n]+") do restaurados = restaurados + 1 end
    if restaurados > 0 then
        table.insert(avisos, string.format(_("%d arquivo(s) de progresso estavam corrompidos e foram restaurados do backup."), restaurados))
    end
    if #problemas > 0 then
        table.insert(avisos, string.format(_("%d arquivo(s) parecem cópias incompletas e foram movidos para a pasta _incompletos (exceto o livro aberto). Copie-os de novo:\n\n%s"),
            #problemas, table.concat(problemas, "\n")))
    end

    os.remove(DADOS .. "/verificar")
    os.remove(DADOS .. "/estado")
    log(string.format("verificação: %d livro(s) novos/alterados, %d incompleto(s), %d restaurado(s)",
        verificados, #problemas, restaurados))

    if #avisos > 0 then
        UIManager:show(InfoMessage:new{ text = _("Ponte USB\n\n") .. table.concat(avisos, "\n\n") })
    else
        UIManager:show(InfoMessage:new{
            text = verificados > 0
                and string.format(_("Ponte USB: %d livro(s) novo(s) ou alterado(s) conferido(s). Tudo certo."), verificados)
                or _("Ponte USB: tudo certo."),
            timeout = 3,
        })
    end
end

return UsbPonte
