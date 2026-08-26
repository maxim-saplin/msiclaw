# MSI Claw A1M M1/M2 and Moonlight Chord Investigation

Investigation date: 2026-08-25

Device: MSI Claw A1M, DMI board `MS-1T41`, firmware release `0x0172`

Deck 44 stack: kernel `7.2.0-ogc6.1.fc44.x86_64`, InputPlumber `0.78.1`, OpenGamepadUI `0.46.0-11.fc44`, Moonlight Flatpak `6.1.0`

## Executive conclusion

The intended solution was a real Steam Input pass-through path:

```text
M1/M2 hardware
  -> MSI MCU M-key profile
  -> Linux evdev event
  -> InputPlumber source and target
  -> Steam Input-visible controller
  -> per-game or Moonlight action
```

That stable path was not achieved on Deck 44. The experiment was rolled back. The normal `MSI Claw` InputPlumber composite is active again, both M-key slots are neutral, Moonlight's SDL override is removed, and the original OGUI profiles are restored.

The keyboard-shortcut mapping tried near the end was only a workaround. It was not equivalent to HHD's `paddles_as: steam_input` behavior. The gamepad-chord version was especially unsafe because Moonlight's quit chord contains `Start`, which can pause the streamed game when the chord leaks through.

## The layers

The main source of confusion was treating several independent input layers as one controller.

| Layer | Relevant device or file | Responsibility |
|---|---|---|
| MSI firmware and MCU | `/dev/hidraw0`, HID device `0003:0DB0:1902.0001` | Stores what M1 and M2 should emit when `mkeys_function=macro` is active. |
| MSI evdev interfaces | The real nodes were usually `event5` gamepad, `event6` keyboard, and `event7` mouse. | Emits ordinary gamepad, keyboard, or mouse events after the MCU applies an M-key profile. Event numbers are not stable. |
| InputPlumber | Composite device and target devices | Selects source events, filters duplicates, and creates virtual gamepad/keyboard/mouse outputs. |
| OpenGamepadUI | `~/.local/share/opengamepadui/settings.cfg` and generated profile JSON | Chooses a profile and target for an application. It can regenerate or switch profile files. |
| Steam Input | Steam's virtual controller and per-game layout | Can map native extra paddle inputs if they reach Steam as stable controller capabilities. |
| Moonlight | Flatpak `com.moonlight_stream.Moonlight`, Steam AppID `3294910603` | Detects an SDL controller, forwards streamed input, and handles its own local shortcut chords. |

The important distinction is:

```text
normal streamed gamepad input != Moonlight local shortcut detection
```

Changing the controller that carries normal game input does not automatically repair Moonlight's local shortcut recognizer.

## What HHD was doing

The retained HHD-era state was approximately:

```yaml
controllers:
  claw:
    controller_mode:
      mode: hori_steam
      uinput:
        paddles_as: steam_input
    dinput_mode: true
```

The meanings are easy to misread:

- `dinput_mode: true` enabled a special MSI vendor-HID initialization path. It was not simply a request to use an ordinary DInput controller.
- `hori_steam` selected an output arrangement with gyro, paddles, and Steam-oriented controls.
- `paddles_as: steam_input` exposed extra controller buttons for Steam Input. It did not mean that Steam could discover arbitrary raw MSI firmware slots by itself.

HHD's older MSI code used a legacy profile packet resembling:

```text
0f 00 00 3c 21 01 <address> 05 01 00 00 12 00
```

and then sent the ROM-sync command:

```text
0f 00 00 3c 22
```

The HHD-side addresses recorded during the investigation were M1 `0x00ba` and M2 `0x0163` for the relevant newer A1M firmware path.

## Deck 44 hid-msi format

The Deck 44 kernel driver uses a different M-key profile layout. For firmware release `0x0172`, the addresses observed in the current driver were:

```text
M1: 0x00bb
M2: 0x0164
```

The current-format report is:

```text
0f 00 00 3c 21 01 <address, big endian> 07 04 00 <five key-code slots>
```

The current driver's mapping table includes ordinary gamepad, keyboard, and mouse codes. Examples:

```text
0x0e  BTN_SELECT
0x0f  BTN_START
0x58  KEY_LEFTBRACE
0x59  KEY_RIGHTBRACE
0x5d  KEY_S
0x74  KEY_LEFTCTRL
0x76  KEY_LEFTALT
0x9c  KEY_F23
0xff  DISABLED
```

The HHD token `0x12` is not in this table. Writing it returned a successful 64-byte HID transfer and caused `BTN_TRIGGER_HAPPY1/2` capability slots to appear on the evdev node, but it did not produce reliable physical button events. Capability advertisement was therefore not proof that the buttons were working.

The driver's sysfs interface exposed `button_m1`, `button_m2`, and `button_mapping_options`, but the installed Deck 44 build rejected the attempted name writes with `EINVAL` or a low-level write assertion. The raw HID packet path could write valid codes and the driver could read those valid codes back, but physical output still needed independent raw-event verification.

## Moonlight's native chords

The Moonlight source behavior recovered during the investigation was:

```text
Quit session:       Start + Select + Left Bumper + Right Bumper
Performance overlay: Select + Left Bumper + Right Bumper + X
```

The triggers are not part of either native chord. Moonlight checks an exact SDL button mask on one controller. Normal streamed gamepad forwarding and this local shortcut check are separate code paths.

Moonlight also has keyboard shortcuts equivalent to:

```text
Performance overlay: Ctrl + Alt + Shift + S
Quit session:        Ctrl + Alt + Shift + Q
```

The setting `capturesyskeys=0` disables the keyboard shortcut path. Enabling it does not repair a missing physical M-key event; it only makes a correctly generated keyboard event eligible for Moonlight's shortcut handler.

## What we tried

### 1. Route Moonlight away from Steam's virtual Xbox 360 pad

Initially Moonlight opened Steam's virtual `/dev/input/event25`, named `Microsoft X-Box 360 pad 0`. That controller did not expose the expected paddle slots. A temporary Flatpak override was used:

```text
SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=0
SDL_GAMECONTROLLER_IGNORE_DEVICES=0x28de/0x11ff
```

This worked for SDL device selection: a fresh Moonlight process opened the Xbox Elite-style InputPlumber controller instead. It did not create working M1/M2 events and was removed during rollback.

### 2. Map M1/M2 in the OGUI per-app profile

Editing the global OGUI overlay was insufficient. Moonlight used a per-app profile, and OGUI also generated an Xbox Elite target variant. The relevant profile had to be changed in both forms.

The first mapping used Moonlight's native gamepad chords. This was conceptually close to the requested behavior, but it had two problems:

- The physical rear events were not stable.
- The quit chord contains `Start`, so a leaked or partially recognized chord can pause the streamed game.

The profile also repeatedly alternated between `OpenGamepadUI Default` and `Moonlight Rear Chords` when the application target did not match the active `xbox-elite` target. That made the controller appear to change behavior every few seconds.

### 3. Use HHD's `0x12` token with the current report format

The current-format reports were written to M1 `0x00bb` and M2 `0x0164`, followed by ROM sync. The HID writes returned 64 bytes, and the DInput node advertised `BTN_TRIGGER_HAPPY1` and `BTN_TRIGGER_HAPPY2`.

Direct raw captures then showed no physical `HAPPY1/2` transitions. The current `hid-msi` driver does not name `0x12` as a valid mapping. This was the key false positive: the device descriptor changed, but the buttons did not become a usable input source.

### 4. Add an InputPlumber DInput paddle bridge

The custom bridge admitted the DInput source, translated `HAPPY1/2`, and included only the named paddle capabilities so normal controls were not duplicated. InputPlumber successfully loaded a composite named `MSI Claw A1M with paddles` and reported `LeftPaddle1` and `RightPaddle1`.

That proved configuration parsing and capability construction only. It did not prove that a physical press reached the source. The raw source was also exclusively grabbed by InputPlumber, so `evtest` could report that no events were available. Later captures used InputPlumber stopped temporarily.

### 5. Replace gamepad chords with keyboard shortcuts

To prevent `Start` from pausing games, the experiment changed the Moonlight profile to emit keyboard events. The intended M1 action was `Ctrl+Alt+Shift+S`; the intended M2 action was `Ctrl+Alt+Shift+Q`, and later M2 was made neutral.

The keyboard target did show a `Q` sequence during one capture, but no reliable `S` event arrived for M1. The capture was also affected by profile reloads, so it was not a clean physical acceptance test. This path was rolled back because it was a workaround, not Steam Input paddle pass-through.

### 6. Try supported ordinary key codes

The current driver recognized `KEY_LEFTBRACE` and `KEY_RIGHTBRACE` as valid codes. A raw current-format write could read them back through sysfs. A direct raw capture showed a repeating `KEY_RIGHTBRACE` stream for one physical test, while the other M-key produced no corresponding event. The result was not stable enough to use as a controller mapping.

The driver sysfs writer itself rejected the same names, so the final test used raw HID writes. This distinction matters when reproducing the work: a successful HID transfer is not the same as a successful event path.

## Lessons learned

1. **Start with the raw physical event.** Do not edit Steam, OGUI, or Moonlight until one physical M-key press produces a distinct event on the real MSI evdev node.
2. **A capability is not an event.** InputPlumber can advertise `LeftPaddle1` and `RightPaddle1` even when the source never reports a press.
3. **Event numbers are temporary.** Resolve devices by sysfs vendor, product, physical path, and name. `event23` changed from an Elite target to an InputPlumber mouse during this work; the real Elite target later appeared as `event24`.
4. **Profile files have scope.** OGUI's global profile, per-app base profile, and target-specific generated profile are different files. Updating one does not guarantee that a running application uses it.
5. **Do not use a gamepad quit chord as a harmless test.** Moonlight's quit chord contains `Start`, which is a normal pause input in many streamed games.
6. **Separate Moonlight from Steam Input.** Moonlight's local chord recognizer is not Steam Input's per-game action system. Selecting an Elite SDL controller does not make Moonlight's hard-coded chord logic work.
7. **Do not port HHD packets by token alone.** The packet layout, addresses, firmware version, and driver-supported code table all matter.
8. **Bound every diagnostic reader.** A previous capture left orphaned `evtest` and SSH processes running for over an hour and holding the raw device. Use a timeout, a cleanup trap, and verify the reader exited.

## Safer future test order

If this investigation is resumed, use this order:

1. Close Moonlight and record the current firmware values, InputPlumber profile, OGUI settings, and active event-node names.
2. Resolve the MSI nodes dynamically from `/sys/class/input/event*/device`, checking `id/vendor`, `id/product`, `phys`, and `name`. Never assume `event5` or any other number.
3. Check `button_mapping_options` and the firmware release. Choose one supported, harmless code and one M-key only.
4. Stop InputPlumber briefly, start bounded `evtest` readers on the real MSI gamepad, keyboard, and mouse interfaces, and press exactly one physical M-key.
5. If no raw event appears, stop. The problem is still firmware, MCU mode, or hardware; Steam and Moonlight mappings cannot fix it.
6. If a raw event appears consistently, restart InputPlumber and verify that the same event reaches the intended virtual target. Capture the target by device name, not event number.
7. Only after source and target events are proven should Steam Input receive a per-app mapping. Keep the global game profile neutral.
8. Only after Steam Input is proven should Moonlight-specific behavior be tested. Test direct Flatpak launch and Steam launch separately, and treat keyboard shortcuts and native gamepad chords as different experiments.
9. Do not use remote suspend or hibernate during input experiments. The Claw can be left offline until a person presses the power button.

## Rollback reference

The rollback used the following known-good user backups on the Claw:

```text
~/.local/share/opengamepadui/data/gamepad/profiles/51a1f05af85e342e3c849b47d387086476282d5f50dc240c19216d6edfb1eb5a.json.bak.20260825-213306
~/.local/share/opengamepadui/data/gamepad/profiles/51a1f05af85e342e3c849b47d387086476282d5f50dc240c19216d6edfb1eb5a_xbox-elite.json.bak.20260825-213306
~/.local/share/opengamepadui/settings.cfg.bak.20260825-214001
~/.var/app/com.moonlight_stream.Moonlight/config/Moonlight Game Streaming Project/Moonlight.conf.bak.20260825-231212
```

The restored baseline has:

```text
InputPlumber composite: MSI Claw
InputPlumber profile:   bin
gamepad_mode:           dinput
mkeys_function:         macro
button_m1:              (not set)
button_m2:              (not set)
Moonlight capturesyskeys=0
```

The temporary Flatpak SDL override and custom `/etc/inputplumber` paddle files were removed. Timestamped pre-rollback backups were retained as safety copies; they are inactive and do not participate in input routing.

## Bottom line

The hunt was not a successful Steam Input paddle restoration. It established where the boundary is: the missing proof was a stable physical M1/M2 event from the MSI firmware, not another Moonlight chord definition. The normal controller is intentionally restored until that lower-level event path can be demonstrated first.