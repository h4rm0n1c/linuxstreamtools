#!/usr/bin/env python3
import argparse
import asyncio
import base64
import hashlib
import json
import os
import sys
from typing import Optional, Dict, Any, Tuple

import websockets  # python3-websockets


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


class ObsClient:
    def __init__(self, url: str, password: Optional[str]) -> None:
        self.url = url
        self.password = password
        self.ws: Optional[websockets.WebSocketClientProtocol] = None

        # Serialize send/recv on the websocket to prevent cross-task recv corruption.
        self._req_lock = asyncio.Lock()
        self._req_seq = 0

    async def connect(self) -> None:
        print(f"[INFO] Connecting to OBS WebSocket at {self.url} ...", file=sys.stderr)
        ws = await websockets.connect(self.url, subprotocols=["obswebsocket.json"])

        # Hello (op=0)
        hello = json.loads(await ws.recv())
        d = hello.get("d", {})
        auth_info = d.get("authentication") or {}
        rpc_version = d.get("rpcVersion", 1)

        identify: Dict[str, Any] = {
            "op": 1,
            "d": {
                "rpcVersion": rpc_version,
                "eventSubscriptions": 0,
            },
        }

        if auth_info and self.password:
            challenge = auth_info.get("challenge", "")
            salt = auth_info.get("salt", "")
            identify["d"]["authentication"] = compute_auth(self.password, challenge, salt)

        await ws.send(json.dumps(identify))

        # Wait for Identified (op=2)
        while True:
            msg = json.loads(await ws.recv())
            if msg.get("op") == 2:
                break

        self.ws = ws
        print("[INFO] Connected and identified with OBS.", file=sys.stderr)

    async def ensure_connected(self) -> None:
        if self.ws is None or self.ws.closed:
            await self.connect()

    def _mk_request_id(self, prefix: str) -> str:
        self._req_seq += 1
        p = prefix if prefix and prefix != "1" else "req"
        return f"{p}-{self._req_seq}"

    async def request(self, request_type: str, request_data: Optional[dict] = None, req_id: str = "1") -> dict:
        async with self._req_lock:
            await self.ensure_connected()
            assert self.ws is not None

            rid = self._mk_request_id(req_id)

            payload: Dict[str, Any] = {
                "op": 6,
                "d": {
                    "requestType": request_type,
                    "requestId": rid,
                },
            }
            if request_data is not None:
                payload["d"]["requestData"] = request_data

            await self.ws.send(json.dumps(payload))

            while True:
                msg = json.loads(await self.ws.recv())
                if msg.get("op") != 7:
                    continue

                d = msg.get("d", {})
                if d.get("requestId") != rid:
                    continue

                status = d.get("requestStatus", {})
                if status.get("result") is not True:
                    code = status.get("code")
                    comment = status.get("comment", "")
                    raise RuntimeError(f"OBS request {request_type} failed (code={code}, comment={comment})")

                return d

    async def close(self) -> None:
        async with self._req_lock:
            if self.ws is not None and not self.ws.closed:
                await self.ws.close()
            self.ws = None


async def get_scene_item_id(obs: ObsClient, scene_name: str, source_name: str, req_id: str) -> int:
    resp = await obs.request(
        "GetSceneItemId",
        {"sceneName": scene_name, "sourceName": source_name},
        req_id=req_id,
    )
    rd = resp.get("responseData", {})
    sid = rd.get("sceneItemId")
    if sid is None:
        raise RuntimeError(f"Could not find scene item '{source_name}' in scene '{scene_name}'")
    return int(sid)


async def set_scene_item_enabled(obs: ObsClient, scene_name: str, scene_item_id: int, enabled: bool, req_id: str) -> None:
    await obs.request(
        "SetSceneItemEnabled",
        {"sceneName": scene_name, "sceneItemId": scene_item_id, "sceneItemEnabled": bool(enabled)},
        req_id=req_id,
    )


async def get_scene_transition_override(obs: ObsClient, scene_name: str, req_id: str) -> Tuple[Optional[str], Optional[int]]:
    resp = await obs.request(
        "GetSceneSceneTransitionOverride",
        {"sceneName": scene_name},
        req_id=req_id,
    )
    rd = resp.get("responseData", {})
    name = rd.get("transitionName")
    dur = rd.get("transitionDuration")
    name_out = name if (isinstance(name, str) and name) else None
    dur_out = int(dur) if dur is not None else None
    return (name_out, dur_out)


async def set_scene_transition_override(
    obs: ObsClient,
    scene_name: str,
    transition_name: Optional[str],
    transition_duration: Optional[int],
    req_id: str,
) -> None:
    await obs.request(
        "SetSceneSceneTransitionOverride",
        {
            "sceneName": scene_name,
            "transitionName": transition_name,
            "transitionDuration": transition_duration,
        },
        req_id=req_id,
    )


async def try_force_cut_transition(obs: ObsClient) -> Tuple[Optional[str], Optional[int]]:
    try:
        resp = await obs.request("GetCurrentSceneTransition", None, req_id="getTrans")
        saved_name = resp.get("responseData", {}).get("transitionName")

        resp = await obs.request("GetCurrentSceneTransitionDuration", None, req_id="getTransDur")
        saved_dur = resp.get("responseData", {}).get("transitionDuration")
        saved_dur_ms = int(saved_dur) if saved_dur is not None else None

        try:
            await obs.request("SetCurrentSceneTransition", {"transitionName": "Cut"}, req_id="setCut")
        except Exception as e:
            print(f"[DEBUG] Couldn't set transition to Cut: {e}", file=sys.stderr)

        try:
            await obs.request("SetCurrentSceneTransitionDuration", {"transitionDuration": 0}, req_id="setCutDur")
        except Exception as e:
            print(f"[DEBUG] Couldn't set Cut duration: {e}", file=sys.stderr)

        return (saved_name, saved_dur_ms)
    except Exception as e:
        print(f"[DEBUG] Transition save/force cut failed: {e}", file=sys.stderr)
        return (None, None)


async def restore_transition(obs: ObsClient, saved: Tuple[Optional[str], Optional[int]]) -> None:
    name, dur_ms = saved
    if not name and dur_ms is None:
        return
    try:
        if name:
            await obs.request("SetCurrentSceneTransition", {"transitionName": name}, req_id="restoreTrans")
        if dur_ms is not None:
            await obs.request("SetCurrentSceneTransitionDuration", {"transitionDuration": int(dur_ms)}, req_id="restoreDur")
    except Exception as e:
        print(f"[DEBUG] Transition restore failed (ignored): {e}", file=sys.stderr)


async def get_media_status(obs: ObsClient, input_name: str) -> Tuple[Optional[str], Optional[int], Optional[int]]:
    resp = await obs.request("GetMediaInputStatus", {"inputName": input_name}, req_id="getMedia")
    rd = resp.get("responseData", {}) or {}
    state = rd.get("mediaState")
    cursor = rd.get("mediaCursor")
    dur = rd.get("mediaDuration")
    try:
        cursor_i = int(cursor) if cursor is not None else None
    except Exception:
        cursor_i = None
    try:
        dur_i = int(dur) if dur is not None else None
    except Exception:
        dur_i = None
    return (state, cursor_i, dur_i)


async def hold_until_clip_done_or_fallback(
    obs: ObsClient,
    itstinks_scene: str,
    clip_input: str,
    prev_scene_item_id: int,
    hide_delay_s: float,
    fallback_duration_ms: int,
    end_timeout_s: float,
) -> None:
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

    pad_s = 0.15
    fallback_s = (fallback_duration_ms / 1000.0) + pad_s
    max_s = max(fallback_s, end_timeout_s)

    hidden = False
    seen_active = False
    last_state = None

    while True:
        now = loop.time()
        elapsed = now - t0

        if (not hidden) and (elapsed >= hide_delay_s):
            try:
                await set_scene_item_enabled(obs, itstinks_scene, prev_scene_item_id, False, req_id="hidePrev")
                print(f"[INFO] Hid PreviousScene in itstinks at +{hide_delay_s:.3f}s", file=sys.stderr)
            except Exception as e:
                print(f"[DEBUG] hide failed (ignored): {e}", file=sys.stderr)
            hidden = True

        try:
            state, cursor, dur = await get_media_status(obs, clip_input)
        except Exception as e:
            print(f"[DEBUG] GetMediaInputStatus failed (ignored): {e}", file=sys.stderr)
            state, cursor, dur = (None, None, None)

        if state != last_state:
            print(f"[DEBUG] mediaState={state!r}, cursor={cursor}, dur={dur}", file=sys.stderr)
            last_state = state

        if state in active_states:
            seen_active = True

        ended_by_obs = False
        if seen_active and (state is not None) and (state not in active_states):
            ended_by_obs = True
        if dur is not None and dur > 0 and cursor is not None and cursor >= (dur - 50):
            ended_by_obs = True

        if ended_by_obs and elapsed >= fallback_s:
            return

        if elapsed >= fallback_s:
            return

        if elapsed >= max_s:
            return

        await asyncio.sleep(0.05)


async def takemycutplease(
    obs: ObsClient,
    itstinks_scene: str,
    clip_input: str,
    prevscene_scene_source_name: str,
    previousscene_clone_input: str,
    hide_delay_s: float,
    fallback_duration_ms: int,
    preload_ms: int,
    force_cut: bool,
) -> None:
    resp = await obs.request("GetCurrentProgramScene", None, req_id="getProgramScene")
    return_scene = resp.get("responseData", {}).get("currentProgramSceneName")
    if not return_scene:
        raise RuntimeError("Couldn't determine current program scene name")

    if return_scene == itstinks_scene:
        print(f"[WARN] Already on '{itstinks_scene}'. Refusing to recurse reality.", file=sys.stderr)
        return

    print(f"[INFO] Return program scene: {return_scene!r}", file=sys.stderr)

    clone_target = return_scene
    if return_scene == "PreviousScene":
        try:
            r = await obs.request("GetInputSettings", {"inputName": previousscene_clone_input}, req_id="getCloneSettings")
            s = r.get("responseData", {}).get("inputSettings", {}) or {}
            c = s.get("clone")
            if isinstance(c, str) and c and c != "PreviousScene":
                clone_target = c
                print(f"[INFO] On 'PreviousScene' wrapper; using clone target {clone_target!r}", file=sys.stderr)
        except Exception as e:
            print(f"[DEBUG] Could not resolve wrapper clone target (ignored): {e}", file=sys.stderr)

    saved_from_ov: Tuple[Optional[str], Optional[int]] = (None, None)
    saved_itstinks_ov: Tuple[Optional[str], Optional[int]] = (None, None)
    overrides_disabled = False

    try:
        saved_from_ov = await get_scene_transition_override(obs, return_scene, req_id="getOvFrom")
        saved_itstinks_ov = await get_scene_transition_override(obs, itstinks_scene, req_id="getOvItstinks")

        await set_scene_transition_override(obs, return_scene, None, None, req_id="clrOvFrom")
        await set_scene_transition_override(obs, itstinks_scene, None, None, req_id="clrOvItstinks")

        overrides_disabled = True
        print(f"[INFO] Temporarily cleared transition overrides for {return_scene!r} and {itstinks_scene!r}", file=sys.stderr)
    except Exception as e:
        print(f"[DEBUG] Could not clear/inspect scene transition overrides (continuing): {e}", file=sys.stderr)
        overrides_disabled = False

    saved_trans = (None, None)
    if force_cut:
        saved_trans = await try_force_cut_transition(obs)

    clip_scene_item_id: Optional[int] = None
    prev_scene_item_id: Optional[int] = None

    try:
        await obs.request(
            "SetInputSettings",
            {
                "inputName": previousscene_clone_input,
                "inputSettings": {"clone": clone_target},
                "overlay": True,
            },
            req_id="setCloneTarget",
        )
        print(f"[INFO] {previousscene_clone_input} clone -> {clone_target!r}", file=sys.stderr)

        clip_scene_item_id = await get_scene_item_id(obs, itstinks_scene, clip_input, req_id="getClipItemId")
        prev_scene_item_id = await get_scene_item_id(obs, itstinks_scene, prevscene_scene_source_name, req_id="getPrevItemId")

        await set_scene_item_enabled(obs, itstinks_scene, prev_scene_item_id, True, req_id="enablePrevAtStart")
        await set_scene_item_enabled(obs, itstinks_scene, clip_scene_item_id, True, req_id="enableClipAtStart")

        # Preload: restart clip before switching to reduce black flicker
        try:
            await obs.request(
                "TriggerMediaInputAction",
                {"inputName": clip_input, "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_STOP"},
                req_id="stopClipPre",
            )
        except Exception:
            pass

        await asyncio.sleep(0.02)

        t_restart = asyncio.get_running_loop().time()

        await obs.request(
            "TriggerMediaInputAction",
            {"inputName": clip_input, "mediaAction": "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_RESTART"},
            req_id="restartClipPre",
        )

        if preload_ms > 0:
            await asyncio.sleep(preload_ms / 1000.0)

        await obs.request("SetCurrentProgramScene", {"sceneName": itstinks_scene}, req_id="goItstinks")
        print(f"[INFO] Switched to {itstinks_scene!r}", file=sys.stderr)

        already_elapsed = asyncio.get_running_loop().time() - t_restart
        effective_hide = max(0.0, hide_delay_s - max(0.0, already_elapsed))

        await hold_until_clip_done_or_fallback(
            obs=obs,
            itstinks_scene=itstinks_scene,
            clip_input=clip_input,
            prev_scene_item_id=prev_scene_item_id,
            hide_delay_s=effective_hide,
            fallback_duration_ms=fallback_duration_ms,
            end_timeout_s=15.0,
        )

        try:
            await set_scene_item_enabled(obs, itstinks_scene, clip_scene_item_id, False, req_id="disableClipEnd")
        except Exception as e:
            print(f"[DEBUG] disable clip failed (ignored): {e}", file=sys.stderr)

        await obs.request("SetCurrentProgramScene", {"sceneName": return_scene}, req_id="goBack")
        print(f"[INFO] Returned to {return_scene!r}", file=sys.stderr)

        try:
            await set_scene_item_enabled(obs, itstinks_scene, prev_scene_item_id, True, req_id="resetPrevVisible")
        except Exception as e:
            print(f"[DEBUG] reset prevscene visibility failed (ignored): {e}", file=sys.stderr)

    finally:
        try:
            cur = await obs.request("GetCurrentProgramScene", None, req_id="getProgramSceneFinally")
            cur_name = cur.get("responseData", {}).get("currentProgramSceneName")
        except Exception:
            cur_name = None

        if cur_name == itstinks_scene:
            try:
                await obs.request("SetCurrentProgramScene", {"sceneName": return_scene}, req_id="emergencyBack")
                print(f"[WARN] Emergency return to {return_scene!r}", file=sys.stderr)
            except Exception as e:
                print(f"[DEBUG] Emergency return failed (ignored): {e}", file=sys.stderr)

        if overrides_disabled:
            try:
                await set_scene_transition_override(obs, itstinks_scene, saved_itstinks_ov[0], saved_itstinks_ov[1], req_id="rstOvItstinks")
                await set_scene_transition_override(obs, return_scene, saved_from_ov[0], saved_from_ov[1], req_id="rstOvFrom")
                print(f"[INFO] Restored transition overrides for {return_scene!r} and {itstinks_scene!r}", file=sys.stderr)
            except Exception as e:
                print(f"[DEBUG] Failed to restore scene transition overrides (ignored): {e}", file=sys.stderr)

        if force_cut:
            await restore_transition(obs, saved_trans)

        if prev_scene_item_id is not None:
            try:
                await set_scene_item_enabled(obs, itstinks_scene, prev_scene_item_id, True, req_id="finallyResetPrevVisible")
            except Exception:
                pass


def main() -> None:
    p = argparse.ArgumentParser(description="takemycutplease: cut to itstinks, play clip, cut back to previous scene.")
    p.add_argument("--url", default="ws://127.0.0.1:4455", help="OBS WebSocket URL")
    p.add_argument("--password", default=None, help="OBS WebSocket password (optional)")
    p.add_argument(
        "--password-file",
        default="~/.config/memen_demon/obs_password",
        help="Read OBS WebSocket password from a file (default: ~/.config/memen_demon/obs_password)",
    )
    p.add_argument("--itstinks-scene", default="itstinks", help="Scene to cut to")
    p.add_argument("--clip-input", default="it_stinks_clip", help="Media input name to restart/wait on")
    p.add_argument("--prevscene-source", default="PreviousScene", help="Scene-item source name inside itstinks to hide at timestamp")
    p.add_argument("--clone-input", default="PrevSceneClone", help="Source Clone input name to point at previous scene")
    p.add_argument("--hide-delay", type=float, default=2.7, help="Seconds into the clip to hide PreviousScene (default 2.7)")
    p.add_argument("--fallback-ms", type=int, default=7500, help="Clip length in ms used as a hard floor (default 7500)")
    p.add_argument("--preload-ms", type=int, default=30, help="Restart clip this many ms BEFORE switching scenes (default 30)")
    p.add_argument("--no-force-cut", action="store_true", help="Don't try to force transition to Cut temporarily")
    args = p.parse_args()

    # Expand ~ in the default (and any user-provided) password file path.
    if args.password_file:
        args.password_file = os.path.expanduser(args.password_file)

    if args.password_file and not args.password:
        with open(args.password_file, "r", encoding="utf-8") as f:
            args.password = f.read().strip()

    async def runner() -> None:
        obs = ObsClient(args.url, args.password)
        try:
            await takemycutplease(
                obs=obs,
                itstinks_scene=args.itstinks_scene,
                clip_input=args.clip_input,
                prevscene_scene_source_name=args.prevscene_source,
                previousscene_clone_input=args.clone_input,
                hide_delay_s=float(args.hide_delay),
                fallback_duration_ms=int(args.fallback_ms),
                preload_ms=int(args.preload_ms),
                force_cut=not bool(args.no_force_cut),
            )
        finally:
            await obs.close()

    try:
        asyncio.run(runner())
    except KeyboardInterrupt:
        print("\n[INFO] Interrupted.", file=sys.stderr)


if __name__ == "__main__":
    main()
