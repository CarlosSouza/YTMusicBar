# YTMusicBar

Cliente autônomo do YouTube Music para a barra de menus do macOS 14+, feito em SwiftUI, `ytmusicapi`, `yt-dlp` e `mpv`. O app segue a arquitetura do widget `quickshell.ytmusic` do Omarchy e reaproveita a abordagem de empacotamento local do UsageBar.

O catálogo é consultado pelo protocolo local do `ytmusicapi`. A reprodução usa um único `mpv` persistente, que resolve o áudio sozinho pelo `ytdl_hook` (apontado para o `yt-dlp` do Homebrew) e mantém a fila de faixas. Não há Safari, Chrome, WebView, Apple Events ou login embutido.

## Recursos

- tudo acontece no popover da barra de menus, sem nenhuma janela: player com capa, progresso arrastável, transporte e volume; busca; abas Biblioteca, Playlists e Resultados em uma lista rolável; Ajustes e Configurar acesso como páginas internas;
- reprodução local em segundo plano por um único mpv, reaproveitado entre cliques;
- ao tocar uma música, a lista onde ela estava (biblioteca ou resultados) entra na fila a partir dela; playlists entram inteiras. Anterior e próxima navegam pela fila;
- nome da faixa na barra de menus, com capa, artista, álbum e progresso no popover;
- reproduzir/pausar, anterior (reinicia a faixa depois de 3 s), próxima, arrastar o progresso;
- curtir ou remover a curtida da faixa atual, com o estado inicial consultado no servidor;
- volume e mudo do mpv;
- nenhum acesso por Apple Events e nenhuma permissão de Automação do macOS.

## Compilar

Pré-requisitos: macOS 14+, Command Line Tools ou Xcode com Swift 6, e Homebrew com `mpv` e `yt-dlp`. O `ytmusicapi` fica em um venv local que o build copia para dentro do app.

```sh
brew install mpv yt-dlp
git clone https://github.com/CarlosSouza/YTMusicBar.git
cd YTMusicBar
python3 -m venv .ytmusic-venv
.ytmusic-venv/bin/pip install ytmusicapi
bash scripts/build-app.sh
open dist/YTMusicBar.app
```

O script gera um app com assinatura ad hoc para uso local. Para distribuição pública ainda são necessários Developer ID, notarização e um ícone próprio.

## Primeiro uso

1. Abra o YTMusicBar pela barra de menus.
2. Clique em **Configurar acesso…**. A página explica cada passo, abre o YouTube Music e recebe os headers colados diretamente no popover. Não é preciso abrir o Terminal.
3. Depois de salvar, use a busca ou a aba Biblioteca e clique em uma música; o nome e os controles passam a aparecer no popover e o título na barra de menus.

Os headers ficam em `~/Library/Application Support/YTMusicBar/ytmusic-auth.json` e são usados somente pelo bridge local. O navegador não é necessário depois da configuração. Eles são credenciais sensíveis e não devem ser compartilhados.

## Biblioteca, playlists e busca

O popover tem as abas Biblioteca e Playlists, e a aba Resultados aparece depois de uma busca. Clicar em uma música coloca na fila a lista inteira onde ela estava, começando por ela; clicar em uma playlist carrega todas as faixas disponíveis. Quando a fila termina, a última faixa fica visível pausada e o botão de reproduzir a reinicia. Cliques rápidos são serializados pelo bridge e o último vence, sempre com um único processo `mpv`. Fechar o popover mantém a reprodução. Sair (ou Cmd-Q) para o mpv antes de o processo terminar.

O estado do player fica em `~/Library/Application Support/YTMusicBar/` (`queue.json`, `queue.m3u`, `mpv.pid`, `player.lock`); o socket IPC do mpv é `ytmusicbar-mpv.sock` no diretório temporário do usuário.

## Verificar

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/ytmusicbar-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/ytmusicbar-modules \
swift run \
  --scratch-path /private/tmp/ytmusicbar-tests \
  --cache-path /private/tmp/ytmusicbar-cache \
  --disable-sandbox \
  YTMusicCoreChecks

plutil -lint dist/YTMusicBar.app/Contents/Info.plist
codesign --verify --deep --strict dist/YTMusicBar.app
```

Os checks cobrem URLs, avanço do progresso, formatação de duração, o bridge Python e a presença de `mpv`/`yt-dlp`.

## Limites conhecidos

- `ytmusicapi` e `yt-dlp` dependem de APIs/protocolos internos do YouTube e podem exigir atualização;
- os headers de autenticação podem expirar ou precisar ser refeitos;
- o app não contorna anúncios, DRM, restrições geográficas ou requisitos do YouTube Premium;
- a versão local usa assinatura ad hoc e não está pronta para distribuição fora desta máquina.

## Estrutura

- `Sources/YTMusicCore`: estado de reprodução, URLs e lógica testável;
- `Sources/YTMusicBar/LocalMusicPlayer.swift`: bridge Swift para catálogo e reprodução local;
- `scripts/ytmusic_bridge.py`: `ytmusicapi`, ciclo de vida do mpv único e fila via IPC;
- `Sources/YTMusicBar/App.swift`: popover completo (player, catálogo, ajustes, configuração de acesso);
- `Sources/YTMusicBar/Store.swift`: estado observável, aba ativa, busca, polling e encerramento gracioso;
- `scripts/build-app.sh`: empacotamento `.app` local;
- `Tests/YTMusicCoreTests`: checks sem rede.
