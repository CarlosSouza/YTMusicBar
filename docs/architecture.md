# Arquitetura

```text
MenuBarExtra (popover SwiftUI) ───────┐
                                     ▼
                                PlayerStore
                                     │ JSON lines (um processo por comando)
                                     ▼
                              ytmusic_bridge.py
                             ┌───────┴────────┐
                             ▼                ▼
                         ytmusicapi          mpv (único, persistente)
                     busca/biblioteca/   ├─ ytdl_hook → yt-dlp resolve o áudio
                     playlists/curtir    ├─ playlist interna = fila de faixas
                                         └─ socket IPC ytmusicbar-mpv.sock
```

`LocalMusicPlayer` é o seam entre SwiftUI e o backend. Cada comando é uma mensagem JSON para o bridge Python, que vive só durante aquele comando. Cookies e headers nunca retornam para a interface.

O catálogo autenticado usa `ytmusicapi` para chamadas InnerTube. A configuração inicial é feita em um navegador normal, pela tela guiada do app, porque o Google bloqueia login em WebViews.

## Ciclo de vida do mpv

- Existe no máximo um `mpv` do YTMusicBar. O bridge o encontra pelo socket IPC e pelo `mpv.pid`; se o socket não responde, encerra o pid antigo (só se a linha de comando dele referencia o socket do app) e inicia outro.
- `play` recebe a música clicada e a lista em que ela estava. Envia `loadfile` da faixa clicada (começa a tocar de imediato), `loadlist … append` das seguintes e `loadlist … insert-at 0` das anteriores, e salva metadados por videoId em `queue.json` (título, artista, álbum, capa, curtida, `lastVideoId`). Playlists são expandidas com `get_playlist`.
- A curtida é consultada no servidor (`get_watch_playlist`) de forma preguiçosa, uma vez por faixa, durante o `status`, quando a lista não trouxe `likeStatus`.
- `play` e `stop` são serializados por `flock` em `player.lock`, então cliques rápidos não geram processos duplicados; o último clique vence.
- O snapshot lê a entrada `current` da playlist do mpv para saber qual faixa toca e cruza com `queue.json`. Em transições sem entrada `current` usa `lastVideoId`, para a interface não piscar. Quando a fila termina (`idle-active`), devolve a última faixa pausada no fim; `togglePlayback` nesse estado faz `playlist-play-index` para reiniciá-la. Sem socket ou sem fila, o estado é `idle`.
- `stop` envia `quit`, espera o processo sair, remove socket, pid e fila. O app chama `stop` em `applicationShouldTerminate` e só então encerra.

Não existem WebKit, AppleScript, Apple Events, teclas de mídia globais ou frameworks privados. A principal fragilidade é a estabilidade dos protocolos internos usados pelo `ytmusicapi`/`yt-dlp`.
