---
layout: post
title:  "Announcing Asterinas 0.18.0"
date:   2026-06-04 09:00:00 +0800
author: "Hongliang Tian"
---

The [Asterinas](https://github.com/asterinas/asterinas) community is happy to announce a new version of Asterinas, [0.18.0](https://github.com/asterinas/asterinas/releases/tag/v0.18.0)!

<div class="video-container">
    <iframe src="//player.bilibili.com/player.html?isOutside=true&aid=116692231391283&bvid=BV1sfEA6NENm&cid=38859048677&p=1&autoplay=0"
            scrolling="no"
            border="0"
            frameborder="no"
            framespacing="0"
            allowfullscreen="true">
    </iframe>
</div>

The headline of this release is a major step toward running Asterinas as the guest OS for VM-based **[Kata Containers](https://katacontainers.io/)** and **[Confidential Containers (CoCo)](https://confidentialcontainers.org/)**. Getting there requires a host of new building blocks, and this release delivers many of them: **namespaces** (the IPC and cgroup namespaces, plus nsfs at `/proc/[pid]/ns`), **cgroups** (the PID sub-controller and a partial CPU sub-controller), **virtio-fs** for sharing a filesystem with the host, **virtio-rng** (`/dev/hwrng`) for hardware entropy, and a fully **reimplemented vsock** for host–guest communication.

Userspace debugging comes to Asterinas in this release. We implement the **`ptrace`** syscall along with its core operations—`PTRACE_SETOPTIONS`, `PTRACE_SYSCALL`, and `PTRACE_PEEK`/`POKE`—which together enable popular debugging tools such as **GDB** and **strace** to run on Asterinas, complete with verified-usage documentation and CI coverage.

This release also substantially modernizes the storage stack. The **ext2 filesystem has been reimplemented**, a new **NVMe driver** joins the block layer, and the VFS gains a new **`Dentry` revalidate mechanism** alongside a **refactored page cache**. The result is a more reliable and capable storage stack.

Finally, Asterinas NixOS dramatically expands its coverage of real-world software, with **over 100 popular packages now verified**—including **Codex**, **QEMU**, and **Firefox**. To keep this growing catalog working, we have integrated a range of new test suites, including **kselftest**, **xfstests**, and the standard unit-test suites of **Go**, **Python**, and **JDK**.

## Asterinas NixOS

We have made the following key changes to Asterinas NixOS:

* [Add a framework for Asterinas NixOS test suites](https://github.com/asterinas/asterinas/pull/2771)
* [Add documentation for more verified applications](https://github.com/asterinas/asterinas/pull/2956)
* [Add tests for popular applications](https://github.com/asterinas/asterinas/pull/3187)
* [Add Go std test on Asterinas NixOS](https://github.com/asterinas/asterinas/pull/2943)
* [Add JDK test on Asterinas NixOS](https://github.com/asterinas/asterinas/pull/3017)
* [Add Python regression tests on Asterinas NixOS](https://github.com/asterinas/asterinas/pull/2944)
* [Add QEMU test for virtualization applications](https://github.com/asterinas/asterinas/pull/3245)
* [Support `ARCH_GET_GS`/`ARCH_SET_GS` to enable Firefox](https://github.com/asterinas/asterinas/pull/3286)

## Asterinas Kernel

We have made the following key changes to the Asterinas kernel:

* Process management
    * [Refactor `PidFile` and add the `pidfd_getfd` syscall](https://github.com/asterinas/asterinas/pull/2877), [add the `pidfd_send_signal` syscall](https://github.com/asterinas/asterinas/pull/2912), and [align `PidFile` semantics with POSIX](https://github.com/asterinas/asterinas/pull/2922)
    * [Fix buggy behavior when loading corrupted ELF files](https://github.com/asterinas/asterinas/pull/2777)
* Ptrace
    * [Add the `ptrace` syscall](https://github.com/asterinas/asterinas/pull/2984)
    * [Support debugging with `ptrace`](https://github.com/asterinas/asterinas/pull/3065)
    * Add [`PTRACE_SETOPTIONS`](https://github.com/asterinas/asterinas/pull/3061), [`PTRACE_SYSCALL`](https://github.com/asterinas/asterinas/pull/3241), and [`PTRACE_PEEK/POKE_TEXT/DATA`](https://github.com/asterinas/asterinas/pull/3242)
    * Add (kernel-side) patches, verified-usage docs, and CI for [GDB](https://github.com/asterinas/asterinas/pull/3254) and [strace](https://github.com/asterinas/asterinas/pull/3266)
    * [Support force-write via `/proc/[pid]/mem`](https://github.com/asterinas/asterinas/pull/2855)
    * [Add the Yama ptrace scope](https://github.com/asterinas/asterinas/pull/3018)
* Signals and IPC
    * [Correct `sigsuspend` and fix various other signal behaviors](https://github.com/asterinas/asterinas/pull/3050)
    * [Fix lots of bugs in System V semaphores](https://github.com/asterinas/asterinas/pull/3199)
* Memory management
    * [Respect `mmap` address hints](https://github.com/asterinas/asterinas/pull/3012)
    * [Fix many wrong error codes and other buggy behavior in various MM syscalls](https://github.com/asterinas/asterinas/pull/2766)
* File systems
    * VFS
        * [Add the pseudo `Path`](https://github.com/asterinas/asterinas/pull/2798)
        * [Introduce the `Dentry` revalidate mechanism](https://github.com/asterinas/asterinas/pull/3048)
        * [Refactor the page cache implementation](https://github.com/asterinas/asterinas/pull/2953) and [fix a page cache bug that leaks uninitialized memory to userspace](https://github.com/asterinas/asterinas/pull/3256)
        * [Implement the `pivot_root` syscall](https://github.com/asterinas/asterinas/pull/2445)
        * [Implement `O_TMPFILE` support for `open`/`openat`](https://github.com/asterinas/asterinas/pull/3185)
        * [Refactor `Metadata`'s fields and fix pseudo-filesystems' Device ID](https://github.com/asterinas/asterinas/pull/2887)
    * virtio-fs
        * [Support virtio-fs in Asterinas](https://github.com/asterinas/asterinas/pull/3084)
    * Ext2
        * [Rewrite the ext2 filesystem](https://github.com/asterinas/asterinas/pull/3171)
    * Procfs
        * Add [`/proc/mounts`](https://github.com/asterinas/asterinas/pull/2929), [`/proc/[pid]/auxv`](https://github.com/asterinas/asterinas/pull/3073), [`/proc/[tid]`](https://github.com/asterinas/asterinas/pull/3125), [more entries in `/proc/[pid]/maps`](https://github.com/asterinas/asterinas/pull/2925), and [`mountstats`](https://github.com/asterinas/asterinas/pull/3054)
* Sockets and networking
    * [Rewrite vsock](https://github.com/asterinas/asterinas/pull/3122)
    * [Add initial IPv6 support](https://github.com/asterinas/asterinas/pull/3129)
    * [Reject binding to privileged ports without `CAP_NET_BIND_SERVICE`](https://github.com/asterinas/asterinas/pull/3141)
    * [Fix some UDP problems](https://github.com/asterinas/asterinas/pull/3282)
* Namespaces and cgroups
    * [Support nsfs (`/proc/[pid]/ns`)](https://github.com/asterinas/asterinas/pull/2966)
    * [Support the IPC namespace](https://github.com/asterinas/asterinas/pull/2988)
    * [Support the cgroup namespace](https://github.com/asterinas/asterinas/pull/3109)
    * [Implement the cgroup PID sub-controller](https://github.com/asterinas/asterinas/pull/2987)
    * Add a partial cgroup CPU sub-controller, providing [`cpu.stat` statistics](https://github.com/asterinas/asterinas/pull/3116) and [dummy `cpu.weight`/`cpu.max` limit files](https://github.com/asterinas/asterinas/pull/3175)
    * [Bind mount namespace files](https://github.com/asterinas/asterinas/pull/3082)
* Security
    * [Implement capabilities and execution of programs by root](https://github.com/asterinas/asterinas/pull/2978)
    * [Implement capability bounding set support](https://github.com/asterinas/asterinas/pull/3092)
    * [Fix credentials-related system calls and clean them up](https://github.com/asterinas/asterinas/pull/2952)
    * [Add the initial LSM framework](https://github.com/asterinas/asterinas/pull/3078)
* Devices
    * Block and NVMe
        * [Add the NVMe driver](https://github.com/asterinas/asterinas/pull/1984)
    * PCI
        * [Improve PCI device enumeration and detection](https://github.com/asterinas/asterinas/pull/2680)
        * [Get the PCI bus range from FDT/ACPI and add support for PCI ECAM on x86](https://github.com/asterinas/asterinas/pull/2914)
    * TTY and console
        * [Support multiple TTYs](https://github.com/asterinas/asterinas/pull/3049)
        * [Support the NS16550A UART console, `/dev/ttyS0`, and `console=ttyS0`](https://github.com/asterinas/asterinas/pull/2837)
        * [Keyboard enhancements](https://github.com/asterinas/asterinas/pull/3000)
    * VirtIO
        * [Support `virtio-rng` and expose it as `/dev/hwrng`](https://github.com/asterinas/asterinas/pull/2951)
        * [Model `virtqueue` as untrusted and use fallible allocation in `aster-virtio`](https://github.com/asterinas/asterinas/pull/3160)
    * TDX
        * [Add TSM-MR (measurement register) sysfs support](https://github.com/asterinas/asterinas/pull/2891)
* Tests
    * [Add Linux kselftest test suite](https://github.com/asterinas/asterinas/pull/2900)
    * [Add the xfstests test suite](https://github.com/asterinas/asterinas/pull/2945)
* Misc
    * [Add a generic syscall table](https://github.com/asterinas/asterinas/pull/2819)
    * [Introduce the kernel parameter framework](https://github.com/asterinas/asterinas/pull/3010)

## Asterinas OSTD & OSDK

We have made the following key changes to OSTD and/or OSDK:

* OSTD
    * [Replace the `log` crate with OSTD's own logging API](https://github.com/asterinas/asterinas/pull/3080)
    * [Refactor `Pod` with zerocopy](https://github.com/asterinas/asterinas/pull/2898)
    * [Refactor the DMA APIs](https://github.com/asterinas/asterinas/pull/2351)
    * [Add a Memcpy/Memset trait framework for typed memory copies](https://github.com/asterinas/asterinas/pull/3022)
* Misc
    * [Add a Docker development environment on ARM (aarch64)](https://github.com/asterinas/asterinas/pull/2691)

## Asterinas Book

We have made the following key changes to the Book:

* [Add coding guidelines](https://github.com/asterinas/asterinas/pull/2974)
* [Add OSTD soundness analysis](https://github.com/asterinas/asterinas/pull/3042)
* [Add Kata Containers documentation](https://github.com/asterinas/asterinas/pull/3170)
* [Add Confidential Containers (CoCo) documentation](https://github.com/asterinas/asterinas/pull/3192)

## Contributors

This release was made possible by contributions from 36 individuals. Thank you for your amazing work!

* Ruihan Li (191 commits)
* jiangjianfeng (92 commits)
* Wang Siyuan (72 commits)
* Qingsong Chen (64 commits)
* Chen Chengjun (59 commits)
* Tate, Hongliang Tian (52 commits)
* Tao Su (46 commits)
* Zhang Junyang (36 commits)
* zjp (26 commits)
* li041 (23 commits)
* Xinyi Yu (23 commits)
* Marsman1996 (18 commits)
* wyt8 (17 commits)
* Aaron Chen (9 commits)
* zzj-5341 (9 commits)
* Chaoqun Zheng (8 commits)
* Hsy-Intel (7 commits)
* Cautreoxit (4 commits)
* Chao Liu (4 commits)
* Junrui Luo (4 commits)
* Ray Lee (4 commits)
* rikosellic (4 commits)
* TankTechnology (4 commits)
* Zhenchen Wang (4 commits)
* Yuke Peng (3 commits)
* Zhihang Shao (3 commits)
* yyda (3 commits)
* Arthur Paulino (1 commit)
* Jakob Hellermann (1 commit)
* Linermao (1 commit)
* lxh (1 commit)
* Shen Bowen (1 commit)
* Wei Zhang (1 commit)
* wrj97 (1 commit)
* YanLien (1 commit)
* zzjrabbit (1 commit)
