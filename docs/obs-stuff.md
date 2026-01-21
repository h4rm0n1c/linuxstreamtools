# OBS tools notes

This repo includes OBS-focused scripts under `obs_stuff/`. They are meant to work together for meme triggers, cutaway gags, and NetTTS/Streamlink integrations.

## Overview

- **memen_demon**: Long-running OBS websocket daemon that listens on a Unix socket for meme names and plays them in a dedicated scene. It can also listen to NetTTS status and duck/mute background music while speech or memes are active.
- **take my cut, please!**: A one-shot script that cuts to an "it stinks" scene, plays the clip, hides the embedded previous-scene layer at a timed beat, and returns to the previous program scene.

## Recommended setup

### memen_demon

1. Enable obs-websocket in OBS (Tools → WebSocket Server Settings).
2. Create a scene named `memes` (or pass `--scene` to the daemon).
3. Add your meme Media Sources to the scene. The source name is the trigger string you send.
4. (Optional) Add an audio input named `BGM` so the daemon can duck/mute background audio while memes/TTS play.
5. (Optional) Add a text source named `CurrentTrack` for track display updates.
6. Store the websocket password with the wrapper so both scripts can reuse it:

```sh
cd obs_stuff
./memen_demon setpassword
```

7. Start the daemon and test a meme trigger:

```sh
./memen_demon start
./memen_demon send airhorn
```

If you need to target another scene, send `meme_name@scene_name`.

**How this interacts with streamlink_3.sh**

- `streamlink_3.sh` typically drives the `BGM` input and `CurrentTrack` text updates for background music.
- When `memen_demon` detects a meme or NetTTS speech, it mutes `BGM`. Once everything is idle, it restores the prior mute state so Streamlink background music resumes as before.

### take my cut, please!

1. Create a scene named `itstinks` (or pass `--itstinks-scene`).
2. Add a Media Source named `it_stinks_clip` and make sure it plays the Jay Sherman clip. The default configuration expects the ~7-second cut from "The Critic" (often sourced from https://www.youtube.com/watch?v=xIx8JNoyRq8), so download a local copy and point the Media Source to that file.
3. Add a Source Clone input named `PrevSceneClone` (input type: Source Clone). The script will update its target to match the current program scene.
4. Add a scene item named `PreviousScene` that displays the clone in the layout you want to roast. Keep it positioned above the clip (or otherwise ordered the way you want it to appear), because it is the layer hidden at the `--hide-delay` timestamp.

Run the script:

```sh
python3 takemycutplease.py --itstinks-scene itstinks --clip-input it_stinks_clip
```

## NetTTS interaction

`memen_demon` connects to the NetTTS status server at `127.0.0.1:5556` and listens for `START`/`STOP` lines. When speech begins, it will mute `BGM`; when speech ends and no meme is playing, it restores the previous mute state.

## Debian/Devuan prerequisites

```sh
sudo apt install python3-websockets socat
```
