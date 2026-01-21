#!/usr/bin/env python3
import argparse
import asyncio
import base64
import hashlib
import json
import os
import sys
from typing import Optional

import websockets  # from python3-websockets package

OBS_URL = "ws://127.0.0.1:4455"
DEFAULT_SCENE_NAME = "memes"
DEFAULT_SOCKET_PATH = "/tmp/obs_meme_daemon.sock"

# Name of the audio input in OBS to duck/mute during memes/TTS
BGM_INPUT_NAME = "BGM"

# Text source to update for current track display
TRACK_SOURCE_NAME = "CurrentTrack"

# NetTTS status server (0.95d): sends "START\n" / "STOP\n" when speaking
NETTTS_STATUS_HOST = "127.0.0.1"
NETTTS_STATUS_PORT = 5556


def compute_auth(password: str, challenge: str, salt: str) -> str:
    """
    obs-websocket v5 auth:
      secret = base64(sha256(password + salt))
      auth   = base64(sha256(secret + challenge))
    """
    secret_hash = hashlib.sha256((password + salt).encode("utf-8")).digest()
    secret_b64 = base64.b64encode(secret_hash).decode("utf-8")

    auth_hash = hashlib.sha256((secret_b64 + challenge).encode("utf-8")).digest()
    auth_b64 = base64.b64encode(auth_hash).decode("utf-8")
    return auth_b64


class ObsMemeController:
    def __init__(self, password: Optional[str], default_scene: str) -> None:
        self.password = password
        self.default_scene = default_scene
        self.ws: Optional[websockets.WebSocketClientProtocol] = None
        self._lock = asyncio.Lock()

        # BGM ducking state
        self.tts_active: bool = False
        self.meme_active: bool = False
        self.bgm_user_muted: Optional[bool] = None  # what user had set before we touched it
        self.bgm_muted_by_us: bool = False          # have we actually changed BGM mute?

    async def _connect(self) -> None:
        """
        Establish a fresh connection to OBS and perform the Hello/Identify handshake.
        """
        print("[INFO] Connecting to OBS WebSocket...", file=sys.stderr)
        ws = await websockets.connect(
            OBS_URL,
            subprotocols=["obswebsocket.json"],
        )

        # Hello (op=0)
        hello = json.loads(await ws.recv())
        d = hello.get("d", {})
        auth_info = d.get("authentication") or {}
        rpc_version = d.get("rpcVersion", 1)

        identify = {
            "op": 1,
            "d": {
                "rpcVersion": rpc_version,
                "eventSubscriptions": 0,  # no events needed
            },
        }

        if auth_info and self.password:
            challenge = auth_info.get("challenge", "")
            salt = auth_info.get("salt", "")
            identify["d"]["authentication"] = compute_auth(
                self.password, challenge, salt
            )

        await ws.send(json.dumps(identify))

        # Wait for Identified (op=2)
        while True:
            msg = json.loads(await ws.recv())
            op = msg.get("op")
            if op == 2:
                break
            # ignore events

        self.ws = ws
        print("[INFO] Connected and identified with OBS.", file=sys.stderr)

    async def _ensure_connected(self) -> None:
        """
        Ensure we have a live connection; reconnect if needed.
        """
        if self.ws is None or self.ws.closed:
            await self._connect()

    async def _obs_request(
        self,
        request_type: str,
        request_data: Optional[dict] = None,
        req_id: str = "1",
    ) -> dict:
        """
        Send a single OBS request and wait for its corresponding response.
        Returns the inner 'd' object from the response.
        """
        await self._ensure_connected()
        assert self.ws is not None

        payload = {
            "op": 6,
            "d": {
                "requestType": request_type,
                "requestId": req_id,
            },
        }
        if request_data:
            payload["d"]["requestData"] = request_data

        await self.ws.send(json.dumps(payload))

        while True:
            msg = json.loads(await self.ws.recv())
            op = msg.get("op")
            if op != 7:
                # event or something else; ignore
                continue

            d = msg.get("d", {})
            if d.get("requestId") != req_id:
                continue

            status = d.get("requestStatus", {})
            if status.get("result") is not True:
                code = status.get("code")
                comment = status.get("comment", "")
                raise RuntimeError(
                    f"OBS request {request_type} failed (code={code}, comment={comment})"
                )
            return d

    async def _wait_for_media_end(
        self,
        input_name: str,
        start_timeout: float = 2.0,
        end_timeout: float = 15.0,
    ) -> None:
        """
        Poll mediaState until:
          - we first see it in an active state (OPENING/BUFFERING/PLAYING), then
          - we see it leave that active set (ENDED/STOPPED/etc.).
        """
        loop = asyncio.get_running_loop()
        t0 = loop.time()

        active_states = {
            "OBS_WEBSOCKET_MEDIA_INPUT_STATE_OPENING",
            "OBS_WEBSOCKET_MEDIA_INPUT_STATE_BUFFERING",
            "OBS_WEBSOCKET_MEDIA_INPUT_STATE_PLAYING",
            "OBS_MEDIA_STATE_OPENING",
            "OBS_MEDIA_STATE_BUFFERING",
            "OBS_MEDIA_STATE_PLAYING",
        }

        seen_active = False
        last_state = None

        while True:
            resp = await self._obs_request(
                "GetMediaInputStatus",
                {"inputName": input_name},
                req_id="pollMediaStatus",
            )
            rd = resp.get("responseData", {})
            state = rd.get("mediaState")
            cursor = rd.get("mediaCursor")

            now = loop.time()

            if state != last_state:
                print(
                    f"[DEBUG] mediaState={state!r}, mediaCursor={cursor}",
                    file=sys.stderr,
                )
                last_state = state

            if not seen_active:
                # Phase 1: wait until it enters a "playing-ish" state.
                if state in active_states:
                    seen_active = True
                    t0 = now  # reset timer for end phase
                elif now - t0 > start_timeout:
                    print(
                        f"[DEBUG] wait_for_media_end: never saw active state "
                        f"within {start_timeout}s, giving up",
                        file=sys.stderr,
                    )
                    return
            else:
                # Phase 2: once active, wait until it leaves the active set.
                if state not in active_states:
                    return
                if now - t0 > end_timeout:
                    print(
                        f"[DEBUG] wait_for_media_end: still active after "
                        f"{end_timeout}s, giving up",
                        file=sys.stderr,
                    )
                    return

            await asyncio.sleep(0.05)

    async def _update_bgm_mute(self) -> None:
        """
        Centralised BGM mute logic:

        - If either meme_active or tts_active is True:
            ensure BGM is muted (recording original user mute state).
        - If neither is active:
            restore BGM to original user state, if we changed it.
        """
        # If nothing needs ducking, restore and bail.
        if not (self.meme_active or self.tts_active):
            if self.bgm_muted_by_us and self.bgm_user_muted is not None:
                try:
                    await self._obs_request(
                        "SetInputMute",
                        {"inputName": BGM_INPUT_NAME, "inputMuted": self.bgm_user_muted},
                        req_id="bgmRestore",
                    )
                    print(
                        f"[INFO] BGM '{BGM_INPUT_NAME}' mute restored to {self.bgm_user_muted}.",
                        file=sys.stderr,
                    )
                except Exception as e:
                    print(
                        f"[DEBUG] Failed to restore BGM '{BGM_INPUT_NAME}' mute state: {e}",
                        file=sys.stderr,
                    )
            self.bgm_muted_by_us = False
            self.bgm_user_muted = None
            return

        # We need BGM muted.
        if self.bgm_muted_by_us:
            # Already handled.
            return

        try:
            resp = await self._obs_request(
                "GetInputMute",
                {"inputName": BGM_INPUT_NAME},
                req_id="bgmGet",
            )
            rd = resp.get("responseData", {})
            prev_muted = rd.get("inputMuted")
            if prev_muted is None:
                print(
                    f"[DEBUG] BGM '{BGM_INPUT_NAME}' has no inputMuted field.",
                    file=sys.stderr,
                )
                return

            self.bgm_user_muted = bool(prev_muted)
            print(
                f"[DEBUG] BGM '{BGM_INPUT_NAME}' previous mute state: {self.bgm_user_muted}",
                file=sys.stderr,
            )

            if not prev_muted:
                await self._obs_request(
                    "SetInputMute",
                    {"inputName": BGM_INPUT_NAME, "inputMuted": True},
                    req_id="bgmMute",
                )
                print(
                    f"[INFO] BGM '{BGM_INPUT_NAME}' muted (active duck: meme={self.meme_active}, tts={self.tts_active}).",
                    file=sys.stderr,
                )
            else:
                print(
                    f"[INFO] BGM '{BGM_INPUT_NAME}' was already muted; leaving as is.",
                    file=sys.stderr,
                )

            self.bgm_muted_by_us = True
        except Exception as e:
            print(
                f"[DEBUG] Could not adjust BGM '{BGM_INPUT_NAME}': {e}",
                file=sys.stderr,
            )

    async def set_tts_active(self, active: bool) -> None:
        """
        Called by the NetTTS status watcher when TTS starts/stops.
        """
        self.tts_active = active
        print(f"[DEBUG] TTS active set to {active}", file=sys.stderr)
        await self._update_bgm_mute()

    async def set_track_text(self, text: str) -> None:
        """
        Update the FreeType2 text source TRACK_SOURCE_NAME with the given text.
        Only the 'text' field is changed; style is preserved.
        """
        try:
            await self._obs_request(
                "SetInputSettings",
                {
                    "inputName": TRACK_SOURCE_NAME,
                    "inputSettings": {"text": text},
                    "overlay": True,
                },
                req_id="trackUpdate",
            )
            print(f"[TRACK] Updated {TRACK_SOURCE_NAME} = {text!r}", file=sys.stderr)
        except Exception as e:
            print(f"[TRACK] Failed to update track text: {e}", file=sys.stderr)

    async def play_meme(self, meme_name: str, scene_name: Optional[str] = None) -> None:
        """
        Show the meme scene item, duck/mute BGM, restart the media, wait for it to finish,
        then restore BGM if nothing else (like TTS) is active, and hide the meme.
        Only one play at a time (protected by a lock).
        """
        async with self._lock:
            self.meme_active = True
            await self._update_bgm_mute()

            try:
                await self._ensure_connected()
                scene = scene_name or self.default_scene

                # 1) Get sceneItemId for this meme inside the chosen scene
                resp = await self._obs_request(
                    "GetSceneItemId",
                    {
                        "sceneName": scene,
                        "sourceName": meme_name,
                    },
                    req_id="getSceneItemId",
                )
                rd = resp.get("responseData", {})
                scene_item_id = rd.get("sceneItemId")
                if scene_item_id is None:
                    raise RuntimeError(
                        f"Could not find scene item '{meme_name}' in scene '{scene}'"
                    )

                # 2) Get media duration (may be None/0/useless)
                resp = await self._obs_request(
                    "GetMediaInputStatus",
                    {"inputName": meme_name},
                    req_id="getMediaStatus",
                )
                rd = resp.get("responseData", {})
                duration = rd.get("mediaDuration")
                print(
                    f"[DEBUG] mediaDuration for {meme_name!r}: {duration!r}",
                    file=sys.stderr,
                )

                duration_ms: Optional[int] = None
                try:
                    if duration is not None:
                        duration_ms = int(duration)
                        if duration_ms <= 0:
                            duration_ms = None
                except (TypeError, ValueError):
                    duration_ms = None

                # 3) Show + STOP + RESTART + wait + hide
                await self._obs_request(
                    "SetSceneItemEnabled",
                    {
                        "sceneName": scene,
                        "sceneItemId": scene_item_id,
                        "sceneItemEnabled": True,
                    },
                    req_id="enableSceneItem",
                )

                # Try STOP first (clean slate), but ignore failure.
                try:
                    await self._obs_request(
                        "TriggerMediaInputAction",
                        {
                            "inputName": meme_name,
                            "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP",
                        },
                        req_id="stopMedia",
                    )
                except RuntimeError as e:
                    print(f"[DEBUG] STOP action failed: {e}", file=sys.stderr)

                await self._obs_request(
                    "TriggerMediaInputAction",
                    {
                        "inputName": meme_name,
                        "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_RESTART",
                    },
                    req_id="restartMedia",
                )

                await asyncio.sleep(0.05)  # tiny delay before polling

                if duration_ms is not None:
                    await asyncio.sleep((duration_ms / 1000.0) + 0.1)
                else:
                    await self._wait_for_media_end(
                        meme_name,
                        start_timeout=2.0,
                        end_timeout=15.0,
                    )

                await self._obs_request(
                    "SetSceneItemEnabled",
                    {
                        "sceneName": scene,
                        "sceneItemId": scene_item_id,
                        "sceneItemEnabled": False,
                    },
                    req_id="disableSceneItem",
                )

            except websockets.ConnectionClosed:
                print(
                    "[WARN] OBS connection closed, will reconnect next time.",
                    file=sys.stderr,
                )
                if self.ws is not None:
                    await self.ws.close()
                self.ws = None
                raise
            except Exception as e:
                print(f"[ERROR] play_meme failed: {e}", file=sys.stderr)
                raise
            finally:
                # Meme finished; clear flag and update BGM according to remaining activity (e.g. TTS)
                self.meme_active = False
                await self._update_bgm_mute()


async def handle_client(reader: asyncio.StreamReader,
                        writer: asyncio.StreamWriter,
                        controller: ObsMemeController) -> None:
    addr = writer.get_extra_info("peername") or "unix-socket"
    print(f"[INFO] Client connected: {addr}", file=sys.stderr)
    try:
        while True:
            try:
                line = await reader.readline()
            except (ConnectionResetError, BrokenPipeError):
                # Client vanished mid-read
                break

            if not line:
                # EOF from client
                break

            cmd = line.decode("utf-8", errors="ignore").strip()
            if not cmd:
                continue

            # Special: "quit" closes this client connection only.
            if cmd.lower() in {"quit", "exit"}:
                break

            # TRACK_CLEAR: blank the track text
            if cmd.upper() == "TRACK_CLEAR":
                print("[INFO] TRACK_CLEAR command received", file=sys.stderr)
                await controller.set_track_text("")
                try:
                    writer.write(b"OK\n")
                    await writer.drain()
                except (ConnectionResetError, BrokenPipeError):
                    pass
                continue

            # TRACK <text>: set track text directly
            if cmd.upper().startswith("TRACK "):
                text = cmd[6:].strip()
                print(f"[INFO] TRACK command received: {text!r}", file=sys.stderr)
                await controller.set_track_text(text)
                try:
                    writer.write(b"OK\n")
                    await writer.drain()
                except (ConnectionResetError, BrokenPipeError):
                    pass
                continue

            # Support "meme" or "meme@scene"
            meme_name = cmd
            scene_name: Optional[str] = None
            if "@" in cmd:
                meme_name, scene_name = cmd.split("@", 1)
                meme_name = meme_name.strip()
                scene_name = scene_name.strip() or None

            print(
                f"[INFO] Request to play meme {meme_name!r}"
                + (f" in scene {scene_name!r}" if scene_name else ""),
                file=sys.stderr,
            )

            # Run the meme, then try to send a response if the client is still around
            try:
                await controller.play_meme(meme_name, scene_name)
                reply = b"OK\n"
            except Exception as e:
                err = f"ERROR: {e}\n"
                reply = err.encode("utf-8")

            try:
                writer.write(reply)
                await writer.drain()
            except (ConnectionResetError, BrokenPipeError):
                # Client closed before we could reply; nothing to do
                break

    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except (ConnectionResetError, BrokenPipeError):
            # Socket already dead; just log and move on
            print("[DEBUG] Client socket already closed.", file=sys.stderr)
        print(f"[INFO] Client disconnected: {addr}", file=sys.stderr)


async def nettts_status_watcher(controller: ObsMemeController) -> None:
    """
    Connect to NetTTS status server (port=NetTTS+1, default 5556) and
    watch for START/STOP lines to control TTS-based BGM ducking.
    """
    while True:
        try:
            print(
                f"[NETTTS] Connecting to {NETTTS_STATUS_HOST}:{NETTTS_STATUS_PORT}...",
                file=sys.stderr,
            )
            reader, writer = await asyncio.open_connection(
                NETTTS_STATUS_HOST, NETTTS_STATUS_PORT
            )
            print("[NETTTS] Connected to status server.", file=sys.stderr)

            try:
                while True:
                    line = await reader.readline()
                    if not line:
                        print("[NETTTS] Disconnected from status server.", file=sys.stderr)
                        break

                    cmd = line.decode("utf-8", errors="ignore").strip().upper()
                    if not cmd:
                        continue

                    print(f"[NETTTS] STATUS: {cmd}", file=sys.stderr)

                    if cmd == "START":
                        await controller.set_tts_active(True)
                    elif cmd == "STOP":
                        await controller.set_tts_active(False)
                    else:
                        print(
                            f"[NETTTS] Unknown status line: {cmd!r}",
                            file=sys.stderr,
                        )
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass

        except ConnectionRefusedError:
            print(
                "[NETTTS] Status server refused connection; retrying in 3s...",
                file=sys.stderr,
            )
        except Exception as e:
            print(f"[NETTTS] Error: {e}; retrying in 3s...", file=sys.stderr)

        await asyncio.sleep(3.0)


async def main_async(args: argparse.Namespace) -> None:
    # Clean up old socket if present
    if os.path.exists(args.socket):
        os.unlink(args.socket)

    controller = ObsMemeController(password=args.password,
                                   default_scene=args.scene)

    # Start NetTTS status watcher
    asyncio.create_task(nettts_status_watcher(controller))

    # Unix socket server for meme commands
    server = await asyncio.start_unix_server(
        lambda r, w: handle_client(r, w, controller),
        path=args.socket,
    )
    print(f"[INFO] Meme daemon listening on {args.socket}", file=sys.stderr)

    async with server:
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Long-running OBS meme daemon: listens on a Unix socket for meme names and plays them."
    )
    parser.add_argument(
        "--password",
        help="OBS WebSocket password (as set in OBS). Leave empty if no password.",
        default=None,
    )
    parser.add_argument(
        "--scene",
        help="Default scene name that contains meme sources.",
        default=DEFAULT_SCENE_NAME,
    )
    parser.add_argument(
        "--socket",
        help=f"Unix socket path to listen on (default: {DEFAULT_SOCKET_PATH}).",
        default=DEFAULT_SOCKET_PATH,
    )
    parser.add_argument(
        "--password-file",
        help="Read OBS WebSocket password from a file (recommended).",
        default=None,
    )
    args = parser.parse_args()

    if args.password_file and not args.password:
        with open(args.password_file, "r", encoding="utf-8") as f:
            args.password = f.read().strip()


    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        print("\n[INFO] Meme daemon shutting down (KeyboardInterrupt).", file=sys.stderr)


if __name__ == "__main__":
    main()
