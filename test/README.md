# Provider checks

Run the command tests on Linux or macOS with Ruby 3.2 or later:

```sh
ruby test/virtiofs_test.rb
```

These tests exercise provider defaults, modern and legacy virtiofsd arguments,
the QEMU memory backend and device arguments, reload argument deduplication,
and guest mount path quoting.
They launch a small fake daemon, so no Vagrant or QEMU installation is needed.
The GitHub Actions matrix runs them on both operating systems.

On Linux, install QEMU and virtiofsd, then check the real device handshake:

```sh
ruby test/qemu_virtiofs_smoke.rb
```

This starts virtiofsd through the provider's folder adapter and starts QEMU
with the resulting arguments. It checks QEMU's monitor response. It does not
boot a guest or verify an in-guest mount.

With Vagrant and this plugin installed, run a full guest check:

```sh
ruby test/vagrant_virtiofs_smoke.rb
```

The default box is `cloud-image/debian-12` for amd64. Set
`VAGRANT_TEST_ARCH=arm64` on an ARM host, and
`VAGRANT_TEST_QEMU_DIR` if ARM firmware is outside QEMU's default directory.
The script checks the guest mount, reads a host file, writes a file back,
halts the VM to verify daemon cleanup, then destroys it. CI runs this stage
on Linux with TCG for portable virtualization.
