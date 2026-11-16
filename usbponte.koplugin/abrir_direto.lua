-- Ponte USB: ao voltar do modo USB, abre o livro direto, sem o aviso "Opening file".
--
-- O vigia da Ponte USB copia este arquivo para koreader/patches/ só na volta do modo USB,
-- e o plugin o apaga assim que o KOReader abre. Se ele ficar aqui por algum motivo, não faz
-- nada: só age quando a Ponte USB acabou de sair do modo USB.

local lfs = require("libs/libkoreader-lfs")
if lfs.attributes("/var/local/usbponte/verificar", "mode") ~= "file" then
    return
end

local ReaderUI = require("apps/reader/readerui")
local showReader_original = ReaderUI.showReader
ReaderUI.showReader = function(self, file, provider, seamless, ...)
    -- Só a primeira abertura (a da volta do modo USB) é feita sem aviso
    ReaderUI.showReader = showReader_original
    return showReader_original(self, file, provider, true, ...)
end
