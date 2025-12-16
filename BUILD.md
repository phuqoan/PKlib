BUILD
=====

This file documents how to assemble and link the sources in this repository (16-bit x86, Turbo Assembler/Linker), and how to run the examples in DOSBox.

Prerequisites
-------------

- `tasm` (Turbo Assembler) and `tlink` (Turbo Linker) available in your PATH, or accessible inside a DOSBox environment.
- A DOS runtime or emulator (e.g., DOSBox) to run the produced 16-bit executables.

Assemble & Link (native DOS / command prompt where `tasm`/`tlink` exist)
-----------------------------------------------------------------

1. Open a command prompt with `tasm` and `tlink` on PATH (or run inside DOSBox).
2. Change to the `src` directory and run the supplied build batch:

```bat
cd src
ASM.BAT
```

What `ASM.BAT` does
--------------------

- Assembles the example programs (if their .obj files are missing):
  - `tasm /m9 /oi EXAMPLE0.ASM` and `tasm /m9 /oi EXAMPLE1.ASM`
- Assembles the library source:
  - `tasm /m9 /a /oi IMPLODE.ASM`
- Links example objects to the library:
  - `tlink EXAMPLE0.OBJ IMPLODE.OBJ`
  - `tlink EXAMPLE1.OBJ IMPLODE.OBJ`

Running in DOSBox (recommended on modern systems)
-------------------------------------------------

1. Install DOSBox (https://www.dosbox.com/) and put `tasm`/`tlink` binaries into a folder (e.g., `C:\dosdev`).
2. Start DOSBox and mount your repository and the dev tools. Example commands inside DOSBox:

```bat
mount c C:\path\to\your\repo
mount d C:\dosdev
set PATH=d:\;d:\bin;...
c:
cd \PKlib\src
ASM.BAT
```

3. After building, run the example executable(s) produced in `src/` (e.g., `EXAMPLE0.EXE` test mode binary,
`EXAMPLE1.EXE` test mode ascii) inside DOSBox. Ensure a `TEST.IN` file exists in `src/` before running the example.

Troubleshooting
---------------

- If `tasm`/`tlink` are missing: either install them in the DOS environment or use compatible 16-bit assemblers/linkers.
- Line endings: if running inside DOSBox, ensure batch files use CRLF line endings.
- Case sensitivity: DOS is case-insensitive; file names in batch may use different case than repo but will still work on Windows/DOS.

Optional next steps I can do for you
-----------------------------------

- Extract a short API reference for `Implode`/`Explode` showing stack layout and parameter order.
- Port the build to a modern cross-assembler toolchain (if desired).
