# Warden Anti-Cheat Research (World of Warcraft)

Research compiled from public sources: emulator projects (AzerothCore, TrinityCore, WoWee),
community reverse-engineering (WardenScanner, OwnedCore, HackMag), and wiki documentation.
Most details come from WoW 3.3.5a (build 12340); retail Warden may differ significantly.

---

## 1. Overview

Warden is Blizzard's proprietary anti-cheat system, used across multiple titles but most
prominent in World of Warcraft. Key characteristics:

- **User-mode only** -- no kernel driver. Runs as a module inside the WoW process (Ring 3).
- **Server-driven** -- the server sends encrypted scan requests; the client executes them and
  returns results. Blizzard can update checks without patching the game client.
- **Dynamic modules** -- scanning code is downloaded from the server at runtime, unpacked into
  heap memory (not loaded through the normal Windows PE loader), and can change between sessions.
- **Challenge-response model** -- the server sends a challenge packet, the client's Warden module
  performs the requested scan(s), and the client returns hashed/encrypted results.

### Comparison to other anti-cheats

| System     | Ring | Loads at       | Notes                                      |
|------------|------|----------------|--------------------------------------------|
| **Warden** | 3    | Game start     | User-mode, module-based, server-driven     |
| VAC        | 3    | Game start     | User-mode, signature scanning              |
| EAC        | 0    | Game start     | Kernel driver, unloads when game exits     |
| BattlEye   | 0    | Game start     | Kernel driver, unloads when game exits     |
| Vanguard   | 0    | System boot    | Persistent kernel driver (Riot/Valorant)   |
| Ricochet   | 0    | Game start     | Kernel driver (Activision/CoD)             |

Being user-mode means Warden has less visibility than kernel anti-cheats -- it cannot
inspect kernel objects, other drivers, or DMA traffic. However, it is less invasive and
avoids the security risks of a kernel driver.

---

## 2. Architecture

### 2.1 Module Loading Pipeline

Warden modules are not standard Windows DLLs. They are custom PE-like images delivered
encrypted from the server. The loading sequence:

1. **MD5 verify** -- check the module checksum against the server's challenge
2. **RC4 decrypt** -- decrypt the payload using session-derived keys
3. **RSA-2048 verify** -- verify the module signature (Blizzard's public key or realm-specific).
   The module ends with a `NGIS` tag followed by a 256-byte RSA signature. The recovered
   block contains a SHA1 hash and a `MAIEV.MOD` marker.
4. **zlib decompress** -- inflate the payload
5. **Parse** -- unpack Warden's custom image format (copy/skip pair stream)
6. **Relocate** -- apply base relocations
7. **Bind imports** -- resolve imports to API stubs and Warden callbacks
8. **Init** -- call the entry point

The module is placed at a **random heap address**, not loaded through `LoadLibrary`, so it
does not appear in the process module list (PEB `InLoadOrderModuleList`).

### 2.2 Module ABI

- **Entry point**: `thiscall` convention, `ECX` = pointer to a client-services object.
  Returns the module's own object whose first DWORD is a vtable pointer.
- **Client services** (module calls these): `SendPacket`, `CheckModule`, `LoadModule`,
  `AllocateMemory`, `FreeMemory`, `SetRC4Data`, `GetRC4Data`
- **Module exports** (client calls these): `GenerateRC4Keys`, `Unload`, `PacketHandler`, `Tick`

The module vtable has **14 entries** when fully active.

### 2.3 Cryptography

| Algorithm | Purpose                                          |
|-----------|--------------------------------------------------|
| RC4       | Encrypt/decrypt Warden traffic (separate in/out) |
| MD5       | Module identity/checksum                         |
| SHA1      | HMAC for check hashes, SHA1Randx key derivation  |
| RSA-2048  | Module signature verification                    |

RC4 keys are derived from the 40-byte session key using HMAC-SHA1 (TrinityCore approach).
Separate cipher states for client-to-server and server-to-client, each a 256-byte S-box
plus `i` and `j` counters.

### 2.4 Network Protocol

```
SMSG_WARDEN_DATA = 0x2E6  (server -> client)
CMSG_WARDEN_DATA = 0x2E7  (client -> server)
```

**Server opcodes:**
| Opcode | Name                  | Description                          |
|--------|-----------------------|--------------------------------------|
| 0x00   | MODULE_USE            | Load/use a specific module           |
| 0x01   | MODULE_CACHE          | Cache module data                    |
| 0x02   | CHEAT_CHECKS_REQUEST  | Request a batch of integrity checks  |
| 0x03   | MODULE_INITIALIZE     | Initialize the loaded module         |
| 0x05   | HASH_REQUEST          | Request hash computation             |

**Client opcodes:**
| Opcode | Name                  | Description                          |
|--------|-----------------------|--------------------------------------|
| 0x00   | MODULE_MISSING        | Module not in cache                  |
| 0x01   | MODULE_OK             | Module loaded/cached successfully    |
| 0x02   | CHEAT_CHECKS_RESULT   | Results of integrity checks          |
| 0x04   | HASH_RESULT           | Hash computation result              |

**Check request format:** `[opcode byte][check count][per-check: type, address, length]`

**Check reply format:** `[0x02][uint16 length][uint32 checksum][results]`
The checksum is the XOR of five 32-bit words of SHA1(results).

---

## 3. Scan Types (Check Types)

Check-type opcodes **vary per module** -- they are read from the module's header (or `.cr`
file) and XORed with the request's last byte. The following are the canonical types from
AzerothCore's `Warden.h`:

| Check Type     | Byte (AC) | What it does                                              |
|----------------|-----------|-----------------------------------------------------------|
| MEM_CHECK      | 0xF3      | Read bytes at a specific memory address                   |
| PAGE_CHECK_A   | 0xB2      | HMAC-SHA1 hash of a code page (variant A)                 |
| PAGE_CHECK_B   | 0xBF      | HMAC-SHA1 hash of a code page (variant B)                 |
| MPQ_CHECK      | 0x98      | SHA1 hash of a game data file                             |
| LUA_EVAL_CHECK | 0x8B      | Execute Lua code and check the return value               |
| DRIVER_CHECK   | 0x71      | Check for presence of a specific kernel driver            |
| TIMING_CHECK   | 0x57      | Measure response latency (detects single-stepping/interception) |
| PROC_CHECK     | 0x7E      | Check for presence of a specific API/procedure            |
| MODULE_CHECK   | 0xD9      | Check for presence of a loaded DLL/module                 |

### 3.1 What each scan targets

**MEM_CHECK** -- The primary scan for detecting inline hooks, code patches, and injected
trampolines. Reads N bytes at a given virtual address inside the WoW process and returns
them to the server. The server compares against known-good values from the original binary.
This is how Warden detects:
- Inline hooks (JMP/CALL instructions replacing function prologues)
- NOPed-out checks
- Patched game logic (speedhacks, teleport hacks)

**PAGE_CHECK_A / PAGE_CHECK_B** -- Hashes entire code pages using HMAC-SHA1 with a
server-provided seed. Catches broader modifications to executable sections that a
point-read might miss.

**MODULE_CHECK** -- Enumerates loaded DLLs and hashes them. Detects:
- Injected DLLs (cheat modules loaded via `CreateRemoteThread`/`LoadLibrary`)
- Known cheat DLLs by hash signature

**DRIVER_CHECK** -- Checks for the presence of specific kernel-mode drivers (by device
path or service name). Targets:
- Known cheat drivers (rootkits that hide processes or hook kernel functions)
- Memory manipulation drivers (similar to WinRing0, KDMapper, etc.)

**MPQ_CHECK** -- Hashes game data archives to detect:
- Modified models (wallhacks, model swaps)
- Modified textures
- Tampered game data files

**LUA_EVAL_CHECK** -- Executes Lua code in the game's scripting environment and checks
the return value. Detects:
- Bot frameworks that register global Lua variables or functions
- Modified addon APIs
- Automation frameworks that create hidden frames

**PROC_CHECK** -- Checks for the existence of specific exported functions in loaded
modules. Can detect cheats that export known API names.

**TIMING_CHECK** -- Measures how long the client takes to respond. Detects:
- Debuggers (single-stepping causes delays)
- Interception layers that add latency
- Virtual machine overhead

### 3.2 Warden's self-integrity monitoring

Warden monitors its own integrity by:
- Checking vtable entries for unexpected modifications
- Scanning key function prologues for JMP/CALL/PUSH+RET patterns (hook signatures)
- Verifying the integrity of the `WardenData` network handler

---

## 4. Detection Vectors

### 4.1 In-process detection (what Warden looks for inside WoW)

1. **Known cheat signatures** -- byte patterns matching known cheat tools
2. **Inline hooks** -- modified function prologues (first 5+ bytes changed to JMP/CALL)
3. **Injected DLLs** -- modules not in the original load list
4. **Modified game code** -- hash mismatches on executable pages
5. **Lua-environment tampering** -- bot globals, hidden frames, modified APIs
6. **Modified game data files** -- MPQ archive hash mismatches
7. **Exploitative model edits** -- wallhack/model swap detections

### 4.2 Out-of-process detection

1. **Known cheat drivers** -- device paths or driver names matching known rootkits
2. **Process enumeration** -- Warden has historically enumerated running processes and
   window titles (source of the 2005 "spyware" controversy)
3. **Hardware fingerprinting** -- Blizzard reportedly collects MAC addresses, motherboard
   serial numbers, and GPU identifiers for HWID bans (unverified against official sources)

### 4.3 Server-side detection (not part of Warden proper)

- Statistical analysis of player movement (teleport detection, speedhack detection)
- Action-pattern analysis (bot detection via input regularity)
- Economy tracking (gold farming patterns)
- Heuristic analysis of combat logs

---

## 5. Relevance to This Project's Architecture

This repo currently supports CS2, AssaultCube, and Rust using three memory-access approaches.
Here is how each maps to Warden's detection capabilities:

### 5.1 `Bypass` class (ReadProcessMemory/WriteProcessMemory)

**Detection risk: HIGH**

The `Bypass` class calls `ReadProcessMemory` / `WriteProcessMemory` via kernel32.dll with an
open process handle. Warden can detect this through:
- **Process handle enumeration** -- Warden can call `NtQuerySystemInformation` to list
  processes with open handles to the WoW process
- **Module scanning** -- if the cheat is a separate .exe, Warden's out-of-process checks
  can find it by window title or process name
- This is the approach with the **least stealth** and is trivially detected by any
  anti-cheat that checks for external readers

### 5.2 `KernelMemoryReader` (physical memory via vulnerable driver)

**Detection risk: MEDIUM**

Uses a loaded vulnerable driver to read/write physical memory, with CR3-based page table
walking to translate virtual addresses. Advantages vs Warden specifically:
- **Bypasses user-mode API hooks** -- no calls to `ReadProcessMemory` that Warden could
  intercept or monitor
- **No process handle needed** -- reads physical memory directly, so handle enumeration
  doesn't find it
- **Driver unlinking** -- the `DriverLoader.UnlinkFromModuleList` method removes the
  driver from `PsLoadedModuleList`, hiding it from `DRIVER_CHECK` scans

However, Warden's `DRIVER_CHECK` is not the only concern:
- The driver's **device path** could still be enumerable via `\\.\DeviceName`
- Registry artifacts from `NtLoadDriver` may persist
- Modern Windows (Hypervisor-Protected Code Integrity / HVCI) blocks unsigned drivers
- The vulnerable driver itself may be **signature-banned** (e.g., WinRing0 is widely known)

### 5.3 `KoshcheiPipeReader` (named pipe to external driver/loader)

**Detection risk: MEDIUM-LOW** (against Warden specifically)

Communicates with an external kernel component via a named pipe (`\\.\pipe\koshchei`).
This is the most indirect approach:
- The reading happens in kernel space, invisible to Warden's user-mode scans
- No direct process handle to WoW
- Named pipe communication is less suspicious than IOCTL calls

But:
- The **pipe name** is a static string that could be signature-matched
- The external loader process could be enumerated
- The kernel component still needs to evade driver-level detection

### 5.4 Key differences: Warden vs. VAC/EAC

| Aspect                  | Warden                    | VAC (CS2)              | EAC (Rust)              |
|-------------------------|---------------------------|------------------------|-------------------------|
| Ring level              | 3 (user)                  | 3 (user) + Trusted Mode| 0 (kernel)              |
| Driver checks           | By name/path              | Limited                | Full kernel visibility  |
| Physical memory access  | Cannot detect directly    | Cannot detect directly | Can detect DMA devices  |
| Handle enumeration      | Via Win32 API             | Via Win32 API          | Via kernel callbacks    |
| Page table walking      | No visibility             | No visibility          | Can monitor CR3 changes |
| Hook detection          | Checks known functions    | Checks known functions | Kernel-level integrity  |

**Warden is the least aggressive** of the anti-cheats this project would face. The
`KernelMemoryReader` and `KoshcheiPipeReader` approaches that work against VAC (CS2)
would likely be effective against Warden as well, since Warden has strictly less
visibility (user-mode only, no kernel driver).

---

## 6. Warden-Specific Considerations for WoW Support

### 6.1 Offset acquisition

Unlike CS2 (which has community dumpers like `cs2-dumper`), WoW offsets are typically
obtained by:
- Reverse-engineering the WoW client binary
- Using IDA/Ghidra with community-maintained signature databases
- Pattern scanning the WoW process for known byte signatures
- Community offset databases (e.g., OwnedCore offset dumps per build)

WoW updates frequently change offsets, similar to CS2.

### 6.2 Warden module detection

If adding WoW support, the tool should be aware of Warden's scan timing. Warden scans are
**periodic but not predictable** -- the server can request a scan at any time. Key
considerations:
- Scans arrive as `SMSG_WARDEN_DATA` packets
- The module can `Tick()` at any time for timing checks
- Write operations to WoW memory are more dangerous than reads, since page-hash checks
  can detect modified bytes

### 6.3 What NOT to do (Warden specifically detects these)

1. **Don't inject DLLs** -- MODULE_CHECK will hash and flag them
2. **Don't hook game functions** -- MEM_CHECK reads function prologues
3. **Don't modify game data files** -- MPQ_CHECK hashes archives
4. **Don't create Lua globals** -- LUA_EVAL_CHECK can query for them
5. **Don't use known/banned driver names** -- DRIVER_CHECK scans by name
6. **Don't leave a predictable window title** -- process enumeration can find it

### 6.4 Architecture implications

The safest approach for WoW (from a detection standpoint) would be:
- **External overlay** (as this project already does for CS2)
- **Kernel-level memory reading** (KernelMemoryReader or KoshcheiPipeReader)
- **Read-only** where possible (avoid writes that trigger page-hash mismatches)
- **No injection** into the WoW process
- **Obfuscated/randomized** binary signatures (the existing XOR encoding and Obfuscar
  pipeline help here)

---

## 7. Community Resources & Reference Repositories

### 7.1 UnknownCheats (unknowncheats.me)

UnknownCheats has a dedicated **World of Warcraft** subforum
(`unknowncheats.me/forum/world-of-warcraft/`) that covers memory editing, Warden
research, and reverse engineering. The site is not indexed by standard search engines
and requires direct browsing. Key areas to look at:

- **WoW Memory Editing subforum** -- active threads on object manager traversal, offset
  dumps per build, Warden scan analysis, and external reading techniques
- **Warden discussion threads** -- community analysis of scan batches, module hashes,
  and detection vectors. Historical threads document how Warden's checks evolved across
  expansions.
- **Offset dump threads** -- per-build offset posts (similar to OwnedCore's format) that
  track object manager base, entity list pointers, player structure offsets, and camera
  data across client patches
- **Anti-cheat research** -- general anti-cheat evasion research applicable across games,
  including kernel-mode reading, DMA techniques, and hypervisor-based approaches

Note: The site requires registration to view most content. Threads are version-specific
and go stale quickly as WoW patches. Cross-reference with OwnedCore's WoW Memory Editing
section which has overlapping but distinct communities.

### 7.2 OwnedCore (ownedcore.com)

OwnedCore's **WoW Memory Editing** subforum is the most active public forum for WoW
reverse engineering. Recent threads of note:

| Thread | Build | Content |
|--------|-------|---------|
| [Classic Era 1.15.3 Object Manager](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1031380-wow-classic-era-1-15-3-object-manager-object-traversal-offsets.html) | 1.15.3 | Object traversal loop, entity pointer offsets |
| [Classic 1.15.5.57638 Object Manager Changes](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1052959-wow-classic-1-15-5-57638-object-manager-changes.html) | 1.15.5 | Structural changes mirroring retail |
| [Classic 1.15.5.57979 Offsets](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1065876-wowclassic-1-15-5-57979-offsets.html) | 1.15.5 | Updated base pointers |
| [Classic 1.15.5.58555 Offsets](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1070187-wowclassic-1-15-5-58555-offsets.html) | 1.15.5 | Full offset dump |
| [Classic 1.15.6.58797 Offsets](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1072394-wowclassic-1-15-6-58797-offsets.html) | 1.15.6 | Camera offset changed to 0x3A58 |
| [Classic 1.15.7.60249 Offsets](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1089013-wowclassic-1-15-7-60249-offsets.html) | 1.15.7 | Latest Classic Era offsets |
| [Classic 1.15.7.60277 Offsets](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1090127-wowclassic-1-15-7-60277-offsets.html) | 1.15.7 | Camera moved to 0x478 |
| [Warden Private Server](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1030859-warden-private-server.html) | 3.3.5a | Warden enum, function offsets, module loading |
| [WardenScanner Release](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1103699-wardenscanner-external-warden-monitor-wow-3-3-5a.html) | 3.3.5a | External Warden monitoring tool |
| [Warden Module Myth?](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/968370-warden-module-myth.html) | Various | Discussion on whether Warden modules are real or myth |

Key observation: offsets change with **every minor patch**. The camera offset alone went
from 0x3A58 (1.15.6) to 0x478 (1.15.7). Any WoW support would need an offset update
pipeline similar to `update_offsets.sh` for CS2.

### 7.3 GitHub Repositories

#### Warden-Specific Research Tools

| Repository | Description | Use Case |
|------------|-------------|----------|
| [Likon69/WardenScanner](https://github.com/Likon69/WardenScanner) | External Warden monitor for 3.3.5a. Passive mode reads Warden state without injection. HWBP mode traces module loads and decodes scan batches. Classifies scan targets as BOT_SURFACE, INJECT, SYSTEM. | **Best starting point** for understanding what Warden looks for and when. Study its scan-type decoder and detection classification. |
| [Kelsidavis/WoWee](https://github.com/Kelsidavis/WoWee) | Open-source custom WoW client. Emulates Warden modules via Unicorn Engine x86 emulation with hooked Windows APIs. Full protocol implementation. | **Best reference** for the Warden protocol, module loading pipeline, RC4/RSA crypto, check-type opcodes, and response format. The `docs/WARDEN_IMPLEMENTATION.md` is the most complete public Warden spec. |
| [namreeb/WardenSigning](https://github.com/namreeb/WardenSigning) | Research on cracking Warden module RSA-2048 signatures. Includes **72 sniffed Warden modules** with RC4 keys. Found no exploitable vulnerability. | Useful for the module collection and understanding Warden's cryptographic verification. |
| [Wow-Private-Server/Warden-Export](https://github.com/Wow-Private-Server/Warden-Export) | DLL-injection tool that intercepts Warden module at runtime, dumps from memory, and reconstructs a valid PE file with IAT resolution. | Reference for Warden module memory layout and PE reconstruction. |

#### WoW Client Reverse Engineering

| Repository | Description | Use Case |
|------------|-------------|----------|
| [samwhosung/benilla-re](https://github.com/samwhosung/benilla-re) | Comprehensive RE of WoW 1.12.1 client (build 5875). 37,967 documented functions. Systems: objectlayer, spell, collision, **warden**, net, models, terrain. Ghidra/IDA/x64dbg databases. C header with all structs. | **Gold standard** for client structure reference. The `objectlayer` system documents the object manager. Warden system docs show anti-cheat internals. |
| [SatyPardus/wowdecomp15595](https://github.com/SatyPardus/wowdecomp15595) | C++ decompilation of WoW 4.3.4 (build 15595). Each function tagged with original address. | Reference for Cataclysm-era structures. Useful for understanding how object layouts evolved from Vanilla. |
| [dna113p/Aesha](https://github.com/dna113p/Aesha) | **C# object manager** for WoW 1.12.1. Exposes `Me`, `Players`, `Units` accessors. Uses `ReadProcessMemory` for external reading. | **Most directly relevant** to this project's architecture. C# codebase, external memory reading, entity enumeration -- same pattern as our EntityManager classes. |
| [wowdev (GitHub org)](https://github.com/wowdev) | Community org for WoW client tooling. Hosts `WoWDBDefs` (client database definitions), DBC/DB2 parsing libraries, file format documentation. | Reference for game data structures and file formats. |
| [Arctium/WoW-Launcher](https://github.com/Arctium/WoW-Launcher) | Game launcher that connects to custom servers. Supports clients up to mainline 12.0.5. Points to arctium.io for extended tooling. | Useful for understanding client versioning and sandbox connection. Not a memory tool itself. |

#### Bot Frameworks (Reference Architecture)

| Repository | Description | Use Case |
|------------|-------------|----------|
| [DrewKestell/BloogBot](https://github.com/lone1y/bloogbot) | In-process bot for 1.12.1, TBC 2.4.3, WotLK 3.3.5. C++ with extensive documentation. Private server only. | Architecture reference for WoW game-state reading and entity interaction patterns. |
| [AzDeltaQQ/WotLKRotations](https://github.com/AzDeltaQQ/WotLKRotations) | Python bot framework using `pymem` for external memory reading on 3.3.5a (build 12340). Reads object manager for combat state. | Shows Python-based external reading approach with pymem. |
| [Xartrick/WoWObjectManager](https://github.com/Xartrick/WoWObjectManager) | C# object manager with offset definitions for WoW 5.3.0. Demonstrates MoP-era offset structure. | Reference for how offsets are organized in a C# project. |

#### Server Emulators (Warden Implementation)

| Repository | Description | Use Case |
|------------|-------------|----------|
| [TrinityCore/TrinityCore](https://github.com/TrinityCore/TrinityCore) | 10.8k stars. Open-source MMO framework. Contains **server-side Warden implementation** including check definitions, scan scheduling, and result verification. | Read `src/server/game/Warden/` for the canonical Warden check types, payloads, and verification logic. The AzerothCore `Warden.h` enums come from here. |
| [azerothcore/azerothcore-wotlk](https://github.com/azerothcore/azerothcore-wotlk) | 9.1k stars. WotLK 3.3.5a server with maintained Warden checks. Doxygen docs expose check-type enums and payload structures. | The [Warden.h doxygen](https://www.azerothcore.org/doxygen/d7/dc7/Warden_8h.html) is the best reference for check-type byte values and response codes. |
| [TrinityCore/WowPacketParser](https://github.com/TrinityCore/WowPacketParser) | C# packet parser. Contains Warden opcode parsing in `WoWPacketViewer/Parsers/Warden/`. | Reference for SMSG/CMSG_WARDEN_DATA packet structure and field layout. |
| [tomrus88/WoWTools](https://github.com/tomrus88/WoWTools) | WoW packet viewer with Warden parsers. `CMSG_WARDEN_DATA.cs` walks check results by type (MEM_CHECK, PAGE_CHECK, etc). | Shows how Warden responses are deserialized from the wire format. |

#### Utility Tools

| Repository | Description | Use Case |
|------------|-------------|----------|
| [GH-Offset-Dumper](https://github.com/guided-hacking/GH-Offset-Dumper) | Generic external offset dumper -- signature scans a process and dumps offsets to a header file. Not WoW-specific. | Could be adapted as a WoW offset dumper, similar to how `cs2-dumper` works for CS2. |
| [CheatEngine WoW 1.12.1 offset finder (gist)](https://gist.github.com/LaBlazer/442d8eed354777f5455b9014de5bc60d) | Cheat Engine Lua script that walks the object list to find player base address. | Quick reference for the object manager walk pattern (global pointer -> linked list -> GUID match). |

---

## 8. Open Questions / Further Research

- What does retail (current expansion) Warden look like vs. 3.3.5a? Most public research
  targets private servers running old builds.
- Does modern WoW use any kernel-level component? No public evidence, but Blizzard has
  the Ricochet kernel driver from the Activision side.
- How does Warden interact with Windows Hypervisor-Protected Code Integrity (HVCI)?
- What is Warden's current HWID fingerprinting scope?
- Does Warden use hardware performance counters or timing side-channels?
- UnknownCheats WoW subforum requires direct browsing for current threads -- search
  engines do not index it. Check for recent retail offset dumps and Warden analysis there.

---

## Sources

### Wiki / Documentation
- [Warden (software) - Warcraft Wiki](https://warcraft.wiki.gg/wiki/Warden_(software))
- [Warden (software) - Wowpedia](https://wowpedia.fandom.com/wiki/Warden_(software))
- [AzerothCore Warden.h Doxygen](https://www.azerothcore.org/doxygen/d7/dc7/Warden_8h.html)
- [TrinityCore Warden checks DB schema](https://trinitycore.info/database/335/world/warden_checks)

### GitHub Repositories
- [Likon69/WardenScanner](https://github.com/Likon69/WardenScanner) -- External Warden monitor (3.3.5a)
- [Kelsidavis/WoWee](https://github.com/Kelsidavis/WoWee) -- Custom client with full Warden emulation
- [namreeb/WardenSigning](https://github.com/namreeb/WardenSigning) -- Warden RSA signature research + 72 modules
- [Wow-Private-Server/Warden-Export](https://github.com/Wow-Private-Server/Warden-Export) -- Warden module dumper
- [samwhosung/benilla-re](https://github.com/samwhosung/benilla-re) -- WoW 1.12.1 full RE (37k functions)
- [SatyPardus/wowdecomp15595](https://github.com/SatyPardus/wowdecomp15595) -- WoW 4.3.4 decompilation
- [dna113p/Aesha](https://github.com/dna113p/Aesha) -- C# external object manager (1.12.1)
- [Xartrick/WoWObjectManager](https://github.com/Xartrick/WoWObjectManager) -- C# object manager (5.3.0)
- [TrinityCore/TrinityCore](https://github.com/TrinityCore/TrinityCore) -- Server-side Warden implementation
- [azerothcore/azerothcore-wotlk](https://github.com/azerothcore/azerothcore-wotlk) -- WotLK server with Warden
- [TrinityCore/WowPacketParser](https://github.com/TrinityCore/WowPacketParser) -- Warden packet parsing
- [tomrus88/WoWTools](https://github.com/tomrus88/WoWTools) -- Warden response deserialization
- [wowdev (org)](https://github.com/wowdev) -- Client database definitions and file formats
- [Arctium/WoW-Launcher](https://github.com/Arctium/WoW-Launcher) -- Custom server launcher
- [lone1y/bloogbot](https://github.com/lone1y/bloogbot) -- In-process WoW bot (reference architecture)
- [AzDeltaQQ/WotLKRotations](https://github.com/AzDeltaQQ/WotLKRotations) -- Python external reader (3.3.5a)
- [guided-hacking/GH-Offset-Dumper](https://github.com/guided-hacking/GH-Offset-Dumper) -- Generic offset dumper

### Forum Threads (OwnedCore)
- [Classic Era 1.15.3 Object Manager](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1031380-wow-classic-era-1-15-3-object-manager-object-traversal-offsets.html)
- [Classic 1.15.7.60277 Offsets](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1090127-wowclassic-1-15-7-60277-offsets.html)
- [Warden Private Server](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1030859-warden-private-server.html)
- [WardenScanner Release Thread](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-bots-programs/wow-memory-editing/1103699-wardenscanner-external-warden-monitor-wow-3-3-5a.html)
- [Warden FAQ](https://www.ownedcore.com/forums/world-of-warcraft/world-of-warcraft-general/241075-warden-faq.html)

### Articles / Blog Posts
- [Deceiving Blizzard Warden - HackMag](https://hackmag.com/stuff/deceiving-blizzard-warden)
- [Exploiting Warden Behaviour - Jordan Whittle](https://jordanwhittle.com/posts/exploiting-warden/)
- [WoW Warden Anti-Cheat Explained (hwidchange.com)](https://hwidchange.com/en/blog/wow-warden-anticheat)
- [SuperWoW Warden Detection (deepwiki)](https://deepwiki.com/balakethelock/SuperWoW/6.4-warden-anti-cheat-detection)
- [Your Anti-Cheat Is a Rootkit (urandom.io)](https://urandom.io/blog/2026-03-15-your-anti-cheat-is-a-rootkit)
- [What Kernel-Level Anti-Cheat Is (levvvel.com)](https://levvvel.com/tech/what-is-kernel-level-anti-cheat-software/)
- [WoW Classic TBC Bot Creation Journey (Medium)](https://medium.com/@lconstan/wow-classic-tbc-a-journey-into-bot-creation-1ae9f1e54db9)

### Community Forums (UnknownCheats)
- [UnknownCheats WoW Section](https://www.unknowncheats.me/forum/world-of-warcraft/) -- Not indexed by search engines; requires direct browsing and registration. Active threads on memory editing, Warden analysis, offset dumps, and external reading techniques.
