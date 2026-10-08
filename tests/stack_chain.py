#!/usr/bin/env python3
"""The deepest chain of stack frames below a function of a Thumb image.

    stack_chain.py <image.elf> <function-regex>...

Reads the image's code with arm-none-eabi-objdump: each function's frame
is the registers its `push` and `vpush` save plus its `sub sp` adjustment,
and its callees are the targets of its `bl` and `blx` instructions.  For
each function whose name matches one of the patterns, prints the bytes of
its deepest chain and the chain, one function and its frame a line.

A recursive call adds its frame once: the chain stops where a function
would call one already in it, and says so.  Calls through a register
(`blx r3`) have no target the code names and are not followed.  The
figure is therefore an estimate of the deepest path the code shows, not a
bound; the board's measurement beside it is the other half.
"""

import re
import subprocess
import sys


def frames(elf):
    dis = subprocess.run(["arm-none-eabi-objdump", "-d", "--no-show-raw-insn", elf],
                         capture_output=True, text=True, check=True).stdout
    frame, calls, cur = {}, {}, None

    def count(regs):
        n = 0
        for r in regs.split(","):
            r = r.strip()
            if "-" in r:
                a, b = r.split("-")
                n += int(b[1:]) - int(a[1:]) + 1
            elif r:
                n += 1
        return n

    for line in dis.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if m:
            cur = m.group(1)
            frame[cur] = 0
            calls[cur] = set()
            continue
        if cur is None:
            continue
        m = re.search(r"\b(push|stmdb)(\.w)?\s+(sp!,\s*)?\{([^}]*)\}", line)
        if m:
            frame[cur] += 4 * count(m.group(4))
        m = re.search(r"\bvpush\s+\{([^}]*)\}", line)
        if m:
            frame[cur] += 8 * count(m.group(1))
        m = re.search(r"\bsub(w|\.w)?\s+sp,\s*(sp,\s*)?#(\d+)", line)
        if m:
            frame[cur] += int(m.group(3))
        m = re.search(r"\bblx?\s+[0-9a-f]+ <([^>+]+)>", line)
        if m:
            calls[cur].add(m.group(1))
    return frame, calls


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        sys.exit(2)
    frame, calls = frames(sys.argv[1])
    memo = {}

    def depth(f, chain):
        if f in chain:
            return 0, [f"{f} (recursion, counted once)"]
        if f in memo:
            return memo[f]
        best, path = 0, []
        for g in sorted(calls.get(f, ())):
            d, p = depth(g, chain | {f})
            if d > best:
                best, path = d, p
        memo[f] = (frame.get(f, 0) + best, [f"{f} {frame.get(f, 0)}"] + path)
        return memo[f]

    found = False
    for pat in sys.argv[2:]:
        for f in sorted(frame):
            if re.fullmatch(pat, f):
                found = True
                d, p = depth(f, frozenset())
                print(f"{d} {f}")
                for x in p:
                    print("    " + x)
    sys.exit(0 if found else 1)


if __name__ == "__main__":
    main()
