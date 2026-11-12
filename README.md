# Ponte USB para KOReader no Kindle

Plugin do [KOReader](https://github.com/koreader/koreader) que deixa o Kindle entrar em **modo USB** (para copiar arquivos pelo PC) sem precisar sair do KOReader na mão, e que **volta sozinho para o livro** quando você ejeta ou desconecta o cabo.

> 🇬🇧 *English summary at the end.*

## O problema

No Kindle, enquanto o KOReader está aberto, o `koreader.sh` congela o serviço que cuida do modo USB (`volumd`). Isso acontece porque o próprio KOReader fica dentro da partição que o Kindle entrega ao PC (`/mnt/us`). Resultado: você pluga o cabo e o Kindle **só carrega**. Para copiar livros, é preciso fechar o KOReader, esperar a tela do Kindle, copiar, ejetar e abrir o KOReader de novo, procurando o livro onde parou.

## O que a Ponte USB faz

1. **Ao plugar o cabo**, pergunta se você quer entrar em modo USB ou só carregar.
2. Escolhendo **Modo USB**, ela:
   - salva tudo e faz **backup dos dados de leitura** (progresso, marcações, configurações);
   - tira uma "foto" da lista de livros;
   - fecha o KOReader para o Kindle entrar no modo USB normal;
   - mantém **a página do livro na tela** enquanto o PC está conectado, com um aviso embaixo.
3. **Quando o PC ejeta ou o cabo é puxado**, ela:
   - confere se a memória do Kindle voltou em bom estado (avisa se voltou em modo somente leitura);
   - **restaura do backup** os dados de leitura que tiverem sido corrompidos;
   - **reabre o KOReader no mesmo livro**.
4. Já no KOReader, ela confere os livros novos ou alterados e move as **cópias incompletas** para a pasta `_incompletos`, para você copiar de novo. **Nada é apagado.**

Formatos conferidos contra cópia incompleta: EPUB, KEPUB, CBZ, ZIP, FBZ, DOCX, ODT, XPS, PDF, MOBI, AZW, AZW3, PRC, PDB, DJVU e FB2.

### Rápido e sem piscar

Desde a versão 1.1, a Ponte USB **não deixa o Kindle sair da página do livro**. Em vez de fechar o KOReader por completo (o que faz o Kindle mostrar a tela inicial, reiniciar serviços e redesenhar a tela várias vezes), ela só **pausa** o script do KOReader e libera o modo USB. Na volta, o KOReader reabre direto no livro, sem a piscada de tela cheia.

Medido num Kindle (11ª geração):

| | v1.0 | v1.1 |
|---|---|---|
| Do toque em "Modo USB" até o PC ver o Kindle | ~6 s | **~2,7 s** |
| Da ejeção até o livro aberto de novo | ~16 s | **~9,5 s** |

Quase todo o tempo da volta é o próprio KOReader abrindo. Esse tempo depende dos plugins que você tem instalados (veja [Problemas comuns](#problemas-comuns)).

Se esse jeito rápido não funcionar no seu Kindle, a Ponte USB percebe sozinha e passa a usar o jeito antigo, que fecha e reabre o KOReader inteiro. O jeito antigo também é usado quando o KOReader foi aberto sem o framework do Kindle ("no framework").

## Requisitos

- Kindle com **jailbreak** e **KOReader** instalado (aberto pelo KUAL ou atalho).
- O plugin só funciona no Kindle. Em outros aparelhos (Kobo, Android etc.) ele fica desativado sozinho.

## Instalação

1. Baixe o arquivo **`usbponte.koplugin.zip`** na página de [Releases](../../releases/latest) e extraia.
   *(Ou baixe o repositório inteiro em **Code → Download ZIP** e use a pasta `usbponte.koplugin` que está dentro dele.)*
2. Feche o KOReader e conecte o Kindle no PC pelo cabo USB. Ele aparece como um disco chamado **Kindle**.
3. Copie a pasta **`usbponte.koplugin`** inteira para dentro de **`koreader/plugins/`** no Kindle.
   No final, este arquivo precisa existir:
   ```
   koreader/plugins/usbponte.koplugin/main.lua
   ```
   ⚠️ Não deixe uma pasta dentro da outra (`usbponte.koplugin/usbponte.koplugin/...`) e não mude o nome da pasta.
4. Ejete o Kindle no PC, desconecte o cabo e abra o KOReader.
5. Pronto. O plugin aparece no menu **Ferramentas (🔧) → Ponte USB**.
   Se não aparecer, confira em **Ferramentas → Mais ferramentas → Gerenciamento de plugins** (*Tools → More tools → Plugin management*) se **Ponte USB** está ativado.

## Como usar

### Pelo cabo

Com o KOReader aberto, conecte o cabo. Vai aparecer:

> **Cabo USB conectado.** Entrar em modo USB para copiar arquivos?

- **Modo USB**: o KOReader fecha, o PC reconhece o Kindle e a página do livro continua na tela.
- **Só carregar**: nada muda, o Kindle só carrega.

Copie seus arquivos, **ejete o Kindle no PC** e desconecte. O KOReader reabre no livro em que você estava.

> 💡 Sempre ejete no PC antes de puxar o cabo. Puxar sem ejetar pode corromper arquivos. A Ponte USB tenta consertar o que der, mas ejetar é o que evita o problema.

### Pelo menu: Ferramentas → Ponte USB

| Opção | O que faz |
|---|---|
| **Entrar em modo USB agora** | Faz o mesmo que o botão "Modo USB" do aviso. Útil se o cabo já estava conectado. |
| **Perguntar ao conectar o cabo** | Liga ou desliga o aviso que aparece ao plugar o cabo. |
| **Restaurar progresso que sumiu (último backup)** | Traz de volta do último backup o progresso de livros que ainda existem no Kindle, mas perderam a posição de leitura. |
| **Ver registro** | Mostra o histórico do que a Ponte USB fez. |

### Por gesto

A ação **"Ponte USB: entrar em modo USB"** aparece na lista de ações do KOReader. Dá para colocar num gesto pelo gerenciador de gestos (*Settings → Taps and gestures → Gesture manager*), na categoria **Geral**.

## Onde ficam os dados

| Caminho no Kindle | O que é |
|---|---|
| `/var/local/usbponte/backups/bk1` … `bk3` | Os 3 últimos backups dos dados de leitura (até 20 MB cada). Ficam fora da área que o PC enxerga, para o PC não mexer neles. |
| `/var/local/usbponte/vigia.log` | Registro completo. |
| `koreader/usbponte-registro.txt` | Cópia do registro, visível pelo PC. Útil se algo der errado. |
| `_incompletos/` (na raiz do Kindle) | Livros que chegaram cortados. Copie de novo pelo PC. |
| `*.quebrado` | Quando um dado de leitura é restaurado, a versão corrompida fica ao lado com esse final, só por segurança. |

## Arquivos do plugin

| Arquivo | Função |
|---|---|
| `_meta.lua` | Nome e descrição do plugin. |
| `main.lua` | O plugin em si: menu, aviso do cabo, backup, foto dos livros e conferência dos livros depois do modo USB. |
| `vigia.sh` | Roda fora do KOReader (na memória RAM). Libera o modo USB, espera ele terminar, mantém o aviso na tela e devolve o controle ao KOReader. |
| `restaura.sh` | Restaura do backup os dados de leitura corrompidos ou que sumiram. |
| `checa.lua` | Usado pelo `restaura.sh` para descobrir quais arquivos de dados estão corrompidos. |

## Desinstalar

Apague a pasta `koreader/plugins/usbponte.koplugin` no Kindle. Se quiser, apague também `koreader/usbponte-registro.txt`.
Os backups em `/var/local/usbponte` ocupam pouco espaço. Para removê-los, use o Terminal do KOReader ou SSH: `rm -rf /var/local/usbponte`.

## Problemas comuns

- **O PC não reconheceu o Kindle.** Depois de 90 segundos a Ponte USB desiste e volta para o livro. Tente de novo: desconecte, conecte o cabo e escolha "Modo USB".
- **Aviso de memória em modo somente leitura.** Conecte de novo no PC, deixe o Windows verificar e corrigir a unidade e ejete antes de desconectar.
- **O KOReader não reabriu.** Abra pelo KUAL normalmente. Depois veja `koreader/usbponte-registro.txt` pelo PC para entender o que aconteceu.
- **O livro demora para abrir depois de ejetar.** A parte da Ponte USB leva menos de 1 segundo. O resto é o KOReader iniciando, e plugins pesados deixam isso bem mais lento. Num teste, um único plugin de terceiros levou 3,8 s dos ~8,5 s da abertura. Desativar os plugins que você não usa (**Ferramentas → Mais ferramentas → Gerenciamento de plugins**) deixa a volta mais rápida, e também qualquer abertura normal do KOReader.
- **Quero voltar ao jeito rápido depois de uma falha.** Se o jeito rápido falhar uma vez, a Ponte USB passa a usar o jeito antigo. Para tentar o rápido de novo, apague o arquivo `/var/local/usbponte/forcar_compat` (pelo Terminal do KOReader ou por SSH).

---

## English summary

**Ponte USB** ("USB Bridge") is a KOReader plugin for jailbroken Kindles. While KOReader runs, Kindle's USB mass storage is blocked, so plugging in the cable only charges the device. This plugin closes KOReader when you plug in the cable (or from the menu or a gesture), lets the Kindle enter normal USB mode while keeping the current book page on screen, and reopens KOReader on the same book once you eject or unplug. Since v1.1 it pauses `koreader.sh` instead of letting it exit, so the Kindle never goes back to its home screen: no screen flashes, ~2.7 s to enter USB mode and ~9.5 s to get back to the book (most of which is KOReader's own startup). It also backs up reading data beforehand, restores corrupted metadata afterwards, and moves incomplete book copies to `_incompletos/` (nothing is ever deleted). The interface is in Portuguese.

**Install:** download `usbponte.koplugin.zip` from Releases, extract, and copy the `usbponte.koplugin` folder into `koreader/plugins/` on your Kindle. It shows up under **Tools → Ponte USB**.

---

Feito com a ajuda do [Claude](https://claude.ai).
