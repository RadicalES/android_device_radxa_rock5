/*
 * Copyright (C) 2026 RadicalES
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * rock5_installer: /init of the installer ramdisk. Copies the system on the
 * card it booted from (an ordinary image from tools/mkimg.sh) to the board's
 * internal storage, then reboots into it once the card is removed.
 *
 *   sectors 64 .. first partition   U-Boot (boot ROM offset)
 *   boot, system, vendor            copied, then read back and compared
 *   metadata, userdata              zeroed at the start: Android formats them
 *                                   on first boot (fstab "formattable")
 *   GPT                             the card's partitions, new GUIDs, userdata
 *                                   grown to the end of the target
 *   boot/extlinux/extlinux.conf     replaced by extlinux.conf.target, which
 *                                   mkimg.sh wrote for the target's controller
 *
 * Kernel command line (all optional):
 *   rock5_installer.source=<s>   source disk: its sysfs path contains <s>
 *                                (default fe2c0000.mmc, the microSD slot)
 *   rock5_installer.target=<s>   target disk (default fe2e0000.mmc, the eMMC)
 *   rock5_installer.countdown=N  seconds before writing (default 10)
 *   rock5_installer.dry_run=1    read and check everything, write nothing
 *
 * Messages go to the HDMI console (tty0) and the UART (/dev/console).
 *
 * Test mode, as root on a running system (not as /init):
 *   rock5_installer --test <disk> [--dry-run]
 *       install onto <disk> (e.g. sda, a USB stick, or a loop device with
 *       partition scanning) with no countdown and no reboot, output on stdout
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/random.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <string>
#include <vector>

namespace {

constexpr uint64_t kSector = 512;
constexpr size_t kChunk = 4 << 20;  // bytes per read/write
constexpr uint64_t kZeroBytes = 16 << 20;  // zeroed at the start of metadata/userdata
constexpr uint64_t kUbootFirst = 64;  // boot ROM reads U-Boot from sector 64

int g_tty = -1;
int g_uart = -1;
bool g_test = false;  // --test: return instead of waiting for power off

void out(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void out(const char* fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > static_cast<int>(sizeof(buf)) - 1) n = sizeof(buf) - 1;
    std::string s;
    for (int i = 0; i < n; i++) {  // the tty wants \r\n
        if (buf[i] == '\n') s += '\r';
        s += buf[i];
    }
    if (g_tty >= 0) (void)!write(g_tty, s.data(), s.size());
    if (g_uart >= 0) (void)!write(g_uart, s.data(), s.size());
}

[[noreturn]] void halt(int status = 0) {
    sync();
    if (g_test) exit(status);
    for (;;) pause();
}

[[noreturn]] void fail(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
[[noreturn]] void fail(const char* fmt, ...) {
    char buf[400];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    out("\n*** INSTALL FAILED: %s\n", buf);
    out("*** The internal storage may be incomplete. Fix the cause and run the\n"
        "*** installer again; switch off to stop.\n");
    halt(1);
}

std::string read_file(const std::string& path) {
    std::string s;
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return s;
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) s.append(buf, n);
    close(fd);
    while (!s.empty() && (s.back() == '\n' || s.back() == ' ')) s.pop_back();
    return s;
}

std::string cmdline_value(const std::string& cmdline, const std::string& key,
                          const std::string& def) {
    std::string k = key + "=";
    size_t pos = 0;
    while ((pos = cmdline.find(k, pos)) != std::string::npos) {
        if (pos == 0 || cmdline[pos - 1] == ' ') {
            size_t start = pos + k.size();
            size_t end = cmdline.find(' ', start);
            return cmdline.substr(start, end == std::string::npos ? end : end - start);
        }
        pos += k.size();
    }
    return def;
}

// Creates /dev/<name> from the "major:minor" in <sysfs dir>/dev.
bool make_node(const std::string& sysdir, const std::string& name, mode_t type) {
    std::string dev = read_file(sysdir + "/dev");
    unsigned maj, min;
    if (sscanf(dev.c_str(), "%u:%u", &maj, &min) != 2) return false;
    std::string path = "/dev/" + name;
    unlink(path.c_str());
    return mknod(path.c_str(), type | 0600, makedev(maj, min)) == 0;
}

struct Disk {
    std::string name;     // e.g. mmcblk1
    std::string syspath;  // resolved /sys/block/<name>
    uint64_t sectors = 0;
};

// The whole disk whose sysfs path contains `match` (partitions are not
// listed in /sys/block).
bool find_disk(const std::string& match, Disk* disk) {
    DIR* d = opendir("/sys/block");
    if (!d) return false;
    bool found = false;
    while (dirent* e = readdir(d)) {
        if (e->d_name[0] == '.') continue;
        std::string name = e->d_name;
        if (name.rfind("loop", 0) == 0 || name.rfind("ram", 0) == 0 ||
            name.find("boot") != std::string::npos || name.find("rpmb") != std::string::npos)
            continue;  // mmcblkXboot0/1 and rpmb are eMMC hardware partitions
        char real[PATH_MAX];
        if (!realpath(("/sys/block/" + name).c_str(), real)) continue;
        if (strstr(real, match.c_str()) == nullptr) continue;
        disk->name = name;
        disk->syspath = real;
        disk->sectors = strtoull(read_file(disk->syspath + "/size").c_str(), nullptr, 10);
        found = true;
        break;
    }
    closedir(d);
    return found;
}

// Node name of partition `number` of `disk` (mmcblk0p1, sda1, nvme0n1p1),
// created in /dev.
std::string partition_node(const Disk& disk, int number) {
    DIR* d = opendir(disk.syspath.c_str());
    if (!d) return "";
    std::string node;
    while (dirent* e = readdir(d)) {
        std::string name = e->d_name;
        if (name.rfind(disk.name, 0) != 0) continue;
        std::string dir = disk.syspath + "/" + name;
        if (atoi(read_file(dir + "/partition").c_str()) == number &&
            make_node(dir, name, S_IFBLK)) {
            node = "/dev/" + name;
            break;
        }
    }
    closedir(d);
    return node;
}

// --- GPT --------------------------------------------------------------------

struct __attribute__((packed)) GptHeader {
    char signature[8];
    uint32_t revision;
    uint32_t header_size;
    uint32_t header_crc;
    uint32_t reserved;
    uint64_t my_lba;
    uint64_t alternate_lba;
    uint64_t first_usable;
    uint64_t last_usable;
    uint8_t disk_guid[16];
    uint64_t entries_lba;
    uint32_t num_entries;
    uint32_t entry_size;
    uint32_t entries_crc;
};

struct __attribute__((packed)) GptEntry {
    uint8_t type_guid[16];
    uint8_t unique_guid[16];
    uint64_t first_lba;
    uint64_t last_lba;
    uint64_t attributes;
    uint16_t name[36];
};

uint32_t crc32(const void* data, size_t len) {
    static uint32_t table[256];
    if (table[1] == 0) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xedb88320 ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
    }
    uint32_t c = 0xffffffff;
    const uint8_t* p = static_cast<const uint8_t*>(data);
    for (size_t i = 0; i < len; i++) c = table[(c ^ p[i]) & 0xff] ^ (c >> 8);
    return c ^ 0xffffffff;
}

std::string entry_name(const GptEntry& e) {
    std::string s;
    for (uint16_t c : e.name) {
        if (c == 0) break;
        s += c < 128 ? static_cast<char>(c) : '?';
    }
    return s;
}

void random_guid(uint8_t guid[16]) {
    if (getrandom(guid, 16, 0) != 16) fail("getrandom: %s", strerror(errno));
    guid[7] = (guid[7] & 0x0f) | 0x40;  // version 4 (mixed-endian GPT layout)
    guid[8] = (guid[8] & 0x3f) | 0x80;  // RFC 4122 variant
}

struct Gpt {
    GptHeader header;
    std::vector<GptEntry> entries;  // all num_entries slots
};

// --- Block I/O ----------------------------------------------------------------

struct AlignedBuf {
    uint8_t* p = nullptr;
    explicit AlignedBuf(size_t size) {
        if (posix_memalign(reinterpret_cast<void**>(&p), 4096, size) != 0) fail("out of memory");
    }
    ~AlignedBuf() { free(p); }
};

void read_at(int fd, void* buf, size_t len, uint64_t off, const char* what) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(fd, static_cast<uint8_t*>(buf) + done, len - done, off + done);
        if (n <= 0) fail("reading %s at %llu: %s", what, (unsigned long long)(off + done),
                         n == 0 ? "end of disk" : strerror(errno));
        done += n;
    }
}

void write_at(int fd, const void* buf, size_t len, uint64_t off, const char* what) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = pwrite(fd, static_cast<const uint8_t*>(buf) + done, len - done, off + done);
        if (n <= 0) fail("writing %s at %llu: %s", what, (unsigned long long)(off + done),
                         n == 0 ? "end of disk" : strerror(errno));
        done += n;
    }
}

Gpt read_gpt(int fd, const char* what) {
    Gpt gpt;
    AlignedBuf sec(kSector);
    read_at(fd, sec.p, kSector, 1 * kSector, what);
    memcpy(&gpt.header, sec.p, sizeof(gpt.header));
    GptHeader& h = gpt.header;
    if (memcmp(h.signature, "EFI PART", 8) != 0) fail("%s has no GPT", what);
    if (h.entry_size != sizeof(GptEntry) || h.num_entries == 0 || h.num_entries > 1024)
        fail("%s: unsupported GPT entry layout", what);
    GptHeader check = h;
    check.header_crc = 0;
    if (crc32(&check, h.header_size) != h.header_crc) fail("%s: GPT header CRC mismatch", what);
    size_t bytes = static_cast<size_t>(h.num_entries) * h.entry_size;
    size_t aligned = (bytes + kSector - 1) / kSector * kSector;
    AlignedBuf ents(aligned);
    read_at(fd, ents.p, aligned, h.entries_lba * kSector, what);
    if (crc32(ents.p, bytes) != h.entries_crc) fail("%s: GPT entries CRC mismatch", what);
    gpt.entries.resize(h.num_entries);
    memcpy(gpt.entries.data(), ents.p, bytes);
    return gpt;
}

// Writes protective MBR, primary and backup GPT for a disk of `sectors`.
void write_gpt(int fd, Gpt gpt, uint64_t sectors) {
    GptHeader& h = gpt.header;
    const uint64_t entry_sectors =
            (static_cast<uint64_t>(h.num_entries) * h.entry_size + kSector - 1) / kSector;
    const size_t bytes = static_cast<size_t>(h.num_entries) * h.entry_size;

    AlignedBuf ents(entry_sectors * kSector);
    memset(ents.p, 0, entry_sectors * kSector);
    memcpy(ents.p, gpt.entries.data(), bytes);
    h.entries_crc = crc32(ents.p, bytes);

    // Protective MBR: one 0xee partition covering the disk
    AlignedBuf mbr(kSector);
    read_at(fd, mbr.p, kSector, 0, "target MBR");  // keep any boot code bytes
    memset(mbr.p + 446, 0, 64);
    uint8_t* pe = mbr.p + 446;
    pe[1] = 0x00; pe[2] = 0x02; pe[3] = 0x00;  // CHS start 0/0/2
    pe[4] = 0xee;
    pe[5] = 0xff; pe[6] = 0xff; pe[7] = 0xff;
    uint32_t lba1 = 1;
    uint32_t count = sectors - 1 > 0xffffffffULL ? 0xffffffff : static_cast<uint32_t>(sectors - 1);
    memcpy(pe + 8, &lba1, 4);
    memcpy(pe + 12, &count, 4);
    mbr.p[510] = 0x55;
    mbr.p[511] = 0xaa;
    write_at(fd, mbr.p, kSector, 0, "protective MBR");

    AlignedBuf hdr(kSector);
    auto put_header = [&](uint64_t my_lba, uint64_t alt_lba, uint64_t entries_lba) {
        GptHeader x = h;
        x.my_lba = my_lba;
        x.alternate_lba = alt_lba;
        x.entries_lba = entries_lba;
        x.header_crc = 0;
        x.header_crc = crc32(&x, x.header_size);
        memset(hdr.p, 0, kSector);
        memcpy(hdr.p, &x, sizeof(x));
        write_at(fd, hdr.p, kSector, my_lba * kSector, "GPT header");
    };
    const uint64_t last = sectors - 1;
    const uint64_t backup_entries = last - entry_sectors;
    write_at(fd, ents.p, entry_sectors * kSector, h.entries_lba * kSector, "GPT entries");
    write_at(fd, ents.p, entry_sectors * kSector, backup_entries * kSector, "backup GPT entries");
    put_header(1, last, h.entries_lba);
    put_header(last, 1, backup_entries);
}

// --- Copy / verify --------------------------------------------------------------

struct Range {
    const char* what;
    uint64_t first;  // sector
    uint64_t count;  // sectors
};

struct Progress {
    uint64_t total = 0;
    uint64_t done = 0;
    int shown = -1;
    time_t start = time(nullptr);
    const char* phase = "";
    void add(uint64_t bytes) {
        done += bytes;
        int pct = total ? static_cast<int>(done * 100 / total) : 100;
        if (pct != shown) {
            shown = pct;
            long secs = static_cast<long>(time(nullptr) - start);
            out("\r  %s %3d%%  (%llu of %llu MiB, %ld s)", phase, pct,
                (unsigned long long)(done >> 20), (unsigned long long)(total >> 20), secs);
        }
    }
};

void copy_range(int src, int dst, const Range& r, Progress* prog) {
    AlignedBuf buf(kChunk);
    uint64_t off = r.first * kSector;
    uint64_t left = r.count * kSector;
    while (left) {
        size_t n = left < kChunk ? left : kChunk;
        read_at(src, buf.p, n, off, r.what);
        write_at(dst, buf.p, n, off, r.what);
        off += n;
        left -= n;
        prog->add(n);
    }
}

void verify_range(int src, int dst, const Range& r, Progress* prog) {
    AlignedBuf a(kChunk), b(kChunk);
    uint64_t off = r.first * kSector;
    uint64_t left = r.count * kSector;
    while (left) {
        size_t n = left < kChunk ? left : kChunk;
        read_at(src, a.p, n, off, r.what);
        read_at(dst, b.p, n, off, r.what);
        if (memcmp(a.p, b.p, n) != 0)
            fail("%s differs after writing (near byte %llu): bad storage?", r.what,
                 (unsigned long long)off);
        off += n;
        left -= n;
        prog->add(n);
    }
}

void zero_range(int dst, uint64_t first, uint64_t bytes, const char* what) {
    AlignedBuf buf(kChunk);
    memset(buf.p, 0, kChunk);
    uint64_t off = first * kSector;
    while (bytes) {
        size_t n = bytes < kChunk ? bytes : kChunk;
        write_at(dst, buf.p, n, off, what);
        off += n;
        bytes -= n;
    }
}

bool copy_file(const std::string& from, const std::string& to) {
    std::string data;
    int in = open(from.c_str(), O_RDONLY | O_CLOEXEC);
    if (in < 0) return false;
    char buf[4096];
    ssize_t n;
    while ((n = read(in, buf, sizeof(buf))) > 0) data.append(buf, n);
    close(in);
    if (n < 0) return false;
    int o = open(to.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (o < 0) return false;
    bool ok = write(o, data.data(), data.size()) == static_cast<ssize_t>(data.size()) &&
              fsync(o) == 0;
    return close(o) == 0 && ok;
}

void setup_early() {
    mkdir("/dev", 0755);
    mkdir("/proc", 0555);
    mkdir("/sys", 0555);
    mkdir("/mnt", 0755);
    mount("tmpfs", "/dev", "tmpfs", MS_NOSUID, "mode=0755");
    mount("proc", "/proc", "proc", 0, nullptr);
    mount("sysfs", "/sys", "sysfs", 0, nullptr);
    mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    mknod("/dev/tty0", S_IFCHR | 0600, makedev(4, 0));
    mknod("/dev/null", S_IFCHR | 0666, makedev(1, 3));
    g_uart = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    g_tty = open("/dev/tty0", O_WRONLY | O_NOCTTY | O_CLOEXEC);
}

}  // namespace

int main(int argc, char** argv) {
    const bool test = (argc == 3 || argc == 4) && strcmp(argv[1], "--test") == 0;
    const bool test_dry_run = test && argc == 4 && strcmp(argv[3], "--dry-run") == 0;
    if (getpid() != 1 && !test) {
        fprintf(stderr, "rock5_installer runs as /init of the installer ramdisk\n"
                        "test: rock5_installer --test <disk> [--dry-run]\n");
        return 1;
    }
    g_test = test;
    if (test) {
        g_uart = STDOUT_FILENO;
    } else {
        setup_early();
    }
    const char* mnt = test ? "/data/local/tmp/rock5_installer.mnt" : "/mnt";
    out("\n\n=== OS installer ===\n\n");

    const std::string cmdline = read_file("/proc/cmdline");
    const std::string src_match =
            cmdline_value(cmdline, "rock5_installer.source", "fe2c0000.mmc");
    const std::string dst_match =
            cmdline_value(cmdline, "rock5_installer.target", "fe2e0000.mmc");
    const int countdown =
            test ? 0 : atoi(cmdline_value(cmdline, "rock5_installer.countdown", "10").c_str());
    const bool dry_run =
            test_dry_run || cmdline_value(cmdline, "rock5_installer.dry_run", "0") == "1";
    if (dry_run) out("DRY RUN: nothing will be written.\n\n");

    // Storage drivers probe asynchronously: give them a few seconds
    Disk src, dst;
    if (test) {
        char real[PATH_MAX];
        if (realpath((std::string("/sys/block/") + argv[2]).c_str(), real)) {
            dst.name = argv[2];
            dst.syspath = real;
            dst.sectors = strtoull(read_file(dst.syspath + "/size").c_str(), nullptr, 10);
        }
        find_disk(src_match, &src);
    }
    for (int i = 0; i < 100 && !test; i++) {
        if (find_disk(src_match, &src) && find_disk(dst_match, &dst)) break;
        usleep(100 * 1000);
    }
    if (src.name.empty()) fail("no source disk (%s): did the card come out?", src_match.c_str());
    if (dst.name.empty())
        fail("no internal storage found (%s). Is the eMMC module fitted?", dst_match.c_str());
    if (src.name == dst.name) fail("source and target are the same disk (%s)", src.name.c_str());
    if (!make_node(src.syspath, src.name, S_IFBLK) || !make_node(dst.syspath, dst.name, S_IFBLK))
        fail("could not create device nodes");

    out("From: %s, %llu MiB  (%s)\n", src.name.c_str(),
        (unsigned long long)(src.sectors * kSector >> 20), src_match.c_str());
    out("To:   %s, %llu MiB  (%s)\n\n", dst.name.c_str(),
        (unsigned long long)(dst.sectors * kSector >> 20), dst_match.c_str());

    const std::string src_dev = "/dev/" + src.name;
    const std::string dst_dev = "/dev/" + dst.name;
    int sfd = open(src_dev.c_str(), O_RDONLY | O_DIRECT | O_CLOEXEC);
    if (sfd < 0) fail("open %s: %s", src_dev.c_str(), strerror(errno));
    int dfd = open(dst_dev.c_str(), (dry_run ? O_RDONLY : O_RDWR) | O_DIRECT | O_CLOEXEC);
    if (dfd < 0) fail("open %s: %s", dst_dev.c_str(), strerror(errno));

    // The card's partitions, by name
    Gpt gpt = read_gpt(sfd, "the card");
    auto find = [&](const char* name) -> GptEntry* {
        for (auto& e : gpt.entries)
            if (e.first_lba && entry_name(e) == name) return &e;
        fail("the card has no '%s' partition", name);
    };
    GptEntry* boot = find("boot");
    GptEntry* system = find("system");
    GptEntry* vendor = find("vendor");
    GptEntry* metadata = find("metadata");
    GptEntry* userdata = find("userdata");
    uint64_t first_part = UINT64_MAX;
    for (auto& e : gpt.entries)
        if (e.first_lba && e.first_lba < first_part) first_part = e.first_lba;
    if (first_part <= kUbootFirst) fail("the card's first partition overlaps U-Boot");
    for (auto& e : gpt.entries)
        if (e.first_lba && &e != userdata && e.last_lba >= userdata->first_lba)
            fail("userdata must be the last partition");

    // Target layout: same partitions, userdata to the end
    const uint64_t entry_sectors =
            (static_cast<uint64_t>(gpt.header.num_entries) * gpt.header.entry_size + kSector - 1) /
            kSector;
    const uint64_t last_usable = dst.sectors - 1 - entry_sectors - 1;
    const uint64_t min_userdata = (1ULL << 30) / kSector;  // 1 GiB
    if (last_usable < userdata->first_lba + min_userdata)
        fail("internal storage too small: %llu MiB, needs at least %llu MiB",
             (unsigned long long)(dst.sectors * kSector >> 20),
             (unsigned long long)((userdata->first_lba + min_userdata + 34) * kSector >> 20));

    const std::vector<Range> copies = {
            {"U-Boot", kUbootFirst, first_part - kUbootFirst},
            {"boot", boot->first_lba, boot->last_lba - boot->first_lba + 1},
            {"system", system->first_lba, system->last_lba - system->first_lba + 1},
            {"vendor", vendor->first_lba, vendor->last_lba - vendor->first_lba + 1},
    };
    Progress copy_prog, verify_prog;
    for (const auto& r : copies) copy_prog.total += r.count * kSector;
    verify_prog.total = copy_prog.total;

    out("Partitions copied: U-Boot, boot, system, vendor (%llu MiB)\n",
        (unsigned long long)(copy_prog.total >> 20));
    out("userdata on the target: %llu MiB (formatted by Android on first boot)\n\n",
        (unsigned long long)((last_usable - userdata->first_lba + 1) * kSector >> 20));

    if (dry_run) {
        out("Reading the card to check it...\n");
        AlignedBuf buf(kChunk);
        Progress p;
        p.total = copy_prog.total;
        p.phase = "reading";
        for (const auto& r : copies) {
            for (uint64_t off = r.first * kSector, left = r.count * kSector; left;) {
                size_t n = left < kChunk ? left : kChunk;
                read_at(sfd, buf.p, n, off, r.what);
                off += n;
                left -= n;
                p.add(n);
            }
        }
        out("\n\nDry run done: the card reads fine and the target fits.\n");
        halt();
    }

    out("ALL DATA ON %s WILL BE ERASED.\n", dst.name.c_str());
    out("Remove the card now to cancel.\n");
    for (int i = countdown; i > 0; i--) {
        out("\r  Installing in %2d s ", i);
        sleep(1);
        Disk again;
        if (!find_disk(src_match, &again)) {
            out("\n\nCancelled: the card was removed. Nothing was written.\n");
            halt();
        }
    }
    out("\n\n");

    // 1. Copy, then 2. read back and compare (O_DIRECT: from the storage, not the cache)
    copy_prog.phase = "writing  ";
    for (const auto& r : copies) copy_range(sfd, dfd, r, &copy_prog);
    if (fsync(dfd) != 0) fail("flushing %s: %s", dst_dev.c_str(), strerror(errno));
    out("\n");
    verify_prog.phase = "verifying";
    for (const auto& r : copies) verify_range(sfd, dfd, r, &verify_prog);
    out("\n");

    // 3. Empty metadata and userdata: Android formats them ("formattable")
    zero_range(dfd, metadata->first_lba,
               std::min<uint64_t>(kZeroBytes, (metadata->last_lba - metadata->first_lba + 1) * kSector),
               "metadata");
    zero_range(dfd, userdata->first_lba, kZeroBytes, "userdata");

    // 4. Partition table for the target's size, with new GUIDs
    random_guid(gpt.header.disk_guid);
    for (auto& e : gpt.entries)
        if (e.first_lba) random_guid(e.unique_guid);
    userdata->last_lba = last_usable;
    gpt.header.last_usable = last_usable;
    write_gpt(dfd, gpt, dst.sectors);
    if (fsync(dfd) != 0) fail("flushing %s: %s", dst_dev.c_str(), strerror(errno));
    out("Partition table written.\n");

    // 5. Boot configuration for the target
    if (ioctl(dfd, BLKRRPART) != 0) fail("re-reading partitions: %s", strerror(errno));
    std::string dst_boot;
    for (int i = 0; i < 50 && dst_boot.empty(); i++) {
        dst_boot = partition_node(dst, 1);
        if (dst_boot.empty()) usleep(100 * 1000);
    }
    if (dst_boot.empty()) fail("the new boot partition did not appear");
    mkdir(mnt, 0700);
    if (mount(dst_boot.c_str(), mnt, "vfat", 0, nullptr) != 0)
        fail("mount %s: %s", dst_boot.c_str(), strerror(errno));
    const std::string m = mnt;
    if (!copy_file(m + "/extlinux/extlinux.conf.target", m + "/extlinux/extlinux.conf"))
        fail("writing extlinux.conf: %s", strerror(errno));
    unlink((m + "/extlinux/extlinux.conf.target").c_str());
    unlink((m + "/installer.img").c_str());
    if (umount(mnt) != 0) fail("umount boot: %s", strerror(errno));
    close(dfd);
    sync();
    out("Boot configuration written.\n\n");

    out("=== INSTALL COMPLETE ===\n\n");
    if (test) return 0;
    out("Remove the card: the board then restarts into the new system.\n");
    for (;;) {
        Disk again;
        if (!find_disk(src_match, &again)) break;
        sleep(1);
    }
    out("\nRestarting...\n");
    sync();
    reboot(RB_AUTOBOOT);
    halt();
}
