PKlib
=====

Overview
--------

PKlib contains x86 16-bit Assembly sources for the PKWARE-style data compression library (Implode/Explode) and example programs demonstrating how to call the compression/decompression routines from assembly. These are historical sources (circa early 1990s) intended as reference or for educational use.

Requirements
------------

- Turbo Assembler (`tasm`) and Turbo Linker (`tlink`) as used by the supplied build script `ASM.BAT`.
- A DOS/16-bit development environment (or an emulator like DOSBox) to assemble and run the examples.

Build
-----

From the `src/` directory run the provided batch file to assemble and link the example programs:

```bat
cd src
ASM.BAT
```

`ASM.BAT` calls `tasm`/`tlink` to assemble `EXAMPLE0.ASM`/`EXAMPLE1.ASM` and `IMPLODE.ASM` and link the executables.

Usage
-----

- The examples read `TEST.IN`, compress it to `TEST.CMP` using `Implode`, then decompress to `TEST.EXT` using `Explode`.
- To run the examples, place a test input file named `TEST.IN` in `src/` and run the produced EXE(s) in a DOS environment or emulator.

Key files
---------

- `src/IMPLODE.ASM` - compression implementation (main library source).
- `src/EXAMPLE1.ASM` - example program that calls `Implode` and `Explode` (shows how to supply read/write callbacks).
- `src/ASM.BAT` - build script using `tasm` and `tlink`.
- `src/TEST.IN`, `src/TEST0.BAT`, `src/TEST1.BAT` - test inputs and helper scripts.

License & Copyright
-------------------

These sources include code labeled as "PKWARE Data Compression Library" (copyright notices present in the example sources). The repository does not add or change licensing information. Before using or redistributing this code, confirm copyright and licensing with the original owner (PKWARE) or ensure your use complies with applicable laws.

Contributing
------------

If you want help modernizing, porting, or documenting these sources (for example porting to a modern assembler or extracting the algorithm), open an issue or a PR describing the intended change and target environment (DOSBox, cross-compile, etc.).

Contact / Next steps
-------------------

If you'd like, I can:

- Add a short `BUILD.md` with exact `tasm`/`tlink` flags used by `ASM.BAT`.
- Create a small DOSBox run script to assemble and test automatically.
- Extract a concise API reference showing the `Implode`/`Explode` stack parameters.

Choose one and I'll proceed.
