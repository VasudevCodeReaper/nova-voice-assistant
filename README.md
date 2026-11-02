# Nova — a local Windows voice assistant

> Experimental local Windows assistant. It opens only configured apps, folders,
> web searches, modes, and tasks; it is not a general-purpose command shell.

Nova is a small, configurable Windows assistant that listens through your microphone and can:

- open a short, user-controlled list of apps and folders;
- find non-executable files in Desktop, Documents, and Downloads, then ask before opening one;
- search the web in your default browser; and
- activate named, safe modes that launch only the actions you configure; and
- run named, safe multi-step tasks you define yourself.

It uses [SYSTRAN faster-whisper](https://github.com/SYSTRAN/faster-whisper) for local Whisper speech-to-text and Windows voice output. The included English Whisper model runs on your PC; no account, API key, or cloud transcription is used. The first setup downloads the model once (about 150 MB).

## Start it

Double-click `Start-Nova.cmd`. Wait until the console says **“Whisper is ready”**. Nova stays on standby and does not open the microphone until you **hold F8 for half a second and release it**. Then say:

> “Nova”

Nova replies, “I hear you,” and keeps listening for the next 60 seconds. During that conversation you can speak follow-up commands without repeating “Nova.” Say “stop listening” to end the conversation, or hold F8 again to begin another one. Nova waits for its spoken reply to finish before recording your next answer, so it does not transcribe itself.

For example:

- “Nova, open calculator”
- “Nova, open my documents folder”
- “Nova, search for train times to Delhi”
- “Nova, find budget”
- “Nova, focus mode”
- “Nova, run start work” → “Nova, confirm”
- “Nova, help”
- “stop listening” (while in a conversation)

While a conversation is active, Nova can answer the local time and date aloud. Other ordinary questions such as “What is photosynthesis?” open a normal web search and say what it is searching for; this local-first build does not claim to generate factual answers from a cloud AI service.

To keep the microphone open continuously instead, run:

```powershell
.\Nova.ps1 -ContinuousListening
```

You can also use a harmless typed test from PowerShell:

```powershell
.\Nova.ps1 -Command 'Nova, search for coffee shops' -DryRun -NoSpeech
```

## Make it yours

Edit `nova.config.json` in Notepad. The name you say, app aliases, trusted folders, search provider, hotkey, modes, run tasks, and Whisper microphone settings are all there. By default, the activation key is `F8`, held for 500 ms. You can change it under `hotkey`:

```json
"hotkey": {
  "key": "F8",
  "holdMilliseconds": 500,
  "listenSeconds": 8,
  "sessionSeconds": 60
}
```

Use `F1` through `F12`, `Right Ctrl`, `Left Ctrl`, `Scroll Lock`, or a Windows virtual-key number. Pick a key that does not interfere with an application you use frequently.

The configured Whisper microphone is device `7`, `Microphone (AB13X USB Audio), Windows DirectSound`. To use a different input, replace `whisper.inputDevice` with its numeric device index from `python -c "import sounddevice as sd; print(sd.query_devices())"`, or remove that line to use Windows’ current default microphone.

For example, to add an app, add an alias under `apps`:

```json
"visual studio code": "C:\\Users\\YOUR-NAME\\AppData\\Local\\Programs\\Microsoft VS Code\\Code.exe"
```

Then say “Nova, open Visual Studio Code.” To add a custom mode or named run task, add only `app`, `path`, or `uri` actions. For example:

```json
"tasks": {
  "start work": {
    "say": "Starting your work setup.",
    "actions": [
      { "type": "path", "target": "documents" },
      { "type": "app", "target": "browser" }
    ]
  }
}
```

Say “Nova, run start work,” then confirm. Nova deliberately does **not** support arbitrary PowerShell, shell commands, destructive file actions, installs, or sending messages. A spoken phrase such as “run delete everything” will not be executed unless you explicitly define a task of that exact name in the config—and you should never add destructive tasks.

## Safe operating model

Your spoken words are treated as data, never as executable commands. Nova launches only aliases, mode actions, and named task actions in `nova.config.json`; file lookup searches only the listed `fileSearchRoots` and blocks scripts and executables. It asks before opening a found file and offers numbered choices when there are several matches. To keep a large folder from locking up the assistant, the local lookup is capped; if it cannot find a match promptly, Nova opens a visible File Explorer search instead.

The provided Focus and Presentation modes open Windows settings instead of silently modifying system-wide notification or display settings. That keeps OS-level choices visible and reversible.

## Troubleshooting

- **It cannot hear you:** Speak after Nova says “Listening.” Nova reports its selected Whisper microphone when it starts; confirm that this device’s Windows input meter moves. You can change `whisper.inputDevice` in the config.
- **The F8 key does nothing:** Keep the Nova console window open, make sure F8 is not captured by another full-screen app, and try holding it for slightly longer than half a second. Change `hotkey.key` if it conflicts with an app.
- **A command is ignored:** At standby, activate the hotkey first and speak the configured wake name (default: “Nova”). During the 60-second conversation, follow-up commands do not need the wake name. You can set `wakeWordRequired` to `false`, though that makes accidental triggers more likely.
- **An app will not open:** Verify its path/URI in `nova.config.json` and try it from a PowerShell command with `-DryRun` first.
- **Whisper is loading:** The model is cached after the first successful launch. The compact `base.en` model prioritizes speed; you can later change `whisper.model` to `small.en` for greater accuracy at the cost of more disk space and slower responses.

## Verify the package

Run:

```powershell
.\test-nova.ps1
```

The PowerShell smoke tests use dry-run mode; they do not open apps, search the web, speak, or use the microphone. To verify Whisper and the configured microphone, run `python .\NovaWhisper.py --prepare`.

## License

MIT. See [LICENSE](LICENSE).
