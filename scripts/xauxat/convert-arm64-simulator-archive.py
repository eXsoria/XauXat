#!/usr/bin/env python3

"""Retarget arm64 Mach-O members in a static archive to iOS Simulator."""

from __future__ import annotations

import argparse
import concurrent.futures
import pathlib
import struct
import subprocess
import tempfile


AR_MAGIC = b"!<arch>\n"
MACHO64_LE_MAGIC = b"\xcf\xfa\xed\xfe"
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
PLATFORM_IOSSIMULATOR = 7


def parse_version(value: int) -> str:
    return f"{value >> 16}.{(value >> 8) & 0xff}.{value & 0xff}"


def macho_platform(member: bytes) -> tuple[str, str] | None:
    if not member.startswith(MACHO64_LE_MAGIC) or len(member) < 32:
        return None

    command_count = struct.unpack_from("<I", member, 16)[0]
    offset = 32
    for _ in range(command_count):
        if offset + 8 > len(member):
            raise ValueError("truncated Mach-O load commands")
        command, command_size = struct.unpack_from("<II", member, offset)
        if command_size < 8 or offset + command_size > len(member):
            raise ValueError("invalid Mach-O load command")
        if command in (LC_VERSION_MIN_MACOSX, LC_VERSION_MIN_IPHONEOS):
            minimum = struct.unpack_from("<I", member, offset + 8)[0]
            return "legacy", parse_version(minimum)
        if command == LC_BUILD_VERSION:
            platform, minimum = struct.unpack_from("<II", member, offset + 8)
            if platform == PLATFORM_IOSSIMULATOR:
                return "simulator", parse_version(minimum)
            if platform == PLATFORM_IOS:
                return "device", parse_version(minimum)
        offset += command_size
    return None


def archive_members(contents: bytes) -> list[tuple[int, int, int]]:
    if not contents.startswith(AR_MAGIC):
        raise ValueError("not a static archive")

    members: list[tuple[int, int, int]] = []
    offset = len(AR_MAGIC)
    while offset < len(contents):
        if offset + 60 > len(contents):
            raise ValueError("truncated archive header")
        header = contents[offset : offset + 60]
        if header[58:60] != b"`\n":
            raise ValueError("invalid archive member header")
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError as exc:
            raise ValueError("invalid archive member size") from exc

        payload_offset = offset + 60
        payload_end = payload_offset + size
        if payload_end > len(contents):
            raise ValueError("truncated archive member")

        name_field = header[:16].decode("ascii", errors="replace").strip()
        object_offset = payload_offset
        if name_field.startswith("#1/"):
            name_size = int(name_field[3:])
            object_offset += name_size
        members.append((object_offset, payload_end, len(members)))
        offset = payload_end + (size & 1)
    return members


def retarget_member(
    task: tuple[bytes, int, str, str, pathlib.Path, str],
) -> tuple[int, bytes]:
    member, index, minimum, sdk, work_dir, vtool = task
    source = work_dir / f"{index}.o"
    output = work_dir / f"{index}.sim.o"
    source.write_bytes(member)
    subprocess.run(
        [
            vtool,
            "-set-build-version",
            "iossim",
            minimum,
            sdk,
            "-replace",
            "-output",
            str(output),
            str(source),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    converted = output.read_bytes()
    if len(converted) != len(member):
        raise ValueError(
            f"vtool changed member {index} size from {len(member)} to {len(converted)}"
        )
    return index, converted


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")

    vtool = subprocess.run(
        ["xcrun", "--find", "vtool"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    contents = bytearray(args.archive.read_bytes())
    members = archive_members(contents)
    candidates: list[tuple[bytes, int, str, str, pathlib.Path, str]] = []
    member_ranges: dict[int, tuple[int, int]] = {}

    with tempfile.TemporaryDirectory(prefix="xauxat-iossim-") as directory:
        work_dir = pathlib.Path(directory)
        for start, end, index in members:
            member = bytes(contents[start:end])
            platform = macho_platform(member)
            if platform is None or platform[0] == "simulator":
                continue
            member_ranges[index] = (start, end)
            candidates.append((member, index, platform[1], args.sdk, work_dir, vtool))

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
            for result in executor.map(retarget_member, candidates):
                index, converted = result
                start, end = member_ranges[index]
                contents[start:end] = converted

    for start, end, _ in members:
        platform = macho_platform(bytes(contents[start:end]))
        if platform is not None and platform[0] != "simulator":
            raise ValueError(f"Mach-O member still targets {platform[0]}")

    args.archive.write_bytes(contents)
    print(f"Retargeted {len(candidates)} Mach-O members in {args.archive.name}.")


if __name__ == "__main__":
    main()
