#!/usr/bin/env python3
"""Prepare disposable MS-DOS 6.22 boot/data floppies for the FT2 capture.

The source DOS images are never modified.  A bootable copy of Disk1 is made
with a tiny AUTOEXEC.BAT, while FT2 and the native XM are placed on a separate
2.88 MB FAT12 disk so the tracker still runs entirely inside real MS-DOS.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from pyfatfs.PyFat import PyFat
from pyfatfs.PyFatFS import PyFatFS


BOOT_AUTOEXEC = (
    b"@ECHO OFF\r\n"
    b"PROMPT $P$G\r\n"
    b"SET BLASTER=A220 I7 D1 H5 T6\r\n"
    b"SET ULTRASND=240,3,3,5,5\r\n"
    b"CLS\r\n"
    b"ECHO CRTkafa @ cracktro 01\r\n"
    b"ECHO.\r\n"
    b"CHOICE /C:Y /N /T:Y,2 > NUL\r\n"
    b"LH A:\\CTMOUSE.EXE\r\n"
    b"B:\r\n"
    b"FT2.EXE A:\\CRT01.XM\r\n"
)

SINGLE_AUTOEXEC = (
    b"@ECHO OFF\r\n"
    b"PROMPT $P$G\r\n"
    b"SET BLASTER=A220 I7 D1 H5 T6\r\n"
    b"CLS\r\n"
    b"ECHO CRTkafa @ cracktro 01\r\n"
    b"ECHO.\r\n"
    b"CHOICE /C:Y /N /T:Y,2 > NUL\r\n"
    b"LH A:\\CTMOUSE.EXE\r\n"
    b"A:\r\n"
    b"FT2.EXE A:\\CRT01.XM\r\n"
)

BOOT_CONFIG = (
    b"DEVICE=A:\\HIMEM.SYS /TESTMEM:OFF\r\n"
    b"DEVICE=A:\\EMM386.EXE RAM 4096\r\n"
    b"DOS=HIGH,UMB\r\n"
    b"FILES=30\r\n"
    b"BUFFERS=20\r\n"
)


def write_file(fs: PyFatFS, dos_path: str, source: Path) -> None:
    with source.open("rb") as src, fs.openbin(dos_path, "w") as dst:
        shutil.copyfileobj(src, dst, length=1024 * 1024)


def write_ft2_config(fs: PyFatFS, source: Path) -> None:
    """Select SB16 in an original encrypted FT2.CFG without touching source."""
    encrypted = bytearray(source.read_bytes())
    if len(encrypted) != 1736:
        raise ValueError(f"Unexpected FT2.CFG size: {len(encrypted)}")
    plain = bytearray(value ^ ((index * 7) & 0xFF) for index, value in enumerate(encrypted))
    if plain[:35] != b"FastTracker 2.0 configuration file\x1a":
        raise ValueError("FT2.CFG signature mismatch")

    # Original packed FT2 config layout: output device 2 is Sound Blaster
    # (1 is the parallel-port Soundplayer).  Port 0x220, low DMA 1,
    # high DMA 5 and IRQ 7 match the emulated SB16.
    plain[41:43] = (2).to_bytes(2, "little", signed=True)  # utEnhet
    plain[49] = 1                                         # interpolation
    plain[51] = 1                                         # stereo
    plain[56:58] = (0x220).to_bytes(2, "little", signed=True)
    plain[58:60] = (1).to_bytes(2, "little", signed=True)
    plain[60:62] = (5).to_bytes(2, "little", signed=True)
    plain[62:64] = (7).to_bytes(2, "little", signed=True)
    plain[66] = 1                                         # 16-bit mixing

    patched = bytes(value ^ ((index * 7) & 0xFF) for index, value in enumerate(plain))
    fs.writebytes("/FT2.CFG", patched)


def make_combined_boot_disk(
    output: Path,
    disk1: Path,
    disk2: Path,
    ft2: Path,
    ft2_config: Path,
    xm: Path,
    himem: Path,
    emm386: Path,
    ctmouse: Path,
) -> None:
    """Build one bootable 2.88 MB MS-DOS/FT2 disk for a physical-PC VM."""
    if output.exists():
        output.unlink()
    output.touch()
    fat = PyFat()
    fat.mkfs(
        str(output),
        fat_type=PyFat.FAT_TYPE_FAT12,
        size=2_949_120,
        sector_size=512,
        number_of_fats=2,
        label="CRTKAFATRK",
        volume_id=0x43525431,
        media_type=0xF0,
    )
    fat.close()

    # Keep the generated 2.88 MB BPB, but transplant Microsoft's boot jump,
    # OEM tag and bootstrap from the original MS-DOS 6.22 Disk 1 sector.
    source_boot = disk1.read_bytes()[:512]
    with output.open("r+b") as raw:
        target_boot = bytearray(raw.read(512))
        target_boot[:11] = source_boot[:11]
        target_boot[0x3E:512] = source_boot[0x3E:512]
        target_boot[0x18:0x1A] = (36).to_bytes(2, "little")
        target_boot[0x1A:0x1C] = (2).to_bytes(2, "little")
        raw.seek(0)
        raw.write(target_boot)

    with (
        PyFatFS(str(disk1), read_only=True) as dos_fs,
        PyFatFS(str(disk2), read_only=True) as tools_fs,
        PyFatFS(str(output), read_only=False) as out_fs,
    ):
        # MS-DOS expects these two files first in the root directory.
        out_fs.writebytes("/IO.SYS", dos_fs.readbytes("/IO.SYS"))
        out_fs.writebytes("/MSDOS.SYS", dos_fs.readbytes("/MSDOS.SYS"))
        out_fs.writebytes("/COMMAND.COM", dos_fs.readbytes("/COMMAND.COM"))
        out_fs.writebytes("/CHOICE.COM", tools_fs.readbytes("/CHOICE.COM"))
        out_fs.writebytes("/AUTOEXEC.BAT", SINGLE_AUTOEXEC)
        out_fs.writebytes("/CONFIG.SYS", BOOT_CONFIG)
        write_file(out_fs, "/HIMEM.SYS", himem)
        write_file(out_fs, "/EMM386.EXE", emm386)
        write_file(out_fs, "/CTMOUSE.EXE", ctmouse)
        write_file(out_fs, "/FT2.EXE", ft2)
        write_ft2_config(out_fs, ft2_config)
        write_file(out_fs, "/CRT01.XM", xm)

    # DOS 6.x's floppy bootstrap does not scan an arbitrary FAT12 root: it
    # expects IO.SYS and MSDOS.SYS in the first two physical directory slots.
    # pyfatfs puts the volume label first, so move that entry behind the files.
    with output.open("r+b") as raw:
        boot = raw.read(512)
        reserved = int.from_bytes(boot[0x0E:0x10], "little")
        fats = boot[0x10]
        sectors_per_fat = int.from_bytes(boot[0x16:0x18], "little")
        root_entries = int.from_bytes(boot[0x11:0x13], "little")
        root_offset = (reserved + fats * sectors_per_fat) * 512
        raw.seek(root_offset)
        root = bytearray(raw.read(root_entries * 32))
        used = 0
        while used < root_entries and root[used * 32] not in (0x00, 0xE5):
            used += 1
        label = bytes(root[:32])
        root[: used * 32] = root[32 : (used + 1) * 32]
        root[(used - 1) * 32 : used * 32] = label
        root[11] = 0x21       # IO.SYS: read-only + archive, as on Disk 1
        root[32 + 11] = 0x21  # MSDOS.SYS
        raw.seek(root_offset)
        raw.write(root)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dos-root", type=Path, required=True)
    parser.add_argument("--ft2", type=Path, required=True)
    parser.add_argument("--ft2-config", type=Path)
    parser.add_argument("--xm", type=Path, required=True)
    parser.add_argument("--himem", type=Path, required=True)
    parser.add_argument("--emm386", type=Path, required=True)
    parser.add_argument("--ctmouse", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    disk1 = args.dos_root / "Disk1.img"
    disk2 = args.dos_root / "Disk2.img"
    ft2_config = args.ft2_config or (args.ft2.parent / "FT2.CFG")
    for path in (disk1, disk2, args.ft2, ft2_config, args.xm, args.himem, args.emm386, args.ctmouse):
        if not path.is_file():
            raise FileNotFoundError(path)

    args.output.mkdir(parents=True, exist_ok=True)
    boot_img = args.output / "BOOT622.IMG"
    data_img = args.output / "FT2DATA.IMG"
    combined_img = args.output / "CRTK486.IMG"

    shutil.copyfile(disk1, boot_img)
    with PyFatFS(str(boot_img), read_only=False) as boot_fs:
        keep = {
            "IO.SYS", "MSDOS.SYS", "COMMAND.COM",
            "AUTOEXEC.BAT", "CONFIG.SYS",
        }
        for name in boot_fs.listdir("/"):
            if name.upper() not in keep:
                boot_fs.remove("/" + name)
        boot_fs.writebytes("/AUTOEXEC.BAT", BOOT_AUTOEXEC)
        boot_fs.writebytes("/CONFIG.SYS", BOOT_CONFIG)
        write_file(boot_fs, "/HIMEM.SYS", args.himem)
        write_file(boot_fs, "/EMM386.EXE", args.emm386)
        write_file(boot_fs, "/CTMOUSE.EXE", args.ctmouse)
        with PyFatFS(str(disk2), read_only=True) as disk2_fs:
            boot_fs.writebytes("/CHOICE.COM", disk2_fs.readbytes("/CHOICE.COM"))

    if data_img.exists():
        data_img.unlink()
    data_img.touch()
    fat = PyFat()
    fat.mkfs(
        str(data_img),
        fat_type=PyFat.FAT_TYPE_FAT12,
        size=2_949_120,
        sector_size=512,
        number_of_fats=2,
        label="CRTKAFATRK",
        volume_id=0x43525431,
        media_type=0xF0,
    )
    fat.close()

    # pyfatfs 1.1 leaves the FAT12 BPB geometry fields at zero.  MS-DOS can
    # still enumerate the disk, but period software (including FT2) divides by
    # sectors-per-track while calculating free space.  A 2.88 MB ED floppy is
    # 80 cylinders, 2 heads, 36 sectors per track.
    with data_img.open("r+b") as raw:
        raw.seek(0x18)
        raw.write((36).to_bytes(2, "little"))
        raw.write((2).to_bytes(2, "little"))

    with PyFatFS(str(data_img), read_only=False) as data_fs:
        write_file(data_fs, "/FT2.EXE", args.ft2)
        write_ft2_config(data_fs, ft2_config)
        write_file(data_fs, "/CRT01.XM", args.xm)

    make_combined_boot_disk(
        combined_img, disk1, disk2, args.ft2, ft2_config, args.xm,
        args.himem, args.emm386, args.ctmouse,
    )

    with PyFatFS(str(boot_img), read_only=True) as boot_fs:
        assert boot_fs.readbytes("/AUTOEXEC.BAT") == BOOT_AUTOEXEC
        assert boot_fs.readbytes("/CONFIG.SYS") == BOOT_CONFIG
        assert boot_fs.getsize("/HIMEM.SYS") == args.himem.stat().st_size
        assert boot_fs.getsize("/EMM386.EXE") == args.emm386.stat().st_size
        assert boot_fs.getsize("/CTMOUSE.EXE") == args.ctmouse.stat().st_size
    with PyFatFS(str(data_img), read_only=True) as data_fs:
        assert data_fs.getsize("/FT2.EXE") == args.ft2.stat().st_size
        assert data_fs.getsize("/FT2.CFG") == 1736
        assert data_fs.getsize("/CRT01.XM") == args.xm.stat().st_size
    with PyFatFS(str(combined_img), read_only=True) as combined_fs:
        assert combined_fs.readbytes("/AUTOEXEC.BAT") == SINGLE_AUTOEXEC
        assert combined_fs.getsize("/FT2.EXE") == args.ft2.stat().st_size
        assert combined_fs.getsize("/CRT01.XM") == args.xm.stat().st_size

    print(boot_img)
    print(data_img)
    print(combined_img)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
