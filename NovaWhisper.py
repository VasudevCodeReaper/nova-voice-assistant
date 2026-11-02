#!/usr/bin/env python3
"""Local Whisper voice layer for Nova.

F8 -> local microphone recording -> Whisper transcription -> safe Nova command
router. No transcript is ever sent to a shell or an online service.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import webbrowser
from collections import deque
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel
from scipy.signal import resample_poly


ROOT = Path(__file__).resolve().parent
SPEAKER = ROOT / "Speak-Nova.ps1"
BLOCK_SIZE = 1024
WHISPER_SAMPLE_RATE = 16_000
BLOCKED_EXTENSIONS = {".exe", ".msi", ".bat", ".cmd", ".ps1", ".vbs", ".js", ".jse", ".wsf", ".scr", ".com"}
SAFE_URI_PREFIXES = ("https:", "http:", "ms-settings:", "ms-clock:", "search-ms:")


def log(message: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower().replace("’", "'")).strip(" ,.!?:;")


def expand(value: str) -> str:
    return os.path.expandvars(value)


def item(mapping: dict[str, Any] | None, name: str, default: Any = None) -> Any:
    if not mapping:
        return default
    wanted = name.casefold()
    for key, value in mapping.items():
        if key.casefold() == wanted:
            return value
    return default


def virtual_key(key: str) -> int:
    key = key.strip().upper().replace(" ", "")
    match = re.fullmatch(r"F([1-9]|1[0-2])", key)
    if match:
        return 111 + int(match.group(1))
    named = {"RIGHTCTRL": 0xA3, "RIGHTCONTROL": 0xA3, "LEFTCTRL": 0xA2, "LEFTCONTROL": 0xA2, "SCROLLLOCK": 0x91}
    if key in named:
        return named[key]
    if key.isdigit() and 1 <= int(key) <= 254:
        return int(key)
    raise ValueError("hotkey.key must be F1 through F12, Right Ctrl, Left Ctrl, Scroll Lock, or a virtual-key number")


class VoiceCapture:
    def __init__(self, settings: dict[str, Any]) -> None:
        self.settings = settings
        self.model: WhisperModel | None = None
        self.device = settings.get("inputDevice")
        self.sample_rate = int(settings.get("captureSampleRate", 44_100))
        self.threshold = float(settings.get("voiceThreshold", 0.012))
        self.end_silence = float(settings.get("endSilenceSeconds", 0.85))
        self.max_seconds = float(settings.get("maxUtteranceSeconds", 10))
        self.language = str(settings.get("language", "en"))
        self.model_name = str(settings.get("model", "base.en"))

    def prepare(self) -> None:
        if self.model is not None:
            return
        log(f"Loading local Whisper model '{self.model_name}' (first launch may download it once)...")
        self.model = WhisperModel(self.model_name, device="cpu", compute_type="int8")
        sd.check_input_settings(device=self.device, channels=1, samplerate=self.sample_rate, dtype="float32")
        device_name = sd.query_devices(self.device, "input")["name"]
        log(f"Whisper is ready. Microphone: {device_name} at {self.sample_rate} Hz")

    def record_and_transcribe(self) -> str | None:
        self.prepare()
        chunks: list[np.ndarray] = []
        started = False
        last_voice = 0.0
        peak_level = 0.0
        deadline = time.monotonic() + self.max_seconds
        pre_roll: deque[np.ndarray] = deque(maxlen=5)

        try:
            with sd.InputStream(
                device=self.device,
                samplerate=self.sample_rate,
                channels=1,
                dtype="float32",
                blocksize=BLOCK_SIZE,
            ) as stream:
                while time.monotonic() < deadline:
                    block, overflowed = stream.read(BLOCK_SIZE)
                    if overflowed:
                        log("Microphone buffer overflow; trying to continue.")
                    # USB microphones can report a quiet signal even though
                    # Windows' monitoring playback sounds normal. Consider a
                    # short peak as well as average loudness; Whisper's own
                    # VAD still filters non-speech before transcription.
                    level = float(np.sqrt(np.mean(np.square(block))))
                    peak = float(np.max(np.abs(block)))
                    peak_level = max(peak_level, peak)
                    now = time.monotonic()
                    if not started:
                        pre_roll.append(block.copy())
                        if level >= self.threshold or peak >= self.threshold:
                            started = True
                            last_voice = now
                            chunks.extend(pre_roll)
                    else:
                        chunks.append(block.copy())
                        if level >= self.threshold or peak >= self.threshold:
                            last_voice = now
                        elif now - last_voice >= self.end_silence:
                            break
        except Exception as error:
            log(f"Could not read the microphone: {error}")
            return None

        if not started or not chunks:
            log(f"No speech crossed Nova's sensitivity threshold. Peak input level was {peak_level:.5f}.")
            return None

        audio = np.concatenate(chunks, axis=0).reshape(-1).astype(np.float32, copy=False)
        # Capture at the USB microphone's native rate to avoid driver-side
        # resampling artifacts, then convert cleanly to Whisper's 16 kHz input.
        if self.sample_rate != WHISPER_SAMPLE_RATE:
            audio = resample_poly(audio, WHISPER_SAMPLE_RATE, self.sample_rate).astype(np.float32, copy=False)
        try:
            assert self.model is not None
            segments, _ = self.model.transcribe(
                audio,
                language=self.language,
                beam_size=5,
                # F8 is already an explicit recording gate. Whisper's VAD can
                # discard a short, quiet single word such as "Nova", so leave
                # it off and let transcription decide what it heard.
                vad_filter=False,
                condition_on_previous_text=False,
                initial_prompt="Nova",
            )
            transcript = " ".join(segment.text.strip() for segment in segments).strip()
        except Exception as error:
            log(f"Whisper could not transcribe that recording: {error}")
            return None

        if not transcript:
            log("Whisper did not find spoken words in that recording.")
            return None
        log(f"Heard: {transcript}")
        return transcript


class Nova:
    def __init__(self, config: dict[str, Any]) -> None:
        self.config = config
        self.name = str(config["assistantName"])
        self.hotkey = config.get("hotkey", {})
        self.behavior = config.get("behavior", {})
        self.quiet = False
        self.pending: tuple[str, Any] | None = None
        self.conversation_until: datetime | None = None
        self.should_exit = False

    def say(self, text: str) -> None:
        log(f"Nova: {text}")
        if self.quiet or not bool(self.behavior.get("speak", True)):
            return
        voice = self.config.get("voice", {})
        subprocess.run(
            [
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(SPEAKER),
                "-Text", text, "-Rate", str(voice.get("rate", 0)), "-Volume", str(voice.get("volume", 90)),
            ],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def active(self) -> bool:
        if self.conversation_until and datetime.now() < self.conversation_until:
            return True
        self.conversation_until = None
        return False

    def start_conversation(self) -> None:
        seconds = int(self.hotkey.get("sessionSeconds", 60))
        self.conversation_until = datetime.now() + timedelta(seconds=seconds)
        self.say("I hear you. What would you like to do?")

    def refresh_conversation(self) -> None:
        if self.active():
            self.conversation_until = datetime.now() + timedelta(seconds=int(self.hotkey.get("sessionSeconds", 60)))

    def is_activation(self, text: str) -> bool:
        phrase = normalize(text)
        name = normalize(self.name)
        # A couple of harmless Whisper spacing variants are accepted only after F8.
        return phrase in {name, f"hey {name}", "no va"}

    def open_target(self, target: str, description: str) -> bool:
        target = expand(target)
        try:
            if target.lower().startswith(SAFE_URI_PREFIXES) or os.path.exists(target):
                os.startfile(target)  # type: ignore[attr-defined]
            else:
                subprocess.Popen([target])
            log(f"Opened {description}.")
            return True
        except Exception as error:
            self.say(f"I could not open {description}.")
            log(f"Open failed: {error}")
            return False

    def open_app(self, alias: str) -> bool:
        target = item(self.config.get("apps"), alias)
        if target is None:
            return False
        if self.open_target(str(target), f"the {alias} app"):
            self.say(f"Opening {alias}.")
        return True

    def open_path(self, alias: str) -> bool:
        target = item(self.config.get("paths"), alias)
        if target is None:
            return False
        resolved = expand(str(target))
        if not os.path.isdir(resolved):
            self.say(f"I could not find the {alias} folder.")
            return True
        if self.open_target(resolved, f"the {alias} folder"):
            self.say(f"Opening {alias}.")
        return True

    def search_web(self, query: str) -> None:
        template = str(self.config["search"]["urlTemplate"])
        url = template.replace("{query}", urllib.parse.quote_plus(query.strip()))
        if not url.startswith(("http://", "https://")):
            self.say("The configured search address is not safe, so I did not open it.")
            return
        webbrowser.open(url)
        self.say(f"Searching for {query}.")

    def find_file(self, query: str) -> None:
        needle = query.strip(" '\"").casefold()
        if not needle:
            self.say("Tell me the file name or part of its name.")
            return
        matches: list[Path] = []
        deadline = time.monotonic() + 8
        for root_text in self.config.get("fileSearchRoots", []):
            root = Path(expand(str(root_text)))
            if not root.is_dir():
                continue
            for directory, _, filenames in os.walk(root, followlinks=False):
                if time.monotonic() > deadline or len(matches) >= 5:
                    break
                for filename in filenames:
                    candidate = Path(directory) / filename
                    if candidate.suffix.casefold() in BLOCKED_EXTENSIONS:
                        continue
                    if needle in filename.casefold():
                        matches.append(candidate)
                        if len(matches) >= 5:
                            break
            if time.monotonic() > deadline or len(matches) >= 5:
                break
        if not matches:
            self.say(f"I could not find a safe file matching {query}. Try a more specific name.")
            return
        if len(matches) == 1:
            self.pending = ("file", matches[0])
            self.say(f"I found {matches[0].name}. Say confirm to open it, or cancel.")
            return
        self.pending = ("files", matches)
        for index, match in enumerate(matches, 1):
            log(f"  {index}. {match}")
        self.say(f"I found {len(matches)} files. Say choose 1 through {len(matches)}, or cancel.")

    def run_actions(self, actions: list[dict[str, Any]], context: str) -> None:
        for action in actions:
            kind = str(action.get("type", "")).casefold()
            target = str(action.get("target", ""))
            if kind == "app":
                self.open_app(target)
            elif kind == "path":
                self.open_path(target)
            elif kind == "uri" and target.casefold().startswith(SAFE_URI_PREFIXES):
                self.open_target(target, context)
            else:
                log(f"Skipped unsupported {context} action: {kind}")

    def run_mode(self, name: str) -> bool:
        mode = item(self.config.get("modes"), name)
        if mode is None:
            return False
        if "silence" in mode:
            self.quiet = bool(mode["silence"])
        message = str(mode.get("say", f"Starting {name} mode."))
        if name.casefold() == "quiet":
            was_quiet, self.quiet = self.quiet, False
            self.say(message)
            self.quiet = True
        else:
            self.say(message)
        self.run_actions(mode.get("actions", []), f"{name} mode")
        return True

    def run_task(self, name: str, confirmed: bool = False) -> bool:
        task = item(self.config.get("tasks"), name)
        if task is None:
            return False
        if bool(self.behavior.get("confirmTasks", True)) and not confirmed:
            self.pending = ("task", name)
            self.say(f"I can run {name}. Say confirm or cancel.")
            return True
        self.say(str(task.get("say", f"Running {name}.")))
        self.run_actions(task.get("actions", []), f"the {name} task")
        return True

    def handle_pending(self, text: str) -> bool:
        if not self.pending:
            return False
        if text in {"cancel", "no", "never mind", "nevermind"}:
            self.pending = None
            self.say("Cancelled.")
            return True
        kind, value = self.pending
        if kind == "task" and text in {"confirm", "yes", "do it"}:
            self.pending = None
            self.run_task(str(value), confirmed=True)
            return True
        if kind == "file" and text in {"confirm", "yes", "open it", "do it"}:
            self.pending = None
            self.open_target(str(value), f"the file {Path(value).name}")
            return True
        if kind == "files":
            selected = re.fullmatch(r"(?:choose |option |number )?([1-5])", text)
            if selected and int(selected.group(1)) <= len(value):
                chosen = value[int(selected.group(1)) - 1]
                self.pending = None
                self.open_target(str(chosen), f"the file {chosen.name}")
                return True
        self.say("Please say confirm, cancel, or choose a numbered file.")
        return True

    def handle(self, transcript: str) -> None:
        text = normalize(transcript)
        if not text:
            return
        in_conversation = self.active()
        if not in_conversation:
            if self.is_activation(text):
                self.start_conversation()
            else:
                self.say(f"I heard {transcript}. Hold F8 and say {self.name} first.")
            return

        self.refresh_conversation()
        if self.handle_pending(text):
            return
        if text in {"stop listening", "end conversation", "end the conversation", "end session"}:
            self.conversation_until = None
            self.say("Conversation ended. Hold F8 when you want to talk again.")
            return
        if text in {"exit", "quit", "goodbye"}:
            self.should_exit = True
            self.say("Goodbye.")
            return
        if text in {"help", "what can you do", "commands"}:
            self.say("You can ask me to open an app or folder, search the web, find a file, run a task, or activate a mode.")
            return
        if re.fullmatch(r"(?:what(?:'s| is)? )?(?:the )?time(?: is it)?", text):
            self.say(f"It is {datetime.now():%I:%M %p}.")
            return
        if re.fullmatch(r"(?:what(?:'s| is)? )?(?:the )?date(?: today)?", text):
            self.say(f"Today is {datetime.now():%A, %B %d}.")
            return
        match = re.fullmatch(r"(?:run|launch)(?: task)? (.+)", text)
        if match:
            if not self.run_task(match.group(1)):
                names = ", ".join(self.config.get("tasks", {}).keys()) or "none"
                self.say(f"I only run named tasks from your config. Available tasks are {names}.")
            return
        match = re.fullmatch(r"(?:search(?: for)?|look up|google) (.+)", text)
        if match:
            self.search_web(match.group(1))
            return
        match = re.fullmatch(r"(?:find|locate)(?: file)? (.+)", text)
        if match:
            self.find_file(match.group(1))
            return
        match = re.fullmatch(r"(?:activate|start|turn on|enable) (.+)", text)
        if match and self.run_mode(re.sub(r" mode$", "", match.group(1))):
            return
        match = re.fullmatch(r"(.+?) mode", text)
        if match and self.run_mode(match.group(1)):
            return
        match = re.fullmatch(r"open (.+)", text)
        if match:
            target = re.sub(r"^(?:my |the )", "", match.group(1))
            target = re.sub(r" folder$", "", target)
            if self.open_app(target) or self.open_path(target):
                return
            self.find_file(target)
            return
        if bool(self.behavior.get("searchQuestionsInConversation", True)) and re.match(r"^(what|who|when|where|why|how|tell me about|explain|define)\b", text):
            self.search_web(text)
            return
        self.say("I did not recognize that as a safe command. Say help for examples.")


def held(key: int) -> bool:
    return bool(ctypes.windll.user32.GetAsyncKeyState(key) & 0x8000)


def wait_for_hold(key: int, milliseconds: int) -> None:
    pressed_at: float | None = None
    while True:
        if held(key):
            if pressed_at is None:
                pressed_at = time.monotonic()
            elif (time.monotonic() - pressed_at) * 1000 >= milliseconds:
                while held(key):
                    time.sleep(0.03)
                return
        else:
            pressed_at = None
        time.sleep(0.03)


def load_config(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as file:
        config = json.load(file)
    for required in ("assistantName", "apps", "paths", "modes", "search"):
        if required not in config:
            raise ValueError(f"nova.config.json is missing '{required}'")
    return config


def main() -> int:
    parser = argparse.ArgumentParser(description="Nova's local Whisper voice layer")
    parser.add_argument("--config", type=Path, default=ROOT / "nova.config.json")
    parser.add_argument("--prepare", action="store_true", help="Download/load Whisper and report the chosen microphone, then exit")
    args = parser.parse_args()
    config = load_config(args.config)
    whisper_settings = config.get("whisper", {})
    capture = VoiceCapture(whisper_settings)
    if args.prepare:
        capture.prepare()
        return 0

    nova = Nova(config)
    capture.prepare()
    hotkey = config.get("hotkey", {})
    key_name = str(hotkey.get("key", "F8"))
    key = virtual_key(key_name)
    hold_ms = int(hotkey.get("holdMilliseconds", 500))
    log(f"Whisper standby. Hold {key_name} for {hold_ms} ms, release it, then say '{nova.name}'.")
    nova.say(f"Nova is on standby. Hold {key_name}, then say {nova.name}.")

    while not nova.should_exit:
        if nova.active():
            transcript = capture.record_and_transcribe()
            if transcript:
                nova.handle(transcript)
            continue
        wait_for_hold(key, hold_ms)
        nova.say("Listening.")
        transcript = capture.record_and_transcribe()
        if transcript:
            nova.handle(transcript)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nNova stopped.", flush=True)
    except Exception as error:
        print(f"Nova could not start Whisper: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
