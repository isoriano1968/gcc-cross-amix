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
Dynamically linked AMIX C executable: works on AMIX baremetal
C++ / g++: not complete yet
```

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

The included `.gitignore` files are intentionally conservative, but they are
not a substitute for checking what you publish.

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

Build and install:

```sh
cd tools/amix-cross
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

`HOST_CFLAGS` defaults to `-O2 -g -std=gnu89 -fcommon -no-pie` because the 1990s GNU
configure tests and sources expect pre-C99 implicit `int` behavior.

`BINUTILS_DISABLE_DIRS` is empty by default now. GNU `ld` must build for the
toolchain to become self-contained.

## Safety Checks

Before publishing a new GitHub repository, run:

```sh
make github-safety-check
```

The public repo should contain only the build scripts, patches, wrapper, and
documentation. The user's AMIX sysroot belongs outside the repository or under
ignored generated directories.

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

Only after a C hello binary links and runs on AMIX should `gcc-full` / C++ be
treated as meaningful.

## Kernel And Driver Objects

Example:

```sh
make AMIX_ROOT=$HOME/src/usr-amix CPUFLAGS=-m68030 test-random
```

## Expected First Test

After `make test-random`, the output object should resemble the native AMIX
driver objects:

```text
ELF 32-bit MSB relocatable M68000 Version 1
```

Then copy `build/test/random.o` to the Amiga and try the native AMIX link, or
continue toward `test-hello` for Linux-side executable linking.

## Creating A Public Repository

Recommended public repo contents:

```text
Makefile
README.md
amix-gcc-wrapper.sh
.gitignore
```

Recommended workflow:

```sh
mkdir amix-cross-public
cp tools/amix-cross/Makefile tools/amix-cross/README.md \
   tools/amix-cross/amix-gcc-wrapper.sh tools/amix-cross/.gitignore \
   amix-cross-public/
cd amix-cross-public
git init
git status --short
```

Review `git status` before the first commit. There should be no AMIX `usr`
tree, no sysroot, no copied libraries, and no startup objects.

## Source URLs

The Makefile downloads from GNU's archive:

- https://ftp.gnu.org/gnu/binutils/binutils-2.8.1.tar.gz
- https://ftp.gnu.org/gnu/gcc/gcc-2.7.2.3.tar.gz
