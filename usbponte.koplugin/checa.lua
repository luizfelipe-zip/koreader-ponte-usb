-- Lê caminhos de arquivos de dados do KOReader (um por linha) e imprime os que precisam
-- ser restaurados do backup. Roda com o LuaJIT do KOReader, fora do KOReader.
--   modo "auto":     corrompidos (vazios ou que não carregam) + settings.reader.lua ausente
--   modo "faltando": o mesmo + progresso ausente de livros que ainda existem

local modo = arg[1] or "auto"

-- true = válido, false = corrompido, nil = não existe
-- Só confere se o arquivo está inteiro (vazio ou cortado no meio não compila). Não executa o
-- arquivo: plugins de terceiros guardam dados em Lua de formatos variados, e executá-los
-- gerava falsos "corrompidos".
local function estado(caminho)
    local f = io.open(caminho, "rb")
    if not f then return nil end
    local tamanho = f:seek("end")
    f:close()
    if tamanho == 0 then return false end
    return loadfile(caminho) ~= nil
end

-- metadata.<ext>.lua dentro de <livro sem extensão>.sdr -> caminho do livro
local function livroExiste(caminho)
    local sdr, ext = caminho:match("^(.*)%.sdr/metadata%.(.+)%.lua$")
    if not sdr then return false end
    local livro = (sdr .. "." .. ext):gsub("^/mnt/us/koreader/docsettings", "")
    local f = io.open(livro, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

for caminho in io.lines() do
    local e = estado(caminho)
    if e == false then
        print(caminho)
    elseif e == nil then
        if caminho:match("/settings%.reader%.lua$") then
            print(caminho)
        elseif modo == "faltando" and livroExiste(caminho) then
            print(caminho)
        end
    end
end
