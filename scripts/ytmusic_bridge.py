#!/usr/bin/env python3
"""Small JSON-lines bridge for the standalone YTMusicBar player.

The UI never receives cookies or auth headers. They stay in the local
ytmusicapi config file and are used only by this process for InnerTube calls.

Playback uses one persistent mpv instance owned by YTMusicBar. mpv resolves
the audio itself through its ytdl_hook (pointed at the Homebrew yt-dlp), so
songs and whole playlists are queued as plain YouTube URLs and previous/next
work on mpv's own playlist. Each bridge request is a short-lived process; the
IPC socket plus a pid file are the source of truth for the mpv lifecycle.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Iterator
from urllib.parse import parse_qs, urlparse

try:
    from ytmusicapi import YTMusic
    from ytmusicapi.constants import YTM_DOMAIN
    from ytmusicapi.helpers import get_authorization, sapisid_from_cookie
    from ytmusicapi.models.content.enums import LikeStatus
except ImportError as exc:  # pragma: no cover - exercised by setup diagnostics
    YTMusic = None  # type: ignore[assignment]
    IMPORT_ERROR = str(exc)
else:
    IMPORT_ERROR = ""


APP_SUPPORT = pathlib.Path(os.environ.get("YTMUSICBAR_SUPPORT_DIR", str(pathlib.Path.home() / "Library" / "Application Support" / "YTMusicBar")))
AUTH_FILE = pathlib.Path(os.environ.get("YTMUSICBAR_AUTH_FILE", str(APP_SUPPORT / "ytmusic-auth.json")))
SOCKET_PATH = pathlib.Path(os.environ.get("YTMUSICBAR_SOCKET", str(pathlib.Path(tempfile.gettempdir()) / "ytmusicbar-mpv.sock")))
QUEUE_FILE = APP_SUPPORT / "queue.json"
QUEUE_LIST_FILE = APP_SUPPORT / "queue.m3u"
PID_FILE = APP_SUPPORT / "mpv.pid"
LOCK_FILE = APP_SUPPORT / "player.lock"
LEGACY_FILES = ("current-video-id", "current-track.json", "current-track-liked")
MPV_BINARY = shutil.which("mpv") or "/opt/homebrew/bin/mpv"
YTDLP_BINARY = shutil.which("yt-dlp") or "/opt/homebrew/bin/yt-dlp"
AUDIO_OUTPUT = os.environ.get("YTMUSICBAR_AUDIO_OUTPUT", "")  # "null" keeps automated checks silent
WATCH_URL = "https://www.youtube.com/watch?v={}"
MUSIC_WATCH_URL = "https://music.youtube.com/watch?v={}"
MUSIC_PLAYLIST_URL = "https://music.youtube.com/playlist?list={}"
# The radio endpoint treats the limit as a floor and usually returns more.
RADIO_LIMIT = 150
HOME_ROWS = 20
# Playlists are the same: the limit is a floor, each page adds a couple hundred tracks. Personalized
# mixes never end, so fetching "all of it" never returns. A few hundred is already many hours.
PLAYLIST_LIMIT = 300
# Ceiling for a queue that keeps extending itself; a few thousand tracks is already days of music.
MAX_QUEUE = 2000


def reply(ok: bool, **payload: Any) -> None:
    data = {"ok": ok, **payload}
    print(json.dumps(data, ensure_ascii=False), flush=True)


def fail(message: str) -> None:
    reply(False, error=message)


def client() -> Any:
    if YTMusic is None:
        raise RuntimeError(f"ytmusicapi não está instalado: {IMPORT_ERROR}")
    if not AUTH_FILE.exists():
        raise RuntimeError(
            "Configure a autenticação do YouTube Music primeiro. "
            f"Arquivo esperado: {AUTH_FILE}"
        )
    return YTMusic(str(AUTH_FILE))


# --------------------------------------------------------------------------- auth


CURL_HEADER = re.compile(r"(?:-H|--header)\s+(?:'([^']*)'|\"([^\"]*)\")")
SESSION_EXPIRED = (
    "As credenciais foram salvas, mas o YouTube Music respondeu como sessão encerrada. "
    "Abra o YouTube Music logado no navegador, copie os request headers de uma requisição /browse e importe de novo."
)


def header_pairs(raw: str) -> dict[str, str]:
    text = raw.replace("\r\n", "\n").strip()
    if text.startswith("curl") or "\ncurl " in text:
        lines = [first or second for first, second in CURL_HEADER.findall(text)]
    else:
        lines = [line for line in text.split("\n") if not line.lstrip().startswith(":")]
    headers: dict[str, str] = {}
    for line in lines:
        key, separator, value = line.partition(":")
        if separator and key.strip():
            headers[key.strip().lower()] = value.strip()
    return headers


def parse_auth_input(raw: str) -> tuple[str, str]:
    """Reads a browser header block, a cURL command or a bare cookie value."""
    headers = header_pairs(raw)
    cookie = headers.get("cookie") or (raw.strip() if "__Secure-3PAPISID" in raw else "")
    if not cookie:
        raise RuntimeError(
            "Não encontrei o header cookie. Copie os request headers de uma requisição /browse, "
            "o comando cURL ou apenas o valor do header cookie."
        )
    return cookie, headers.get("x-goog-authuser") or "0"


def auth_headers(cookie: str, authuser: str) -> str:
    """Rebuilds the minimal header block; ytmusicapi regenerates the SAPISIDHASH on every request."""
    try:
        sapisid = sapisid_from_cookie(cookie)
    except (KeyError, TypeError):
        raise RuntimeError(
            "O cookie não contém __Secure-3PAPISID. Confirme que a sessão do YouTube Music está aberta no navegador."
        ) from None
    return "\n".join([
        f"cookie: {cookie}",
        f"x-goog-authuser: {authuser}",
        f"authorization: {get_authorization(sapisid + ' ' + YTM_DOMAIN)}",
    ])


def verify_auth(path: pathlib.Path) -> str:
    """Confirms the stored credentials are signed in and returns the account name when available."""
    probe = YTMusic(str(path))
    try:
        response = probe._send_request("browse", {"browseId": "FEmusic_liked_playlists"})
    except Exception as exc:
        raise RuntimeError(SESSION_EXPIRED) from exc
    params = (response.get("responseContext") or {}).get("serviceTrackingParams") or []
    signed_in = any(
        entry.get("key") == "logged_in" and entry.get("value") == "1"
        for service in params
        for entry in service.get("params") or []
    )
    if not signed_in:
        raise RuntimeError(SESSION_EXPIRED)
    with contextlib.suppress(Exception):
        return probe.get_account_info().get("accountName") or ""
    return ""


def configure_auth(raw: str) -> str:
    """Writes the auth file only after the credentials proved to be signed in."""
    cookie, authuser = parse_auth_input(raw)
    headers = auth_headers(cookie, authuser)
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    pending = AUTH_FILE.with_name(AUTH_FILE.name + ".pending")
    import ytmusicapi

    ytmusicapi.setup(filepath=str(pending), headers_raw=headers)
    try:
        account = verify_auth(pending)
    except Exception:
        pending.unlink(missing_ok=True)
        raise
    pending.replace(AUTH_FILE)
    return account


def selftest() -> int:
    """Offline checks for the auth import, run with --selftest."""
    if YTMusic is None:
        print(f"BridgeSelfTest: FAIL · ytmusicapi indisponível: {IMPORT_ERROR}")
        return 1

    def prepare(raw: str) -> tuple[str, str]:
        """Same path configure_auth takes: read the input, then rebuild the headers."""
        cookie, authuser = parse_auth_input(raw)
        return cookie, auth_headers(cookie, authuser)

    cookie = "__Secure-3PAPISID=abc123; __Secure-3PSID=def456"
    accepted = [
        (f"cookie: {cookie}\nx-goog-authuser: 3", "3"),
        (f"curl 'https://music.youtube.com/youtubei/v1/browse' -H 'cookie: {cookie}' -H 'x-goog-authuser: 1'", "1"),
        (cookie, "0"),
    ]
    for raw, expected_user in accepted:
        parsed_cookie, headers = prepare(raw)
        if parsed_cookie != cookie or f"x-goog-authuser: {expected_user}" not in headers or "SAPISIDHASH" not in headers:
            print(f"BridgeSelfTest: FAIL · {raw[:40]!r} → {parsed_cookie[:30]!r}")
            return 1
    for raw in ("nada aqui", "cookie: FOO=bar; BAZ=qux", ""):
        try:
            prepare(raw)
        except RuntimeError:
            continue
        print(f"BridgeSelfTest: FAIL · aceitou entrada inválida {raw!r}")
        return 1
    durations = [({"duration_seconds": 279}, 279), ({"length": "4:39"}, 279), ({"length": "1:01:01"}, 3661), ({}, 0), ({"length": ""}, 0)]
    for item, expected in durations:
        if duration_of(item) != expected:
            print(f"BridgeSelfTest: FAIL · duration_of({item!r}) = {duration_of(item)}, esperado {expected}")
            return 1
    albums = [("Vol.1", "Vol.1"), ({"name": "Vol.1"}, "Vol.1"), (None, "")]
    for raw_album, expected in albums:
        got = track({"videoId": "x", "album": raw_album})["album"]
        if got != expected:
            print(f"BridgeSelfTest: FAIL · album {raw_album!r} virou {got!r}, esperado {expected!r}")
            return 1
    if not queue_race_check():
        return 1
    print("BridgeSelfTest: OK")
    return 0


def queue_race_check() -> bool:
    """A snapshot must not resurrect a queue that a concurrent play() already replaced."""
    global QUEUE_FILE
    original = QUEUE_FILE
    try:
        QUEUE_FILE = pathlib.Path(tempfile.mkdtemp()) / "queue.json"
        save_queue({"order": ["a"], "tracks": {"a": {"title": "A"}}})
        load_queue()  # what a snapshot process would have read before play() ran
        save_queue({"order": ["a", "b"], "tracks": {"a": {"title": "A"}, "b": {"title": "B"}}})
        update_queue(lambda queue: queue.update({"lastVideoId": "a"}))
        after = load_queue()
        if after.get("order") != ["a", "b"] or "b" not in (after.get("tracks") or {}):
            print(f"BridgeSelfTest: FAIL · update_queue atropelou a fila: {after.get('order')}")
            return False
        return True
    finally:
        QUEUE_FILE = original


# --------------------------------------------------------------------------- catalog


def artwork(item: dict[str, Any]) -> str:
    thumbnails = item.get("thumbnails") or item.get("thumbnail") or []
    if isinstance(thumbnails, list) and thumbnails:
        return thumbnails[-1].get("url", "")
    if isinstance(thumbnails, dict):
        return thumbnails.get("url", "")
    return ""


def like_status(item: dict[str, Any]) -> bool | None:
    status = item.get("likeStatus")
    if status in ("LIKE", "INDIFFERENT", "DISLIKE"):
        return status == "LIKE"
    return None


def duration_of(item: dict[str, Any]) -> int:
    """Watch-playlist rows carry "4:39" instead of duration_seconds."""
    seconds = item.get("duration_seconds")
    if isinstance(seconds, (int, float)) and seconds:
        return int(seconds)
    total = 0
    for part in str(item.get("length") or "").split(":"):
        if not part.strip().isdigit():
            return 0
        total = total * 60 + int(part)
    return total


def track(item: dict[str, Any], kind: str = "song") -> dict[str, Any]:
    if kind == "playlist":
        playlist_id = item.get("playlistId") or item.get("browseId") or ""
        count = item.get("count")
        subtitle = (f"{count} música" if str(count) == "1" else f"{count} músicas") if count else (item.get("description") or "")
        return {
            "id": playlist_id,
            "kind": "playlist",
            "title": item.get("title") or "",
            "subtitle": subtitle,
            "album": "",
            "artwork": artwork(item),
            "duration": 0,
            "url": MUSIC_PLAYLIST_URL.format(playlist_id) if playlist_id else "",
        }
    if kind == "album":
        album_id = item.get("browseId") or ""
        artists = item.get("artists") or []
        artist = ", ".join(a.get("name", "") for a in artists if a.get("name"))
        return {
            "id": album_id,
            "kind": "album",
            "title": item.get("title") or "",
            "subtitle": artist or str(item.get("year") or ""),
            "album": "",
            "artwork": artwork(item),
            "duration": 0,
            "url": MUSIC_PLAYLIST_URL.format(album_id) if album_id else "",
        }
    video_id = item.get("videoId") or ""
    artists = item.get("artists") or []
    artist = ", ".join(a.get("name", "") for a in artists if a.get("name"))
    # Playlist rows nest the album as an object; album tracks send the title directly.
    album = item.get("album")
    album = album.get("name", "") if isinstance(album, dict) else album or ""
    return {
        "id": video_id,
        "kind": "song",
        "title": item.get("title") or "",
        "subtitle": artist,
        "album": album or "",
        "artwork": artwork(item),
        "duration": duration_of(item),
        "url": MUSIC_WATCH_URL.format(video_id) if video_id else "",
        "liked": like_status(item),
    }


def playlist_tracks(playlist_id: str, limit: int = PLAYLIST_LIMIT) -> list[dict[str, Any]]:
    data = client().get_playlist(playlist_id, limit=limit)
    tracks = []
    for row in data.get("tracks") or []:
        if not row.get("videoId") or row.get("isAvailable") is False:
            continue
        tracks.append(track(row))
    return tracks


def album_tracks(browse_id: str) -> list[dict[str, Any]]:
    data = client().get_album(browse_id)
    return [track(row) for row in data.get("tracks") or [] if row.get("videoId") and row.get("isAvailable") is not False]


def radio_tracks(video_id: str) -> list[dict[str, Any]]:
    """The endless radio built from one song; the limit is a floor, YouTube returns more."""
    data = client().get_watch_playlist(videoId=video_id, radio=True, limit=RADIO_LIMIT)
    return [track(row) for row in data.get("tracks") or [] if row.get("videoId")]


def home_sections(limit: int = HOME_ROWS) -> list[dict[str, Any]]:
    """The YouTube Music home rows, keeping only the rows that map to something playable.

    A row carrying a videoId is a song, even when it also carries the RDAMVM playlist id of its
    radio; that id is not a real playlist and get_playlist rejects it.
    """
    sections = []
    for section in client().get_home(limit=limit):
        items = []
        for row in section.get("contents") or []:
            if row.get("videoId"):
                items.append(track(row))
            elif row.get("playlistId"):
                items.append(track(row, "playlist"))
            elif str(row.get("browseId") or "").startswith("MPREb"):
                items.append(track(row, "album"))
        if items:
            sections.append({"title": section.get("title") or "", "items": items})
    return sections


# --------------------------------------------------------------------------- mpv IPC


def mpv_request(command: list[Any], timeout: float = 0.8) -> dict[str, Any] | None:
    """Send one IPC command; None means mpv is not reachable."""
    if not SOCKET_PATH.exists():
        return None
    payload = (json.dumps({"command": command}) + "\n").encode()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(SOCKET_PATH))
            sock.sendall(payload)
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buffer += chunk
        for line in buffer.decode().splitlines():
            message = json.loads(line)
            if "request_id" in message or "error" in message:
                return message
        return None
    except (OSError, ValueError):
        return None


def mpv_get(prop: str) -> Any:
    response = mpv_request(["get_property", prop])
    if not response or response.get("error") != "success":
        return None
    return response.get("data")


def mpv_alive() -> bool:
    return mpv_get("mpv-version") is not None


def read_pid() -> int | None:
    try:
        return int(PID_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def owned_pid_alive(pid: int) -> bool:
    """True only for a live process that is our mpv (its command line names our socket)."""
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    result = subprocess.run(["/bin/ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True, check=False)
    return str(SOCKET_PATH) in result.stdout


def wait_for_exit(pid: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not owned_pid_alive(pid):
            return True
        time.sleep(0.05)
    return not owned_pid_alive(pid)


def kill_owned_mpv() -> None:
    pid = read_pid()
    if pid and owned_pid_alive(pid):
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGTERM)
        if not wait_for_exit(pid, 1.5):
            with contextlib.suppress(OSError):
                os.kill(pid, signal.SIGKILL)
            wait_for_exit(pid, 1.0)
    PID_FILE.unlink(missing_ok=True)
    SOCKET_PATH.unlink(missing_ok=True)


def ensure_mpv() -> None:
    """Reuse the running mpv or start exactly one new instance."""
    if mpv_alive():
        return
    if not pathlib.Path(MPV_BINARY).exists():
        raise RuntimeError("mpv não foi encontrado. Instale com Homebrew.")
    if not pathlib.Path(YTDLP_BINARY).exists():
        raise RuntimeError("yt-dlp não foi encontrado. Instale com Homebrew.")
    kill_owned_mpv()
    args = [
        MPV_BINARY, "--no-video", "--force-window=no", "--audio-display=no",
        "--idle=yes", "--really-quiet", "--no-terminal",
        f"--input-ipc-server={SOCKET_PATH}",
        "--ytdl-format=bestaudio/best",
        f"--script-opts=ytdl_hook-ytdl_path={YTDLP_BINARY}",
    ]
    if AUDIO_OUTPUT:
        args.append(f"--ao={AUDIO_OUTPUT}")
    process = subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    PID_FILE.write_text(str(process.pid), encoding="utf-8")
    for _ in range(80):  # up to 4 s
        if mpv_alive():
            return
        if process.poll() is not None:
            raise RuntimeError("O mpv encerrou logo após iniciar.")
        time.sleep(0.05)
    raise RuntimeError("O mpv não respondeu pelo socket IPC.")


@contextlib.contextmanager
def player_lock() -> Iterator[None]:
    """Serialize play/stop across concurrent bridge processes (rapid clicks)."""
    with open(LOCK_FILE, "w", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def stop_player() -> None:
    """Stop the single mpv instance owned by YTMusicBar and forget the queue."""
    with player_lock():
        if mpv_alive():
            mpv_request(["quit"])
            pid = read_pid()
            if pid:
                wait_for_exit(pid, 1.5)
        kill_owned_mpv()
        QUEUE_FILE.unlink(missing_ok=True)
        QUEUE_LIST_FILE.unlink(missing_ok=True)


# --------------------------------------------------------------------------- queue state


def load_queue() -> dict[str, Any]:
    try:
        data = json.loads(QUEUE_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("tracks"), dict):
            return data
    except (OSError, ValueError):
        pass
    return {"order": [], "tracks": {}}


def save_queue(queue: dict[str, Any]) -> None:
    QUEUE_FILE.write_text(json.dumps(queue, ensure_ascii=False), encoding="utf-8")


def update_queue(mutate: Callable[[dict[str, Any]], None]) -> dict[str, Any]:
    """Read-modify-write of the queue under the player lock, re-reading first.

    Each bridge call is its own process, so a snapshot that read the file, then wrote it back
    after a play() had replaced the queue, would resurrect the old one and lose the metadata
    of every track that play() had just queued.
    """
    with player_lock():
        queue = load_queue()
        mutate(queue)
        save_queue(queue)
        return queue


def ensure_like_known(queue: dict[str, Any], video_id: str) -> dict[str, Any] | None:
    """Fetch the like state from the server once per track, lazily, so play stays fast."""
    meta = queue["tracks"].get(video_id)
    if not meta or meta.get("liked") is not None or meta.get("likeChecked"):
        return None
    liked: bool | None = None
    try:
        data = client().get_watch_playlist(videoId=video_id, limit=1)
        for row in data.get("tracks") or []:
            if row.get("videoId") == video_id:
                liked = like_status(row)
                break
    except Exception:
        return None

    def mutate(queue: dict[str, Any]) -> None:
        entry = queue["tracks"].get(video_id)
        if entry is not None:
            entry["likeChecked"] = True
            entry["liked"] = liked

    return update_queue(mutate)["tracks"].get(video_id)


def video_id_from(url: str) -> str:
    if not url:
        return ""
    try:
        query = parse_qs(urlparse(url).query)
    except ValueError:
        return ""
    return (query.get("v") or [""])[0]


def current_video_id() -> str:
    for entry in mpv_get("playlist") or []:
        if entry.get("current"):
            return video_id_from(entry.get("filename", ""))
    return video_id_from(mpv_get("path") or "")


# --------------------------------------------------------------------------- playback


def queued_track(raw: dict[str, Any]) -> dict[str, Any]:
    """Normalize a track sent by the UI (search/library row) into queue metadata."""
    liked = raw.get("liked")
    return {
        "id": str(raw.get("id") or ""),
        "kind": "song",
        "title": raw.get("title") or "",
        "subtitle": raw.get("artist") or raw.get("subtitle") or "",
        "album": raw.get("album") or "",
        "artwork": raw.get("artwork") or "",
        "duration": raw.get("duration") or 0,
        "liked": liked if isinstance(liked, bool) else None,
    }


def play(kind: str, item_id: str, metadata: dict[str, Any], queue_items: list[dict[str, Any]]) -> None:
    """Queue a playlist, album or radio, or the list the song was clicked in (Apple Music style), starting at the song."""
    if not item_id:
        raise RuntimeError("O item não tem um identificador válido.")
    collections = {"playlist": playlist_tracks, "album": album_tracks, "radio": radio_tracks}
    if kind in collections:
        tracks = collections[kind](item_id)
        if not tracks:
            raise RuntimeError("O item não tem faixas disponíveis.")
        start = 0
    else:
        tracks = [queued_track(raw) for raw in queue_items if raw.get("id")]
        if not any(t["id"] == item_id for t in tracks):
            tracks = [queued_track({"id": item_id, **metadata})]
        start = next(i for i, t in enumerate(tracks) if t["id"] == item_id)

    with player_lock():
        ensure_mpv()
        load_queue_into_mpv([WATCH_URL.format(t["id"]) for t in tracks], start)
        mpv_request(["set_property", "pause", False])
        save_queue({
            "order": [t["id"] for t in tracks],
            "tracks": {t["id"]: t for t in tracks},
            "lastVideoId": tracks[start]["id"],
            # Remember where the queue came from so it can be topped up later. A finite list is
            # already queued whole, and an album ends, so only these two are worth extending.
            "source": {"kind": kind, "id": item_id} if kind in ("playlist", "radio") else {},
        })


def extend_queue() -> int:
    """Appends more tracks from the queue's own source, so a radio or a mix keeps going.

    Returns how many tracks were added. Zero means the source has nothing left, or the queue
    changed while the fetch was in flight.
    """
    queue = load_queue()
    source = queue.get("source") or {}
    kind = str(source.get("kind") or "")
    item_id = str(source.get("id") or "")
    order: list[str] = queue.get("order") or []
    if not item_id or not order or len(order) >= MAX_QUEUE:
        return 0
    tail = order[-1]
    if kind == "radio":
        # A radio is regenerated on every call, so continue it from the track the queue ends on.
        fresh = radio_tracks(tail)
    elif kind == "playlist":
        # The limit is a floor, so asking for what we already have returns that plus the next page.
        fresh = playlist_tracks(item_id, limit=len(order))
    else:
        return 0
    known = set(order)
    added = [t for t in fresh if t["id"] not in known]
    if not added:
        return 0
    with player_lock():
        current = load_queue()
        if (current.get("order") or [])[-1:] != [tail] or not mpv_alive():
            return 0
        QUEUE_LIST_FILE.write_text("\n".join(WATCH_URL.format(t["id"]) for t in added) + "\n", encoding="utf-8")
        if not mpv_request(["loadlist", str(QUEUE_LIST_FILE), "append"], timeout=2.0):
            return 0
        current["order"] = [*current["order"], *(t["id"] for t in added)]
        current["tracks"].update({t["id"]: t for t in added})
        save_queue(current)
    return len(added)


def load_queue_into_mpv(urls: list[str], start: int) -> None:
    """Start the clicked track immediately, then place the rest of the list around it.

    Loading the whole list and jumping to `start` would make mpv resolve entry 0
    first, delaying the clicked track by a few seconds.
    """
    def ok(response: dict[str, Any] | None) -> bool:
        return bool(response) and response.get("error") == "success"

    if not ok(mpv_request(["loadfile", urls[start], "replace"], timeout=2.0)):
        raise RuntimeError("O mpv não aceitou a faixa.")
    after = urls[start + 1:]
    if after:
        QUEUE_LIST_FILE.write_text("\n".join(after) + "\n", encoding="utf-8")
        ok(mpv_request(["loadlist", str(QUEUE_LIST_FILE), "append"], timeout=2.0))
    before = urls[:start]
    if before:
        QUEUE_LIST_FILE.write_text("\n".join(before) + "\n", encoding="utf-8")
        if not ok(mpv_request(["loadlist", str(QUEUE_LIST_FILE), "insert-at", 0], timeout=2.0)):
            # Older mpv without insert-at: append, then move each entry in front of the current one.
            ok(mpv_request(["loadlist", str(QUEUE_LIST_FILE), "append"], timeout=2.0))
            count = mpv_get("playlist-count") or 0
            for offset in range(len(before)):
                mpv_request(["playlist-move", count - len(before) + offset, offset])


def snapshot() -> dict[str, Any]:
    if not mpv_alive():
        return {"idle": True}
    queue = load_queue()
    order: list[str] = queue.get("order") or []
    ended = mpv_get("idle-active") is True
    playlist = mpv_get("playlist") or []
    index = next((i for i, entry in enumerate(playlist) if entry.get("current")), -1)
    video_id = video_id_from(playlist[index].get("filename", "")) if index >= 0 else video_id_from(mpv_get("path") or "")
    if not video_id:
        # Between tracks (or after the queue ended) mpv has no current entry; keep showing the last known track.
        video_id = str(queue.get("lastVideoId") or "")
    meta = queue["tracks"].get(video_id, {})
    if ended and not meta:
        return {"idle": True}
    if video_id and video_id != queue.get("lastVideoId"):
        queue = update_queue(lambda q: q.update({"lastVideoId": video_id}))
        meta = queue["tracks"].get(video_id, meta)
    if video_id:
        meta = ensure_like_known(queue, video_id) or meta
    title = meta.get("title") or mpv_get("media-title") or "Carregando…"
    if index < 0 and video_id in order:
        index = order.index(video_id)
    duration = (mpv_get("duration") if not ended else None) or meta.get("duration") or 0
    volume = mpv_get("volume")
    return {
        "idle": False,
        "title": title,
        "artist": meta.get("subtitle", ""),
        "album": meta.get("album", ""),
        "artwork": meta.get("artwork", ""),
        "currentTime": duration if ended else (mpv_get("time-pos") or 0),
        "duration": duration,
        "paused": True if ended else bool(mpv_get("pause")),
        # core-idle stays true while yt-dlp resolves the stream, so the UI can avoid faking progress.
        "preparing": bool(mpv_get("core-idle")) and not ended,
        "volume": (100 if volume is None else volume) / 100,
        "muted": bool(mpv_get("mute")),
        "liked": meta.get("liked"),
        "queueIndex": index,
        "queueCount": max(len(playlist), len(order)),
        "url": MUSIC_WATCH_URL.format(video_id) if video_id else "",
    }


def toggle_playback() -> None:
    """Pause/resume; after the queue ended, restart the last track instead of doing nothing."""
    if mpv_get("idle-active") is True:
        queue = load_queue()
        order: list[str] = queue.get("order") or []
        last = str(queue.get("lastVideoId") or "")
        if last in order:
            mpv_request(["playlist-play-index", order.index(last)])
            mpv_request(["set_property", "pause", False])
        return
    mpv_request(["cycle", "pause"])


def previous_track() -> None:
    position = mpv_get("playlist-pos") or 0
    elapsed = mpv_get("time-pos") or 0
    if position <= 0 or elapsed > 3:
        mpv_request(["set_property", "time-pos", 0])
    else:
        mpv_request(["playlist-prev"])


def set_like(video_id: str, liked: bool) -> None:
    """Sets the like state instead of toggling it, so the optimistic UI cannot drift from the server."""
    if not video_id:
        raise RuntimeError("Nenhuma faixa selecionada para curtir.")
    client().rate_song(video_id, LikeStatus.LIKE if liked else LikeStatus.INDIFFERENT)

    def mutate(queue: dict[str, Any]) -> None:
        queue["tracks"].setdefault(video_id, {})["liked"] = liked

    update_queue(mutate)


# --------------------------------------------------------------------------- protocol


def handle(request: dict[str, Any]) -> None:
    command = request.get("command")
    if command == "stop":
        stop_player()
        reply(True)
        return
    if command == "configure":
        if YTMusic is None:
            raise RuntimeError(f"ytmusicapi não está instalado: {IMPORT_ERROR}")
        # The auth file is only replaced after the credentials proved to be signed in.
        account = configure_auth(str(request.get("headers", "")))
        reply(True, configured=True, authenticated=True, account=account)
        return
    if command == "verify":
        if not AUTH_FILE.exists():
            reply(True, configured=False, authenticated=False)
            return
        try:
            account = verify_auth(AUTH_FILE)
        except Exception as exc:
            reply(True, configured=True, authenticated=False, error=str(exc))
            return
        reply(True, configured=True, authenticated=True, account=account)
        return
    if command == "status":
        reply(True, configured=AUTH_FILE.exists(), mpv=pathlib.Path(MPV_BINARY).exists(), ytdlp=pathlib.Path(YTDLP_BINARY).exists(), snapshot=snapshot())
        return
    if command == "search":
        results = client().search(request.get("query", ""), filter="songs")
        reply(True, items=[track(row) for row in results[:50]])
        return
    if command == "library":
        reply(True, items=[track(row) for row in client().get_library_songs(limit=100)])
        return
    if command == "playlists":
        reply(True, items=[track(row, "playlist") for row in client().get_library_playlists(limit=100) if row.get("playlistId")])
        return
    if command == "home":
        reply(True, sections=home_sections())
        return
    if command == "radio":
        video_id = str(request.get("id") or "")
        if not video_id:
            raise RuntimeError("Nenhuma faixa selecionada para iniciar a rádio.")
        reply(True, items=radio_tracks(video_id))
        return
    if command == "extend":
        reply(True, added=extend_queue())
        return
    if command == "queue":
        queue = load_queue()
        items = []
        for video_id in queue.get("order") or []:
            meta = queue["tracks"].get(video_id, {})
            items.append({
                "id": video_id, "kind": "song",
                "title": meta.get("title") or video_id, "subtitle": meta.get("subtitle", ""), "album": meta.get("album", ""),
                "artwork": meta.get("artwork", ""), "duration": meta.get("duration") or 0,
                "url": MUSIC_WATCH_URL.format(video_id), "liked": meta.get("liked"),
            })
        reply(True, items=items, snapshot=snapshot())
        return
    if command == "play":
        metadata = {key: request.get(key, "") for key in ("title", "artist", "album", "artwork", "duration", "liked")}
        queue_items = request.get("queue") if isinstance(request.get("queue"), list) else []
        play(str(request.get("kind") or "song"), str(request.get("id") or ""), metadata, queue_items)
        reply(True, snapshot=snapshot())
        return
    if command == "action":
        action = request.get("action")
        simple = {"next": ["playlist-next"], "toggleMute": ["cycle", "mute"]}
        if action == "like":
            set_like(str(request.get("id") or "") or current_video_id(), bool(request.get("liked")))
        elif action == "togglePlayback":
            toggle_playback()
        elif action == "previous":
            previous_track()
        elif action == "jump":
            mpv_request(["playlist-play-index", int(request.get("value") or 0)])
            mpv_request(["set_property", "pause", False])
        elif action == "seek":
            mpv_request(["set_property", "time-pos", float(request.get("value") or 0)])
        elif action == "volume":
            mpv_request(["set_property", "volume", float(request.get("value") or 0) * 100])
        elif action in simple:
            mpv_request(simple[action])
        else:
            raise RuntimeError(f"Ação desconhecida: {action}")
        reply(True, snapshot=snapshot())
        return
    fail(f"Comando desconhecido: {command}")


def main() -> None:
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    for name in LEGACY_FILES:
        (APP_SUPPORT / name).unlink(missing_ok=True)
    for line in sys.stdin:
        try:
            handle(json.loads(line))
        except Exception as exc:  # bridge errors are returned to the Swift UI
            fail(str(exc))


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    main()
