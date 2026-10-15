#!/usr/bin/env python3
"""Writes the house's synthesised sounds into audio/ as .ogg, and copies Kenney's foley in.

    tools/make_sounds.py            # rewrite audio/*.ogg
    tools/make_sounds.py --levels   # print peak and loudness of every file in audio/

Everything here is generated from a fixed seed (numpy + SoX), so the files are ours (CC0, like
the rest of the art) and re-render the same. Kenney's files (Impact Sounds, RPG Audio; CC0) are
copied from the bundle at KENNEY, which is only needed to re-copy them.

Every file is normalised to a -2 dBFS peak by SoX (a decoded Vorbis file overshoots its source by up to a decibel, so -1 came back at 0), so nothing clips; how loud each one PLAYS
is the catalogue's gain_db (game/lm_audio.gd), where it can be tuned without re-rendering.
"""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np
from scipy import signal

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio")
KENNEY = os.path.expanduser("~/assets/kenny-assets/Audio")
RATE = 44100
RNG = np.random.default_rng(20261012)

# Kenney's foley, copied as is: (pack, file in the pack, name here).
KENNEY_FILES = [
    ("Impact Sounds", "footstep_wood_000.ogg", "step_0.ogg"),
    ("Impact Sounds", "footstep_wood_001.ogg", "step_1.ogg"),
    ("Impact Sounds", "footstep_wood_002.ogg", "step_2.ogg"),
    ("Impact Sounds", "footstep_wood_003.ogg", "step_3.ogg"),
    ("Impact Sounds", "footstep_wood_004.ogg", "step_4.ogg"),
    ("RPG Audio", "creak1.ogg", "creak_0.ogg"),
    ("RPG Audio", "creak2.ogg", "creak_1.ogg"),
    ("RPG Audio", "creak3.ogg", "creak_2.ogg"),
    ("RPG Audio", "doorClose_4.ogg", "creak_3.ogg"),
    ("RPG Audio", "doorOpen_1.ogg", "door_0.ogg"),
    ("RPG Audio", "doorOpen_2.ogg", "door_1.ogg"),
    ("RPG Audio", "metalLatch.ogg", "click.ogg"),
    ("Interface Sounds", "switch_002.ogg", "torch_on.ogg"),
    ("Interface Sounds", "switch_003.ogg", "torch_off.ogg"),
]


def t_of(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def lowpass(x, hz, order=2):
    b, a = signal.butter(order, hz / (RATE / 2), "low")
    return signal.lfilter(b, a, x)


def bandpass(x, lo, hi, order=2):
    b, a = signal.butter(order, [lo / (RATE / 2), hi / (RATE / 2)], "band")
    return signal.lfilter(b, a, x)


def loop_seam(x, fade):
    """The last [fade] seconds crossfaded onto the first, so the file loops with no seam."""
    n = int(fade * RATE)
    head, body, tail = x[:n], x[n:-n], x[-n:]
    ramp = np.linspace(0.0, 1.0, n)
    # Equal power, so the seam is not a dip in a bed of noise.
    joined = tail * np.cos(ramp * np.pi / 2) + head * np.sin(ramp * np.pi / 2)
    return np.concatenate([joined, body])


def ambience():
    """The house breathing: a low room rumble, wind finding gaps in the walls, and two low
    tones a few hertz apart swelling in and out. 40 seconds, looped."""
    length = 44.0
    t = t_of(length)
    rumble = lowpass(np.cumsum(RNG.standard_normal(t.size)) * 0.002, 120.0)
    rumble -= lowpass(rumble, 8.0)
    rumble *= 0.7 + 0.3 * np.sin(2 * np.pi * t / 22.0)
    # Wind: noise through a band that wanders, in eight overlapping slices.
    wind = np.zeros_like(t)
    noise = RNG.standard_normal(t.size)
    slices = 8
    for k in range(slices):
        centre = 380.0 + 260.0 * np.sin(k * 1.7)
        band = bandpass(noise, centre * 0.8, centre * 1.25)
        window = np.clip(1.0 - np.abs((t / length) * slices - k - 0.5) / 1.1, 0.0, 1.0)
        wind += band * window
    wind *= 0.35 + 0.65 * np.clip(np.sin(2 * np.pi * t / 11.0 + 0.6), 0.0, 1.0) ** 2
    drone = (np.sin(2 * np.pi * 43.65 * t) + 0.8 * np.sin(2 * np.pi * 46.25 * t) + 0.25 * np.sin(2 * np.pi * 87.3 * t))
    drone *= 0.5 + 0.5 * np.sin(2 * np.pi * t / 14.0) ** 2
    # A far, thin tone now and then: the house settling.
    high = np.sin(2 * np.pi * 523.25 * t + 3.0 * np.sin(2 * np.pi * 0.31 * t)) * np.clip(np.sin(2 * np.pi * t / 19.0 + 2.0), 0, 1) ** 6
    mix = rumble / np.max(np.abs(rumble)) * 0.55 + wind / np.max(np.abs(wind)) * 0.45 + drone / 2.05 * 0.35 + high * 0.04
    return loop_seam(mix, 4.0)


def drone():
    """A witch, heard: a low beating hum and a breath through it, a whisper's band. Four
    seconds, looped."""
    length = 5.0
    t = t_of(length)
    hum = np.sin(2 * np.pi * 49.0 * t) * 0.5 + np.sin(2 * np.pi * 52.0 * t) * 0.45 + np.sin(2 * np.pi * 98.5 * t) * 0.12
    breath_env = np.clip(np.sin(2 * np.pi * t / 2.5), 0.0, 1.0) ** 1.5
    breath = bandpass(RNG.standard_normal(t.size), 900.0, 3200.0) * breath_env
    breath /= np.max(np.abs(breath))
    # A thin, wavering tone a tritone over: the wrongness.
    thin = np.sin(2 * np.pi * 311.1 * t + 0.8 * np.sin(2 * np.pi * 5.5 * t)) * 0.08
    mix = hum * 0.7 + breath * 0.32 + thin
    return loop_seam(mix, 1.0)


def stinger():
    """She has seen you: a dissonant string stab, a low boom under it, ringing out."""
    length = 3.0
    t = t_of(length)
    env = np.exp(-t * 1.6) * np.clip(t / 0.015, 0, 1)
    tones = [220.0, 233.08, 329.63, 349.23, 466.16]
    stab = np.zeros_like(t)
    for f in tones:
        for detune in (-0.3, 0.0, 0.35):
            stab += signal.sawtooth(2 * np.pi * (f + detune) * t + RNG.uniform(0, 6.28))
    stab = lowpass(stab, 2600.0) / len(tones) / 3.0
    boom = np.sin(2 * np.pi * (38.0 + 30.0 * np.exp(-t * 8.0)) * t) * np.exp(-t * 2.2)
    hiss = bandpass(RNG.standard_normal(t.size), 3000.0, 9000.0) * np.exp(-t * 6.0) * 0.25
    return np.tanh((stab * env * 1.3 + boom * 0.9 + hiss) * 1.4)


def scream():
    """Caught: a shriek rising through a ragged band, over a hit."""
    length = 1.8
    t = t_of(length)
    pitch = 620.0 + 520.0 * (1.0 - np.exp(-t * 3.0)) + 25.0 * np.sin(2 * np.pi * 7.0 * t)
    phase = 2 * np.pi * np.cumsum(pitch) / RATE
    voice = signal.sawtooth(phase) * 0.6 + signal.sawtooth(phase * 1.5 + 0.4) * 0.3 + signal.sawtooth(phase * 2.01) * 0.2
    voice = bandpass(voice, 500.0, 4200.0)
    rasp = bandpass(RNG.standard_normal(t.size), 1500.0, 6000.0) * 0.5
    env = np.clip(t / 0.03, 0, 1) * np.clip((length - t) / 0.6, 0, 1)
    hit = np.sin(2 * np.pi * (45.0 + 60.0 * np.exp(-t * 12.0)) * t) * np.exp(-t * 5.0)
    return np.tanh((voice * 1.6 + rasp) * env * 2.2) * 0.75 + hit * 0.6


def heartbeat():
    """One thud of the lub-dub: a low knock with a soft attack, chest not drum."""
    length = 0.32
    t = t_of(length)
    f = 52.0 + 30.0 * np.exp(-t * 25.0)
    thud = np.sin(2 * np.pi * np.cumsum(f) / RATE) * np.exp(-t * 14.0) * np.clip(t / 0.006, 0, 1)
    knock = lowpass(RNG.standard_normal(t.size), 180.0) * np.exp(-t * 60.0) * 2.0
    return lowpass(thud + knock * 0.15, 400.0)


def slam():
    """A door slammed somewhere behind you: a hard wooden hit, the frame rattling, the house
    ringing with it for a moment."""
    length = 1.6
    t = t_of(length)
    thump = np.sin(2 * np.pi * (48.0 + 70.0 * np.exp(-t * 30.0)) * t) * np.exp(-t * 9.0)
    crack = bandpass(RNG.standard_normal(t.size), 180.0, 3200.0) * np.exp(-t * 45.0)
    rattle = np.zeros_like(t)
    for at, gain in ((0.06, 0.5), (0.11, 0.35), (0.19, 0.2)):
        start = int(at * RATE)
        n = int(0.03 * RATE)
        rattle[start:start + n] += bandpass(RNG.standard_normal(n), 900.0, 4000.0) * np.exp(-np.arange(n) / RATE * 120.0) * gain
    tail = lowpass(RNG.standard_normal(t.size), 600.0) * np.exp(-t * 3.2) * 0.25
    return np.tanh((thump * 1.2 + crack * 0.9 + rattle + tail) * 1.5)


def lights_out():
    """The lights of a room dying: a mains buzz that stutters, a pop, and nothing."""
    length = 1.6
    t = t_of(length)
    buzz = signal.square(2 * np.pi * 100.0 * t) * 0.35 + np.sin(2 * np.pi * 200.0 * t) * 0.3 + np.sin(2 * np.pi * 300.0 * t) * 0.15
    buzz = lowpass(buzz, 2500.0)
    # The stutter: the same rhythm the lamps flicker to (LmClient), on and off, then gone at 1.25 s.
    gate = np.zeros_like(t)
    for a, b in ((0.0, 0.18), (0.26, 0.34), (0.45, 0.72), (0.8, 0.86), (0.98, 1.25)):
        gate[int(a * RATE):int(b * RATE)] = 1.0
    gate = lowpass(gate, 60.0, order=1)
    pop_at = int(1.25 * RATE)
    pop = np.zeros_like(t)
    n = int(0.25 * RATE)
    pop[pop_at:pop_at + n] = bandpass(RNG.standard_normal(n), 1200.0, 7000.0) * np.exp(-np.arange(n) / RATE * 40.0)
    return buzz * gate * 0.8 + pop * 1.2


def whisper_voice(seed, syllables, length, pitch):
    """A whisper has no pitch: breath through the formants of a vowel, chopped into syllables
    by an envelope. Each syllable moves between two vowels' formants so it reads as speech
    with no word in it, which is worse than a word. A separate generator per file, so adding
    a whisper never changes the noise any other sound was rendered with."""
    rng = np.random.default_rng(seed)
    t = t_of(length)
    out = np.zeros_like(t)
    vowels = [(730, 1090, 2440), (270, 2290, 3010), (570, 840, 2410), (300, 870, 2240)]
    slot = length / syllables
    for i in range(syllables):
        a = vowels[rng.integers(len(vowels))]
        b = vowels[rng.integers(len(vowels))]
        start = int((i * slot + slot * 0.08) * RATE)
        n = int(slot * 0.78 * RATE)
        noise = rng.standard_normal(n)
        seg = np.zeros(n)
        for k, (fa, fb) in enumerate(zip(a, b)):
            # Two formant bands per vowel, the second's centre slid towards the next vowel.
            lo = min(fa, fb) * pitch
            hi = max(fa, fb) * pitch * 1.12
            seg += bandpass(noise, lo * 0.9, min(hi, 9500.0)) * (1.0 / (k + 1))
        shape = np.sin(np.linspace(0, np.pi, n)) ** 1.6
        out[start:start + n] += seg * shape
    out += bandpass(rng.standard_normal(t.size), 4000.0, 9000.0) * 0.04 * np.abs(out).max()
    return out


def whisper_0():
    return whisper_voice(11, 5, 1.8, 1.0)


def whisper_1():
    return whisper_voice(12, 4, 1.5, 0.85)


def whisper_2():
    return whisper_voice(13, 6, 2.1, 1.1)


def whisper_behind():
    """"Look behind you": four unhurried syllables, close and low."""
    return whisper_voice(14, 4, 1.7, 0.8)


def scare_hit():
    """The sudden sound of a sanity scare: a loud, short, wrong thing. A downward bark of
    inharmonic metal over a burst of noise and a thump, with no build-up and a quick tail."""
    t = t_of(1.4)
    rng = np.random.default_rng(15)
    env = np.exp(-t * 5.0) * np.clip(t / 0.004, 0, 1)
    metal = sum(np.sin(2 * np.pi * f * t * (1.0 - 0.18 * (1 - np.exp(-t * 6.0)))) for f in (187.0, 311.0, 466.0, 733.0, 1217.0)) / 5.0
    burst = bandpass(rng.standard_normal(t.size), 400.0, 8000.0) * np.exp(-t * 14.0)
    thump = np.sin(2 * np.pi * (45.0 + 60.0 * np.exp(-t * 20.0)) * t) * np.exp(-t * 6.0)
    return np.tanh((metal * env * 1.1 + burst * 1.2 + thump * 1.0) * 1.5)


GENERATED = {
    "ambience": ambience, "witch_drone": drone, "stinger": stinger, "scream": scream, "heartbeat": heartbeat,
    # After the five above, so the seeded generator gives those the same noise it always has.
    "slam": slam, "lights_out": lights_out,
    "scare_hit": scare_hit, "whisper_0": whisper_0, "whisper_1": whisper_1, "whisper_2": whisper_2,
    "whisper_behind": whisper_behind,
}


def write_ogg(name, x):
    x = np.asarray(x, dtype=np.float64)
    x = x / max(np.max(np.abs(x)), 1e-9)
    pcm = (x * 32000).astype(np.int16)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "x.wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm.tobytes())
        out = os.path.join(OUT, name + ".ogg")
        subprocess.run(["sox", wav, "-C", "4", out, "norm", "-2"], check=True)


def levels():
    for name in sorted(os.listdir(OUT)):
        if not name.endswith(".ogg"):
            continue
        path = os.path.join(OUT, name)
        stats = subprocess.run(["sox", path, "-n", "stats"], capture_output=True, text=True).stderr
        peak = [line.split()[-1] for line in stats.splitlines() if line.startswith("Pk lev dB")]
        rms = [line.split()[-1] for line in stats.splitlines() if line.startswith("RMS lev dB")]
        ebu = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128", "-f", "null", "-"],
                             capture_output=True, text=True).stderr
        lufs = [line.split()[1] for line in ebu.splitlines() if line.strip().startswith("I:")]
        print("%-16s peak %6s dBFS  rms %6s dB  %s LUFS" % (name, peak[0] if peak else "?", rms[0] if rms else "?", lufs[-1] if lufs else "?"))


def main():
    if "--levels" in sys.argv:
        levels()
        return
    os.makedirs(OUT, exist_ok=True)
    for name, make in GENERATED.items():
        write_ogg(name, make())
    for pack, src, dst in KENNEY_FILES:
        # Through SoX at the same -2 dBFS peak: three of them peak at full scale as shipped.
        subprocess.run(["sox", os.path.join(KENNEY, pack, "Audio", src), "-C", "4", os.path.join(OUT, dst), "norm", "-2"], check=True)
    levels()


if __name__ == "__main__":
    main()
