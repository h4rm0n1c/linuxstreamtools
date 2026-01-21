# OBS stuff

Automations and helper scripts that talk to OBS over obs-websocket for quick gag cuts, meme triggers, and related stream workflows.

## Tools

### memen_demon

Long-running OBS websocket daemon that listens on a Unix socket and plays meme sources on demand, with optional NetTTS status listening for ducking behavior. It pairs with `streamlink_3.sh` and NetTTS for background music control while memes/voice are active.

- Daemon script: `memen_demon.sh` (Python).
- Convenience wrapper/service script: `memen_demon` (shell).
- Default OBS scene: `memes`.
- Default socket: `/tmp/obs_meme_daemon.sock`.

**OBS setup**

1. Enable obs-websocket (Tools → WebSocket Server Settings).
2. Create a scene named `memes` (or pass `--scene`).
3. Add meme sources to that scene (typically Media Sources). The *source name* is the meme name you will send.
4. (Optional) Add an audio input named `BGM` so the daemon can duck/mute background audio while memes/TTS play.
5. (Optional) Add a text source named `CurrentTrack` if you want track display updates.

**Integration notes**

- When `streamlink_3.sh` is running, it typically owns the background music source (`BGM`) and track text (`CurrentTrack`). `memen_demon` will mute/unmute `BGM` during memes and NetTTS speech, then restore the previous mute state when idle.
- The NetTTS status server is expected at `127.0.0.1:5556` and should emit `START`/`STOP` lines. This allows `memen_demon` to duck `BGM` while speech is active.

**Usage**

```sh
# start the daemon with a stored OBS websocket password
./memen_demon setpassword
./memen_demon start

# trigger a meme by name via the Unix socket
./memen_demon send airhorn

# trigger a meme in a specific scene
./memen_demon send airhorn@alt_memes
```

**Prereqs (Debian/Devuan)**

```sh
sudo apt install python3-websockets socat
```

You also need obs-websocket enabled in OBS (v5+).

### take my cut, please!

`takemycutplease.py` cuts to an "it stinks" scene, plays a clip, hides the embedded previous-scene layer at a timed beat, and then cuts back to whatever you were showing. It is designed to work alongside `memen_demon` (shares the same OBS password file by default).

**OBS setup**

1. Enable obs-websocket (Tools → WebSocket Server Settings).
2. Create a scene named `itstinks` (or pass `--itstinks-scene`).
3. Add a Media Source named `it_stinks_clip` containing the Jay Sherman clip.
4. Add a Source Clone input named `PrevSceneClone` (input type: Source Clone) and set it to your current program scene. The script will update the clone target dynamically.
5. Add a scene item named `PreviousScene` that displays the clone above/below the clip as desired. This is the layer the script hides at the `--hide-delay` timestamp.

**Usage**

```sh
python3 takemycutplease.py \
  --itstinks-scene itstinks \
  --clip-input it_stinks_clip
```

**Prereqs (Debian/Devuan)**

```sh
sudo apt install python3-websockets
```

You also need obs-websocket enabled in OBS (v5+).
