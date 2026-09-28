# AMIX Cross-Toolchain Bootstrap

This directory bootstraps a Linux-hosted AMIX cross toolchain for the target:

```text
m68k-cbm-sysv4
```

Current status:

```text
C compiler: works
GNU assembler: works
GNU ld: works
Target libgcc.a, ar and ranlib: built and installed
Dynamically linked AMIX C executable: works on AMIX baremetal
Kernel and driver objects: work
Code generation and assembly: -m68020, -m68030, -m68040, -m68060
Preprocessing (-E): works, so autoconf configure scripts can use it
C++ / g++: not complete yet
```

The compiler installed as `m68k-cbm-sysv4-gcc` is a wrapper script, not the
compiler binary. It repairs GCC's assembly output before assembling it; see
"What The Wrapper Repairs" below for what it corrects and why bypassing it
produces silently wrong code.

## Redistribution Notice

This repository must not include AMIX headers, libraries, startup objects, or
full system trees. Each user must provide their own AMIX sysroot from a
licensed AMIX installation.

Do not commit files such as:

```text
usr/include/*
usr/lib/libc.so.1
usr/lib/ld.so.1
usr/ccs/lib/crt*.o
usr/ccs/lib/mcrt*.o
usr/ccs/lib/pcrt*.o
```

## Quick Start On LMDE

First copy or mount your AMIX tree on Linux. The examples below assume:

```sh
AMIX_ROOT=/media/sf_Storage/usr-amix
```

The tree should contain at least:

```text
$AMIX_ROOT/usr/include
$AMIX_ROOT/usr/lib/libc.so.1
$AMIX_ROOT/usr/lib/ld.so.1
$AMIX_ROOT/usr/ccs/lib/crt1.o
$AMIX_ROOT/usr/ccs/lib/crti.o
$AMIX_ROOT/usr/ccs/lib/crtn.o
```

Build and install, from the repository root:

```sh
make deps-hint
make all AMIX_ROOT=$AMIX_ROOT
. build/env.sh
make validate-sysroot AMIX_ROOT=$AMIX_ROOT
make test-hello AMIX_ROOT=$AMIX_ROOT
```

The Makefile refreshes old `config.guess` and `config.sub` files from
`/usr/share/misc`, so install `autotools-dev` on LMDE before building.

The default install prefix is:

```sh
$HOME/opt/amix-cross
```

Use `/opt/amix-cross` if preferred:

```sh
make PREFIX=/opt/amix-cross all
```

If `/opt/amix-cross` is root-owned, create it first and give yourself write
access, or run the install phases with suitable privileges.

## Building AMIX Programs

After `make all` and `. build/env.sh`, a normal C build should work:

```sh
cat > hello.c <<'EOF'
#include <stdio.h>

int
main(void)
{
	puts("hello from AMIX cross");
	return 0;
}
EOF

m68k-cbm-sysv4-gcc hello.c -o hello
file hello
```

Expected:

```text
ELF 32-bit MSB executable, Motorola m68k, 68020, version 1 (SYSV), dynamically linked
```

Copy the executable to AMIX and run it there.

The wrapper also handles the cases a real build runs into:

- `-E` preprocesses and does not link. It is dispatched to the real cross
  compiler with the target include path, exactly as `-S` is. Before that,
  `-E` fell through to the link path: `m68k-cbm-sysv4-gcc -E foo.c` compiled and
  linked instead of preprocessing and printed nothing on stdout.
- An archive or shared library named on the command line is linked *after* the
  objects. `m68k-cbm-sysv4-gcc prog.c libfoo.a` used to link as
  `libfoo.a prog.o`, and single-pass `ld`, meeting the archive with nothing yet
  undefined, extracted no members and left every symbol in it undefined.
- `libc` is always linked, at the end of the library list. It used to be added
  only when the command line carried no `-l` at all, so a lone `-lfoo` dropped
  it and the link failed on `crt1.o`'s own references (`atexit`, `exit`,
  `_environ`, `__fpstart`). A trailing `-lc` is no longer needed; a redundant
  one is harmless.
- The installed `libgcc.a` is appended to every link, so the soft-arithmetic
  helpers (`__udivdi3`, `__umoddi3`, `__lshrdi3`, the DImode/float conversions)
  resolve without an explicit `-lgcc`.
- `-lNAME` reaches `ld` as `-L<dir> -lNAME`, so the dependency recorded in the
  executable is a name the **guest** can resolve. `ld` records a shared library
  in `DT_NEEDED` under the name it was given unless the library has its own
  `DT_SONAME`, and on this target only `libc.so.1` and `ld.so.1` have one --
  `libsocket.so`, `libnsl.so` and every stock `libX*.so` have none. The wrapper
  used to resolve each `-l` to a file in the build host's sysroot and pass that
  path, so the executable carried
  `NEEDED [/home/<user>/opt/amix-cross/.../usr/lib/libsocket.so]`, a path that
  exists on no AMIX box. The link succeeded and the binary looked correct; it
  died at exec time on the guest. `libc` is still named by path on purpose: the
  sysroot ships `libc.so.1` rather than `libc.so`, so `-lc` could not find it,
  and its `DT_SONAME` is what gets recorded anyway.
- `-c` with no `-o` writes the object into the **current working directory**
  under the input's basename: `m68k-cbm-sysv4-gcc -c ../src/foo.c` produces
  `./foo.o`, and so does `-c ../src/foo.s`. An explicit `-o` is honoured
  verbatim, including a path into another directory.

  This is a change in behaviour for **any compile whose source is not in the
  directory `make` was run from** -- the discriminator is the working directory
  versus the source's own directory, not whether the build uses a separate
  object directory. A non-recursive top-level `Makefile` compiling `sub/foo.c`
  is affected exactly as a VPATH build is; only a compile whose source is in
  the working directory is unchanged, because there the two locations coincide.

  For `.c` sources the wrapper used to keep the directory part and write
  `../src/foo.o`, next to the source. That broke every build compiling from
  elsewhere -- gcc's own build, imake/X11, any autoconf package configured from
  a separate build tree, and any Makefile naming its sources `sub/foo.c`. The
  compile still reported success, so the failure surfaced at the link as
  `ld: cannot open foo.o: No such file or directory`, with stray objects left
  behind in the source tree.

  For `.s`/`.S` inputs the same missing `-o` was worse, because those are
  passed to the real compiler rather than assembled by the wrapper: it forwarded
  an *empty* `-o`, which `gcc 2.7.2.3` drops from the command line it builds, so
  the assembler ran as `as -V -Qy -o ../src/foo.s` -- the file that should have
  been the input became the output. In a non-interactive build `as` then read an
  empty stdin, produced no `.o` anywhere and exited 0; on a terminal the compile
  hung. For a `.s` input the clobbered file is the assembly source itself, so
  the build **replaced its own source with an object**; for `.S` it is gcc's
  preprocessed temporary, so only the object is lost. A plain `.s.o:` suffix
  rule triggered this on every file it touched.

### Using autoconf

Since `-E` is a real preprocessor, autoconf's "checking how to run the C
preprocessor" step passes, so `AC_CHECK_HEADER` reads the AMIX headers in the
sysroot instead of falling back to the build host's `/lib/cpp` and deciding
every `HAVE_*` against Linux headers. Point `configure` straight at the cross
compiler:

```sh
. build/env.sh
CC=m68k-cbm-sysv4-gcc ./configure --host=m68k-cbm-sysv4
```

No separate preprocessor shim is needed.

## What The Wrapper Repairs

GCC 2.7.2.3 targets this machine through `config/m68k/sgs.h`, so it emits the
native SGS assembler's spellings. GNU as 2.8.1 rejects some of them and, worse,
assembles others *silently to a different instruction*. The wrapper runs ten
rewrite rules over every generated `.s` file before handing it to `as`:

1. `.swbeg &N` becomes an explicit 4-byte filler. GNU as parses `.swbeg` but
   emits zero bytes, while gcc's switch dispatch assumes the 4 bytes are there,
   so every switch case was entered 4 bytes late.
2. `tdivs`/`tdivu` become `divsl`/`divul`. GNU as assembles the SGS spelling as
   the 64-bit-dividend form, so every variable-divisor `/` and `%` returned
   garbage. **Silent miscompile.**
3. Register-to-register `fsgldiv.s`/`fsglmul.s` become `.x`, the only suffix
   gas accepts on that shape. Memory and data-register sources are left alone:
   there the `.s` is legal and encodes a genuinely different instruction.
4. Inside bit-field braces, `#` becomes `&`, the immediate prefix on this
   target, for all eight bit-field mnemonics (`bfchg`, `bfclr`, `bfexts`,
   `bfextu`, `bfffo`, `bfins`, `bfset`, `bftst`). `#` is a line-comment
   character here, so gas scrubbed the rest of any hand-written
   `bfffo %d3{#0:#32},%d2` and lost the instruction.
5. The three-operand `.lcomm name,size,align` loses its alignment operand,
   leaving the two-operand form this assembler takes.
6. `cmp.[bwl]` and `fcmp.[bwlsdxp]` get GNU operand order back. `sgs.h` sets
   `SGS_CMP_ORDER`, so gcc prints the two operands reversed. With a memory
   operand gas rejects it; with two FPU registers it assembles cleanly to a
   *different* encoding, and the following `fbgt`/`fsgt` then tests the reversed
   relation. **Silent miscompile.**
7. `f[sd]{add,sub,mul,div,mov,abs,neg,sqrt}` with an FPn source gets the `.x`
   suffix. The suffix names the source operand format, and a register source is
   extended precision by definition.
8. `fdmov` becomes `fdmove`. gas knows `FSMOV` by the short name but `FDMOV`
   only spelled out -- an asymmetry in its opcode table.
9. The sized control-register `fmovm` becomes `fmovem`. The suffixless
   register-list form used in prologues is fine and is not touched.
10. `mov &N,%dN` becomes `mov.l`.

Rules 7 to 10 are shapes gcc emits at `-m68040`.

Do not invoke `m68k-cbm-sysv4-gcc.real` directly. That is the unwrapped
compiler, and its output is exactly what the rules above repair. Rules 2 and 6
fail without any diagnostic, so code built that way assembles, links, runs and
computes the wrong answer.

## Regression Gates

Each gate below checks the *emitted encoding*, not merely that the file
assembled -- a mangled offset or a reversed compare assembles just as quietly.
Run all of them after any change to `fix_asm`.

```text
make test-divmod     divides use the 32-bit-dividend divsll/divull (rule 2)
make test-float      register-to-register fsgldiv/fsglmul are .x, memory
                     and data-register forms untouched (rule 3)
make test-fcmp       the fcmp destination is the register the fmul wrote,
                     i.e. the compare sense survived (rule 6)
make test-bitfield   bit-field offset and width survive as extension-word
                     bits 10:6 and 4:0, register-select bits clear (rule 4)
make test-uint64     64-bit / % and >> link, with __udivdi3 __umoddi3
                     __lshrdi3 resolved from the installed libgcc.a
make test-objdir     -c with no -o writes ./basename.o into the working
                     directory and leaves the source directory clean, for
                     .c, .s and .S alike, while an explicit -o is still
                     honoured verbatim
make test-dtneeded   a program linked against -lsocket -lnsl records bare
                     library names, no build-host path, and still depends
                     on /usr/lib/libc.so.1
make test-kernel-volatile
                     under AMIX_KERNEL_CFLAGS, spl6()/splx() still write
                     %sr and a volatile register poll re-reads memory
make test-user-volatile
                     under AMIX_USER_CFLAGS, a volatile register poll
                     re-reads memory and a const table is read-only data
```

The first four compile with `-c` at both `-O0` and `-O` and inspect the object
with `objdump`, so they need only the installed wrapper; `test-objdir` likewise
needs nothing but the wrapper. `test-uint64` and `test-dtneeded` link, so like
`test-hello` they need the AMIX crt objects and `libc.so.1` in the sysroot;
`test-dtneeded` additionally needs `libsocket.so` and `libnsl.so` there.
`test-kernel-volatile` needs the AMIX headers (`AMIX_ROOT`), and
`test-user-volatile` needs them in the sysroot (`SYSROOT`); see below.

The gates test an installed toolchain, so run `make all` first. They reinstall
only the wrapper script (`make refresh-gcc-wrapper`), so an edit to
`amix-gcc-wrapper.sh` is picked up, but they never reconfigure gcc or reinstall
binutils, which would replace the `ar`/`ranlib` wrappers from
`make install-target-ar`. `test-uint64` still rebuilds and reinstalls
`libgcc.a`, and `test-dtneeded` still runs the `sysroot` copy.

Every gate first runs `make sysroot-check`, which fails unless
`$SYSROOT/usr/lib/libc.so.1` is an ELF shared object; the generated `env.sh`
makes the same check when sourced. `make sysroot` leaves the stock files it
copies read-only (directories stay writable for added libraries) and lifts
that protection itself when it runs again.

## Important Variables

```sh
TARGET=m68k-cbm-sysv4
BINUTILS_VERSION=2.8.1
GCC_VERSION=2.7.2.3
CPUFLAGS=-m68020
AMIX_ROOT=/path/to/usr-amix
SYSROOT=$HOME/opt/amix-cross/m68k-cbm-sysv4/sysroot
AMIX_CRT_DIR=$SYSROOT/usr/ccs/lib
```

`CPUFLAGS` selects the assembler architecture as well as code generation. The
wrapper scans the compile line for `-m68030`, `-m68040` or `-m68060` and passes
the same flag to `as`; with none of them present it assembles `-m68020`. The
choice changes the opcodes emitted, so it is not just a validity check:

- at `-m68020` gcc emits `FSGLMUL`/`FSGLDIV` for single-precision multiply and
  divide. The 68060 implements neither, so every one of them traps into the
  FPSP and is emulated.
- at `-m68040` gcc emits `FSMUL`/`FSDIV` instead, which both the 040 and the 060
  retire in hardware. `-m68040` is therefore the right choice for an 040 or 060
  target.

Because the emitted opcodes differ, do not mix objects built with different
`CPUFLAGS` in one link.

`AMIX_ROOT` is where your own AMIX tree is mounted or copied. Always pass it
explicitly: its Makefile default points two directories above the repository, a
leftover from when this toolchain lived inside a larger tree, and in a
standalone clone that path means nothing.

`AMIX_SYSROOT` and `AMIX_CRT_DIR` are read by the installed wrapper at run time.
`AMIX_SYSROOT` overrides the prefix-relative default `$PREFIX/$TARGET/sysroot`,
and `AMIX_CRT_DIR` overrides `$AMIX_SYSROOT/usr/ccs/lib`. Set them if you keep
the sysroot outside the install prefix. `make env` writes both into
`build/env.sh`, together with `PATH`, `AMIX_ROOT`, `AMIX_KERNEL_CFLAGS` and
`AMIX_USER_CFLAGS`;
`build/env.sh` is generated, machine-specific and git-ignored, so source it
rather than edit it.

`HOST_CFLAGS` defaults to `-O2 -g -std=gnu89 -fcommon -no-pie` because the 1990s GNU
configure tests and sources expect pre-C99 implicit `int` behavior.

`BINUTILS_DISABLE_DIRS` is empty by default now. GNU `ld` must build for the
toolchain to become self-contained.

## AMIX Runtime Files

Linux-side linking needs the AMIX startup objects in addition to `libc.so.1`
and `ld.so.1`. The `sysroot` target copies `usr/include`, `usr/lib`,
`usr/sys`, and `usr/ccs` from `AMIX_ROOT` when present.

Look on AMIX in likely locations:

```sh
ls -l /usr/ccs/lib /usr/lib /lib
find / -name 'crt*.o' -o -name 'values-X*.o'
```

The Makefile currently checks for:

```text
crt1.o
crti.o
crtn.o
```

If they live outside the sysroot default, pass that directory:

```sh
make check-runtime AMIX_ROOT=/media/sf_Storage/usr-amix AMIX_CRT_DIR=/media/sf_Storage/usr-amix/usr/ccs/lib
```

Once `ld` and those startup files are available, try:

```sh
make test-hello AMIX_ROOT=/media/sf_Storage/usr-amix
```

The installed wrapper supports the normal C path once the sysroot contains
`usr/ccs/lib`:

```sh
m68k-cbm-sysv4-gcc hello.c -o hello
```

Build and test a C hello binary on AMIX before working on `gcc-full` / C++.

## Kernel And Driver Objects

Example:

```sh
make AMIX_ROOT=$HOME/src/usr-amix CPUFLAGS=-m68030 test-random
```

### Kernel CFLAGS: -traditional and volatile

`AMIX_KERNEL_CFLAGS` compiles with `-traditional`, which clears `__STDC__`, and
the stock `<sys/types.h>` then does `#define volatile` and `#define const`
(empty); that silently strips the `volatile` from the `asm volatile` spl
primitives in `<sys/inline.h>`, so gcc deletes `splx()` and any `spl6()` whose
result only feeds it, and every MMIO `volatile` access is erased too (a 32-bit
register poll read once, as a byte, then spinning on a register). The flags
therefore carry `-Dvolatile=__volatile__ -Dconst=__const__` beside
`-Dinline=__inline__`, which the header's `#ifndef` guards respect;
`make test-kernel-volatile` gates it.
Objects built with the old flags should be rebuilt.

### User CFLAGS: the same trap

`AMIX_USER_CFLAGS`, the suggested flags for user programs built the way the
native AMIX compiler builds them, also use `-traditional`, so any unit that
includes `<sys/types.h>` (directly or through most system headers) lost
`volatile` and `const` the same way: a poll through a `volatile` pointer was
read once and the loop spun on a register, and `const` tables were placed in
writable `.data`. They now carry the same
`-Dvolatile=__volatile__ -Dconst=__const__`, `make env` exports them into
`build/env.sh`, and `make test-user-volatile` gates them. Code that relies on
`volatile` (signal flags, shared memory, device registers) and was built with
the old flags should be rebuilt; with the fix `const` data moves to `.rodata` in the
read-only text segment, so a program that writes through a cast-away `const`
now faults instead of silently succeeding.

## AMIX Makefiles

Old AMIX Makefiles often hardcode native tools in recipes:

```make
exp: $(OBJ)
	ld -r -o exp $(OBJ)
```

For cross builds, use make variables so the caller can inject the toolchain:

```make
CC ?= cc
LD ?= ld
AR ?= ar

exp: $(OBJ)
	$(LD) -r -o exp $(OBJ)
```

Then build from Linux with:

```sh
PATH=$HOME/opt/amix-cross/bin:$PATH \
CC=m68k-cbm-sysv4-gcc \
LD=m68k-cbm-sysv4-ld \
AR=m68k-cbm-sysv4-ar \
make
```

Kernel and driver builds also need the old AMIX compiler dialect flags:

```make
CFLAGS += -traditional -fno-builtin -Dinline=__inline__
```

## Expected First Test

After `make test-random`, the output object should resemble the native AMIX
driver objects:

```text
ELF 32-bit MSB relocatable M68000 Version 1
```

Then copy `build/test/random.o` to the Amiga and try the native AMIX link, or
continue toward `test-hello` for Linux-side executable linking.

## Source URLs

The Makefile downloads from GNU's archive:

- https://ftp.gnu.org/gnu/binutils/binutils-2.8.1.tar.gz
- https://ftp.gnu.org/gnu/gcc/gcc-2.7.2.3.tar.gz
