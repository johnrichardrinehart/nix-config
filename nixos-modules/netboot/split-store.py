"""Pack store paths into a fixed number of bins of bounded apparent size.

Reads store paths (one per line) on stdin and writes bin N's paths to
<out-dir>/N, one per line. First-fit decreasing; exits non-zero when the
paths do not fit, naming the number of bins first-fit decreasing needs.
"""

import argparse
import os
import sys


def apparent_size(path):
    st = os.lstat(path)
    total = st.st_size
    if not os.path.isdir(path) or os.path.islink(path):
        return total
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            total += os.lstat(os.path.join(root, name)).st_size
    return total


def first_fit_decreasing(sizes, capacity, bins):
    loads = [0] * bins
    assignment = [[] for _ in range(bins)]
    for path, size in sorted(sizes.items(), key=lambda item: (-item[1], item[0])):
        for i in range(bins):
            if loads[i] + size <= capacity:
                loads[i] += size
                assignment[i].append(path)
                break
        else:
            return None, loads
    return assignment, loads


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--parts", type=int, required=True)
    parser.add_argument("--max-bytes", type=int, required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    sizes = {line.strip(): 0 for line in sys.stdin if line.strip()}
    for path in sizes:
        sizes[path] = apparent_size(path)

    too_large = {p: s for p, s in sizes.items() if s > args.max_bytes}
    if too_large:
        for path, size in too_large.items():
            print(f"{path} is {size} bytes, more than one part holds", file=sys.stderr)
        return 1

    assignment, loads = first_fit_decreasing(sizes, args.max_bytes, args.parts)
    if assignment is None:
        needed = args.parts + 1
        while first_fit_decreasing(sizes, args.max_bytes, needed)[0] is None:
            needed += 1
        print(
            f"{len(sizes)} store paths ({sum(sizes.values())} bytes) need {needed} "
            f"parts of at most {args.max_bytes} bytes; storeParts is {args.parts}",
            file=sys.stderr,
        )
        return 1

    for i, paths in enumerate(assignment):
        with open(os.path.join(args.out_dir, str(i)), "w") as out:
            out.writelines(f"{path}\n" for path in sorted(paths))
        print(f"part {i}: {len(paths)} paths, {loads[i]} bytes", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
