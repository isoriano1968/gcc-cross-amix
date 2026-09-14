#!/usr/bin/env bash
set -e

target="@TARGET@"
bindir="$(cd "$(dirname "$0")" && pwd)"
prefix="$(cd "$bindir/.." && pwd)"
real="$bindir/$target-gcc.real"
as="$bindir/$target-as"
ld="$bindir/$target-ld"
sysroot="${AMIX_SYSROOT:-$prefix/$target/sysroot}"
crt_dir="${AMIX_CRT_DIR:-$sysroot/usr/ccs/lib}"

common_cflags=(-I"$sysroot/usr/include")
default_lib_dirs=("$sysroot/usr/lib")
tmpfiles=()

cleanup()
{
	rm -f "${tmpfiles[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fix_asm()
{
	# SGS ".swbeg &N" (emitted before every switch jump table) occupies
	# 4 bytes under the native SGS assembler, and gcc's dispatch is
	# hard-coded around that: "jmp 6(%pc,%d0.w)" expects the table at
	# ext-word+6 = jmp-end+4.  GNU as parses .swbeg but emits ZERO
	# bytes, so every switch case is entered 4 bytes late, skipping its
	# first instruction(s) and branching on stale condition codes.
	# Replace .swbeg with an explicit 4-byte filler to restore the
	# layout the compiler assumed.  (Found via amix-packagemanager
	# contents-fsck: validate_rest's switch misdispatched on the box.)
	perl -pi -e 's/^(\s*)\.swbeg\s+&(\d+)[ \t]*$/$1.long $2/' "$1"

	# gcc's SGS output spells the 68020 32-bit/32-bit divide-with-
	# remainder as "tdivs.l <ea>,%dR:%dQ" / "tdivu.l ..." (remainder in
	# dR, quotient in dQ).  These SGS mnemonics are produced by
	# config/m68k/sgs.h, which renames the Motorola "divsl"/"divul" to
	# "tdivs"/"tdivu".  GNU as 2.8.1 does not know them as the 32-bit-
	# dividend form: it assembles "tdivs.l <ea>,%dR:%dQ" to the SAME
	# encoding as "divs.l <ea>,%dR:%dQ", i.e. the 64-bit-dividend
	# "DIVS.L Dr:Dq" (SIZE bit set), so dR is taken as the HIGH 32 bits
	# of the dividend instead of the remainder destination.  That word
	# holds an unrelated value, the 64-bit quotient overflows 32 bits,
	# and the 68020 then leaves the operand registers UNCHANGED -- so
	# both "%" and "/" on a variable divisor return garbage (measured:
	# 351 % 151 -> -2147408448, 351 / 151 -> 351).  Undo the SGS rename
	# back to the Motorola/GNU-as "divsl.l"/"divul.l" (32-bit dividend,
	# 32r:32q) spelling, which assembles to the correct SIZE-clear
	# encoding with the remainder in dR and the quotient in dQ.  Verify
	# with objdump: the fixed form disassembles as "divsll"/"divull",
	# the broken one as "divsl"/"divul".  (Affects every variable-divisor
	# divide/modulo the compiler emits, at both -O0 and -O.)
	perl -pi -e 's/^(\s*)tdivs(?=[.\s])/${1}divsl/; s/^(\s*)tdivu(?=[.\s])/${1}divul/;' "$1"

	# gcc emits single-precision FP multiply/divide as the 68881/68882
	# "fsglmul"/"fsgldiv" (single-precision ROUNDING, extended-precision
	# operands).  config/m68k/amix.h defines FSGLDIV_USE_S/FSGLMUL_USE_S,
	# which makes the m68k.md templates spell the register-to-register
	# form with a ".s" suffix ("fsgldiv.s %fp1,%fp0") the way the native
	# SGS assembler wants it.  GNU as 2.8.1 disagrees: in its grammar the
	# suffix names the SOURCE OPERAND FORMAT, and when the source is an
	# FPU register the data is by definition 80-bit extended, so ".x" is
	# the only legal suffix on the register-register form.  It rejects the
	# ".s" spelling outright -- "Error: operands mismatch -- statement
	# `fsgldiv.s %fp1,%fp0' ignored" -- which blocks assembly of ANY C
	# using "float" multiply or divide (measured: 15 fsgldiv + 6 fsglmul
	# rejections in one small float test file at -O).  Both spellings mean
	# the same instruction: the single-precision rounding is encoded in
	# the "sgl" of the mnemonic, not in the suffix.  Rewrite to ".x".
	#
	# ONLY the register-to-register form may be rewritten.  With a
	# non-register source the ".s" suffix is load-bearing and legal --
	# "fsgldiv.s 12(%fp),%fp0" (memory) and "fsgldiv.s %d0,%fp0" (data
	# register) both assemble, and both encode a genuinely different
	# instruction (R/M=1, source specifier "single") from the ".x"
	# register-register form (R/M=0).  gcc emits all three shapes, so the
	# match below requires BOTH operands to be %fp0-%fp7 registers and
	# leaves memory/data-register/immediate sources alone.  Verify with
	# objdump: the rewritten form disassembles as "fsgldivx"/"fsglmulx",
	# the untouched legal ones stay "fsgldivs"/"fsglmuls".  ("make
	# test-float" gates both halves.)
	#
	# Note the frame pointer prints as "%fp" with no digit, so the
	# "%fp[0-7]" match cannot mistake "12(%fp)" for an FPU register.
	perl -pi -e 's{^(\s*)fsgl(div|mul)\.s(\s+%fp[0-7]\s*,\s*%fp[0-7])(\s*)$}{$1fsgl$2.x$3$4}' "$1"

	# Bit-field operand: gcc 2.7.2.3 copies an inline "asm" template into its
	# output verbatim, so hand-written m68k assembly that spells the bit-field
	# offset and width the Motorola way -- "bfffo %d3{#0:#32},%d2", which is
	# how portable m68k C writes it (NetBSD's soft-FPU fpu_subr.c, for one) --
	# reaches the assembler unchanged.  On this target "#" is not an immediate
	# prefix at all: the SGS immediate prefix is "&", and GNU as 2.8.1 lists
	# "#" in line_comment_chars (gas/config/tc-m68k.c), so its scrubber drops
	# everything from the "#" to end of line before the m68k parser sees it --
	# the same way it silently eats a stray "moveq #1,%d0":
	#
	#   Error: Missing operand
	#   Error: operands mismatch -- statement `bfffo %d3{' ignored
	#
	# Rewrite the "#" inside the bit-field braces to "&".  That is exactly what
	# gcc's own bit-field patterns already print -- "bfextu (%a0){&0:&5},%d0"
	# assembles today -- so the repaired line is spelled the way the rest of the
	# file is.  "&" rather than a bare number: GNU as needs a prefix as soon as
	# the offset or width is a symbol.  Its operand splitter only breaks at the
	# ":" when the next character is one of a small set (the digits, "&", "#",
	# a register prefix, "(", "@"), so "{&BOFF:&WID}" assembles while the bare
	# "{BOFF:WID}" is a "Bad expression".
	#
	# Only what is between the braces is touched, so "#APP"/"#NO_APP" and any
	# other "#" on the line are left alone, and the register form "{%d0:%d1}"
	# and the already-correct "{&0:&5}" pass through unchanged.  All eight m68k
	# bit-field mnemonics are covered.  gcc's own codegen emits seven of them
	# (config/m68k/m68k.md) and already gets the prefix right, so in practice
	# this only ever fires on inline asm -- but any of the eight can arrive that
	# way, and bfffo, which gcc has no pattern for at all, arrives ONLY that
	# way.  Verify with objdump: offset and width must survive as bits 10:6 and
	# 4:0 of the extension word with the Do/Dw register-select bits clear (a
	# width of 32 encodes as 0).  ("make test-bitfield" gates this.)
	perl -pi -e '
		s{^(\s*bf(?:chg|clr|exts|extu|ffo|ins|set|tst)\s[^\n]*?\{)([^\n{}]*)(\})}{
			my ($head, $field, $tail) = ($1, $2, $3);
			$field =~ s/[#]/&/g;
			"$head$field$tail";
		}egm;
	' "$1"

	perl -pi -e 's/^(\s*\.lcomm\s+[^,]+,[^,]+),\d+\s*$/$1\n/' "$1"

	# Restore Motorola/GNU operand order for compares.  config/m68k/sgs.h
	# defines SGS_CMP_ORDER ("Takes cmp operands in reverse order"), so
	# every compare template in config/m68k/m68k.md prints its two
	# operands the other way round from what GNU as expects.
	#
	# This covers the integer "cmp.[bwl]" AND the 68881 "fcmp.[sdx]".
	# For fcmp the m68k.md patterns have three branches, and in all three
	# -- across SFmode, DFmode and XFmode -- the SGS template is the exact
	# operand-swap of the non-SGS template, with cc_status set identically
	# in both.  So swapping the two printed operands is enough; the
	# condition-code sense gcc assumed is preserved untouched:
	#
	#   both operands FPU regs   SGS "fcmp.x %0,%1"   GNU "fcmp.x %1,%0"
	#   FP reg vs memory/dreg    SGS "fcmp.s %0,%f1"  GNU "fcmp.s %f1,%0"
	#   memory/dreg vs FP reg    SGS "fcmp.s %1,%f0"  GNU "fcmp.s %f0,%1"
	#
	# The two shapes fail differently, and one of them fails SILENTLY.
	# GNU as requires an FPU register as the DESTINATION, so the forms
	# with memory on the right are rejected outright ("operands mismatch
	# -- statement `fcmp.d %fp0,16(%fp)' ignored").  But when BOTH
	# operands are FPU registers the reversed spelling is still valid
	# syntax and assembles silently to a DIFFERENT encoding: "fcmp.x
	# %fp2,%fp0" is f200 0838 (source fp2, destination fp0) whereas
	# "fcmp.x %fp0,%fp2" is f200 0138.  FCMP computes destination minus
	# source, so the unswapped form compares the operands the wrong way
	# round and the following fbgt/fsgt tests the REVERSED relation --
	# e.g. a "secs > 0.0" guard in cross-built code evaluates as
	# "0.0 > secs".  Verify with objdump: FCMP computes <second operand>
	# minus <first operand>, so the value the C source has on the LEFT of
	# the comparison must end up as the SECOND operand.  ("make test-fcmp"
	# gates both shapes.)
	#
	# The split is parenthesis-aware because memory operands contain
	# commas of their own, e.g. "fcmp.s 4(%a0,%d0.l),%fp1".
	perl -0pi -e '
		sub split_operands {
			my ($s) = @_;
			my $depth = 0;
			for (my $i = 0; $i < length($s); $i++) {
				my $ch = substr($s, $i, 1);
				$depth++ if $ch eq "(";
				$depth-- if $ch eq ")";
				if ($ch eq "," && $depth == 0) {
					return (substr($s, 0, $i), substr($s, $i + 1));
				}
			}
			return;
		}
		s{^(\s*(?:cmp\.[bwl]|fcmp\.[bwlsdxp])\s+)([^\n]+)$}{
			my ($prefix, $ops) = ($1, $2);
			my ($left, $right) = split_operands($ops);
			defined $right ? "$prefix$right,$left" : "$prefix$ops";
		}egm;
		# Rounding-precision opcodes with an FPn source: gcc 2.7.2.3 emits
		# the size suffix of the original C type (.s/.d), but a register
		# source is always extended precision and gas rejects anything but
		# .x.  The value is unaffected -- these opcodes round the RESULT to
		# the precision named in the mnemonic, whatever the source is called.
		# FSGLMUL/FSGLDIV are handled by the rule above; this is the
		# FSxxx/FDxxx family, which gcc emits at -m68040.
		s{^(\s*f[sd](?:add|sub|mul|div|mov|abs|neg|sqrt))\.[bwlsdp](\s+%fp[0-7],%fp[0-7]\s*)$}{$1.x$2}gm;
		# ...and this gas knows FSMOV by the short name but not FDMOV, which
		# it only accepts spelled FDMOVE.  An asymmetry in its opcode table,
		# not a difference between the instructions.  Must run after the rule
		# above, which matches on the short spelling.
		s{^(\s*)fdmov(\.)}{$1fdmove$2}gm;
		# Two more spellings gas will not take, both from the float-to-int
		# sequence gcc emits at -m68040: it saves FPCR, sets round-to-zero,
		# converts and restores.  Suffixless `fmovm` (the register-list form
		# in prologues) is fine; only the sized control-register form is not.
		s{^(\s*)fmovm(\.[a-z])}{$1fmovem$2}gm;
		s{^(\s*mov)(\s+&\d+,%d[0-7]\s*)$}{$1.l$2}gm;
	' "$1"
}

compile_one()
{
	local src="$1"
	local obj="$2"
	shift 2
	local asmfile

	asmfile="$(mktemp "${TMPDIR:-/tmp}/amix-gcc.XXXXXX.s")"
	tmpfiles+=("$asmfile")

	# Assemble for whatever architecture the compile asked for.  This used to
	# be hardcoded to -m68020, which silently capped the toolchain at 68020
	# code generation: -m68040 compiles fine and then fails to assemble on
	# 040-only opcodes.  That matters for more than exotica.  gcc at -m68020
	# emits FSGLMUL/FSGLDIV for single-precision multiply and divide, and
	# neither is implemented in the 68060's FPU -- every one of them traps into
	# the FPSP and is emulated.  At -m68040 gcc emits FSMUL/FSDIV instead,
	# which both the 040 and the 060 execute in hardware.
	local asarch=-m68020
	for a in "$@"; do
		case "$a" in
			-m68030|-m68040|-m68060) asarch="$a" ;;
		esac
	done

	"$real" -S "${common_cflags[@]}" "$@" "$src" -o "$asmfile"
	fix_asm "$asmfile"
	"$as" "$asarch" -o "$obj" "$asmfile"
}

# fix (linking): emit the ld argument for one "-lNAME", preferring the "-lNAME"
# form over an absolute path.  ld records a shared library in DT_NEEDED under
# the name it was GIVEN, unless the library carries a DT_SONAME of its own.  On
# this target only libc.so.1 and ld.so.1 have a SONAME: libsocket.so, libnsl.so
# and every stock libX*.so have none.  So resolving "-lsocket" to a file in the
# build HOST's sysroot and passing that path positionally, as this function used
# to, baked the host path into the executable --
#
#   NEEDED  [/home/<user>/opt/amix-cross/m68k-cbm-sysv4/sysroot/usr/lib/libsocket.so]
#
# a path that exists on no AMIX box.  Nothing complained: the link succeeded and
# the binary looked correct; it died at exec time on the guest, where the
# runtime linker has only the recorded string to go on.  Passing "-L<dir>"
# followed by "-lNAME" makes ld search for the file itself, and for a library
# found that way it records just the file name ("libsocket.so"), which is what
# the guest's /usr/lib holds.  (binutils 2.8.1 predates "-l:libNAME.so", so the
# search form is the only way to get a bare name recorded.)
#
# Two libraries still have to be named by path, and both are safe:
#
#   libc      the sysroot ships "libc.so.1", not "libc.so", so ld's -l search
#             cannot find it at all.  It is also the one library with a
#             DT_SONAME, so the recorded name is "/usr/lib/libc.so.1" from the
#             SONAME rather than the host path.  (Routing libc through -lc
#             instead would find the static stub archive in /usr/ccs/lib and the
#             executable would silently lose its libc dependency.)
#   libNAME.so.1
#             a versioned DSO with no unversioned name, same search problem.
#             Nothing but libc is shaped like this in the stock sysroot; if one
#             appears, the previous behaviour is kept.
#
# The lookup order below is unchanged, and matches ld's own: the -L directories
# in command-line order, then the sysroot default, and within each directory the
# shared library before the archive.  So "-lNAME" resolves to exactly the file
# this function inspected, provided the same -L list reaches ld -- which is what
# ld_lib_dirs below is for.  ("make test-dtneeded" gates this.)
resolve_lib()
{
	local name="$1"
	local dir candidate

	test "$name" = c && {
		printf '%s\n' "$sysroot/usr/lib/libc.so.1"
		return 0
	}

	for dir in "${lib_dirs[@]}" "${default_lib_dirs[@]}"; do
		test -f "$dir/lib$name.so" && {
			printf '%s\n' "-l$name"
			return 0
		}
		test -f "$dir/lib$name.so.1" && {
			printf '%s\n' "$dir/lib$name.so.1"
			return 0
		}
		test -f "$dir/lib$name.a" && {
			printf '%s\n' "-l$name"
			return 0
		}
	done

	printf 'amix gcc wrapper: cannot resolve -l%s\n' "$name" >&2
	return 1
}

has_c=no
has_S=no
has_E=no
for arg in "$@"; do
	case "$arg" in
		-c) has_c=yes ;;
		-S) has_S=yes ;;
		-E) has_E=yes ;;
	esac
done

# fix (preprocessing): -E needs only the real preprocessor and the target
# include path.  fix_asm exists to repair generated ASSEMBLY, and -E produces
# none, so it is safe to hand the whole command line straight to the real cross
# compiler with the same include path a compile uses (common_cflags).  Without
# this, -E is unrecognised here and falls through to the parse loop's catch-all
# below, which files any unknown dash-argument as an *ld* flag: "gcc -E foo.c"
# then COMPILES AND LINKS foo.c instead of preprocessing it, emitting nothing on
# stdout.  autoconf's "checking how to run the C preprocessor" step rejects that
# and silently falls back to the build HOST's /lib/cpp, after which every
# AC_CHECK_HEADER reads the host's /usr/include and HAVE_* is decided against
# the wrong headers.  (Same dispatch as -S immediately below.)
if test "$has_E" = yes; then
	exec "$real" "${common_cflags[@]}" "$@"
fi

if test "$has_S" = yes; then
	exec "$real" "${common_cflags[@]}" "$@"
fi

compile_flags=()
sources=()
objects=()
archives=()
ld_flags=()
lib_dirs=()
libs=()
out=a.out
compile_out=
skip=

while test $# -gt 0; do
	arg="$1"
	shift

	if test "$skip" = o; then
		out="$arg"
		compile_out="$arg"
		skip=
		continue
	fi

	case "$arg" in
		-o)
			skip=o
			;;
		-I|-D|-U|-L)
			test $# -gt 0 || { echo "amix gcc wrapper: $arg needs an argument" >&2; exit 1; }
			next="$1"
			shift
			case "$arg" in
				-L) lib_dirs+=("$next") ;;
				*) compile_flags+=("$arg" "$next") ;;
			esac
			;;
		-I*|-D*|-U*|-O*|-m*|-f*|-W*|-g|-traditional)
			compile_flags+=("$arg")
			;;
		-L*)
			lib_dirs+=("${arg#-L}")
			;;
		-l*)
			libs+=("${arg#-l}")
			;;
		*.c)
			sources+=("$arg")
			;;
		*.o)
			objects+=("$arg")
			;;
		# fix (linking): a static archive or shared library named directly on the
		# command line must be linked AFTER the objects that reference it.  The .c
		# sources are compiled and their objects APPENDED to objects[] further
		# down, so a .a/.so left in objects[] here would sort before them:
		# "gcc prog.c libfoo.a" would link as "libfoo.a prog.o", and single-pass
		# ld, meeting the archive while nothing is yet undefined, would pull in no
		# members and every symbol in it would come back undefined.  Collect these
		# separately and place them past the objects on the link line.  Plain .o
		# relocatables stay in objects[] (they carry symbols, not just satisfy
		# references, so their position among the objects does not matter).
		*.a|*.so|*.so.[0-9]*)
			archives+=("$arg")
			;;
		*)
			if [[ "$arg" == -* ]]; then
				ld_flags+=("$arg")
			else
				objects+=("$arg")
			fi
			;;
	esac
done

for input in "${sources[@]}" "${objects[@]}" "${archives[@]}"; do
	if test -n "$input" && test "$out" = "$input"; then
		echo "amix gcc wrapper: refusing to overwrite input file '$input'" >&2
		exit 1
	fi
done

if test "$has_c" = yes; then
	if test "${#sources[@]}" -eq 0; then
		# -c with no *.c source.  Everything the parse loop filed as an
		# "object" -- .s, .S, .i, or any other input the wrapper does not
		# compile itself -- is handed to the real driver, which knows how
		# to assemble or compile each of them.
		#
		# fix (compiling): pass -o only when one was actually given.  This
		# used to pass "-o $compile_out" unconditionally, so a plain
		# "cc -c foo.s" reached the real compiler as "-c -o '' foo.s".
		# gcc 2.7.2.3 splices its spec strings argument by argument and an
		# EMPTY argument disappears from the command line it builds, so
		# the assembler was run as
		#
		#     as -V -Qy -o ../src/probe.s
		#
		# -- the source had become the -o ARGUMENT and as read its input
		# from stdin.  The consequences are worse than a missing object:
		# with stdin at EOF (any non-interactive build) as wrote an empty
		# module OVER THE ASSEMBLY SOURCE and exited 0, so the .s file was
		# replaced by an ELF object, nothing appeared in the working
		# directory, and nothing was printed; on a terminal the compile
		# simply hung waiting for input that never came.  The ordinary
		# SVR4-era way to build assembly,
		#
		#     .s.o:
		#             $(CC) $(CFLAGS) -c $<
		#
		# hits this on every .s file it touches.  (For a .S input the file
		# the assembler clobbers is gcc's own preprocessed temporary, not
		# the source, so that case merely loses the object.)
		#
		# With -o left off, the real driver applies its own -c rule, which
		# is the same rule the *.c path below implements by hand: one
		# object per input, in the CURRENT WORKING DIRECTORY, named after
		# the input's basename -- "cc -c ../src/foo.s" writes "./foo.o"
		# and leaves ../src alone.  That covers .s, .S and .i alike, and
		# multiple inputs in one command, without this branch having to
		# reimplement the naming.  An explicit -o is still passed through
		# verbatim.  ("make test-objdir" gates .c, .s and .S.)
		compile_out_args=()
		if test -n "$compile_out"; then
			for input in "${objects[@]}"; do
				if test -n "$input" && test "$compile_out" = "$input"; then
					echo "amix gcc wrapper: refusing to overwrite input file '$input'" >&2
					exit 1
				fi
			done
			compile_out_args=(-o "$compile_out")
		fi
		exec "$real" "${common_cflags[@]}" -c "${compile_flags[@]}" "${compile_out_args[@]}" "${objects[@]}"
	fi
	if test "${#sources[@]}" -gt 1 && test -n "$compile_out"; then
		echo "amix gcc wrapper: -o with -c and multiple sources is not supported" >&2
		exit 1
	fi
	# fix (compiling): with -c and no -o, the object belongs in the CURRENT
	# WORKING DIRECTORY under the source's basename -- "cc -c ../src/foo.c"
	# writes "./foo.o".  This used to strip only the suffix and keep the
	# directory part, so the object was written NEXT TO THE SOURCE, in
	# ../src/foo.o.  Every build with a separate object directory then failed
	# at the link: the compile reported success, the object was nowhere make
	# expected it, and ld stopped with "cannot open foo.o: No such file or
	# directory".  That is the normal shape of a VPATH/srcdir build -- gcc's
	# own build (which compiles ../gcc-src/*.c into the build directory),
	# imake/X11, and any autoconf package configured from a separate build
	# tree -- so it was not an exotic case.  Worse, the stray objects landed
	# in the source tree, where a second build could pick them up.
	#
	# With an explicit -o nothing changes: $compile_out is used verbatim,
	# including a path into another directory.  ("make test-objdir" gates
	# both halves.)
	for src in "${sources[@]}"; do
		obj="$compile_out"
		test -n "$obj" || {
			obj="$(basename "$src")"
			obj="${obj%.*}.o"
		}
		compile_one "$src" "$obj" "${compile_flags[@]}"
	done
	exit 0
fi

for src in "${sources[@]}"; do
	obj="$(mktemp "${TMPDIR:-/tmp}/amix-gcc.XXXXXX.o")"
	tmpfiles+=("$obj")
	compile_one "$src" "$obj" "${compile_flags[@]}"
	objects+=("$obj")
done

# Locate the installed target libgcc.a (the freestanding soft-arithmetic
# helpers: 64-bit __udivdi3/__umoddi3/__lshrdi3/... and the DImode<->float
# conversions).  A stock gcc driver pulls this in via -lgcc from its specs, but
# this wrapper hand-rolls the ld command line, so add libgcc.a explicitly.  The
# newest installed version directory wins; if none is present the link proceeds
# without it, preserving the previous behaviour.
libgcc_a=
for cand in "$prefix"/lib/gcc-lib/"$target"/*/libgcc.a; do
	test -f "$cand" && libgcc_a="$cand"
done

# fix (linking): hand ld the library search path.  The -L directories used to be
# consumed by the wrapper alone, for resolve_lib's own lookup, and never reached
# ld -- which was invisible while every -l was turned into an absolute path.  Now
# that resolve_lib emits "-lNAME", ld has to be able to find the same files, in
# the same order: the user's -L directories first, then the sysroot default.
# These also give ld the search path it needs for a shared library's own
# dependencies.
ld_lib_dirs=()
for dir in "${lib_dirs[@]}" "${default_lib_dirs[@]}"; do
	ld_lib_dirs+=(-L"$dir")
done

resolved_libs=()
for lib in "${libs[@]}"; do
	# -lgcc is satisfied by the libgcc.a appended to the link below.
	test "$lib" = gcc && continue
	resolved_libs+=("$(resolve_lib "$lib")")
done
# fix (linking): always link libc, at the END of the library list.  A stock gcc
# driver pulls libc in from its specs regardless of the user's -l flags; this
# wrapper hand-rolls ld, and it used to add libc ONLY when no -l was given at
# all.  So a lone "-lfoo" dropped libc from the link entirely, and the first
# symbols left undefined were crt1.o's own atexit/exit/_environ/__fpstart --
# which reads as a broken toolchain rather than a missing -lc.  Appending it
# after the user's libraries (so their libc references still resolve) means an
# explicit trailing -lc is no longer required; a redundant one is harmless.
resolved_libs+=("$(resolve_lib c)")

for crt in crt1.o crti.o crtn.o; do
	test -f "$crt_dir/$crt" || {
		echo "amix gcc wrapper: missing $crt_dir/$crt; set AMIX_CRT_DIR" >&2
		exit 1
	}
done

# libgcc.a goes LAST (after the user's libraries, before crtn): it is a leaf
# dependency, so any preceding static archive whose members reference the 64-bit
# helpers must come before it for single-pass ld to resolve them.  This mirrors
# a stock gcc driver, which appends -lgcc at the end of the link.
exec "$ld" -o "$out" \
	"$crt_dir/crt1.o" "$crt_dir/crti.o" \
	"${objects[@]}" "${archives[@]}" "${ld_flags[@]}" \
	"${ld_lib_dirs[@]}" "${resolved_libs[@]}" \
	${libgcc_a:+"$libgcc_a"} \
	"$crt_dir/crtn.o"
