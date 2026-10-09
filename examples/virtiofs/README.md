# VirtioFS guest example

This example boots a Debian Linux guest with a VirtioFS mount at
`/mnt/virtiofs-smoke`. Install Vagrant, this plugin, QEMU with
`vhost-user-fs-pci` support, and a compatible `virtiofsd` first.

On macOS, the compatible binaries are available from the Antimatter Studios tap:

```sh
brew install antimatter-studios/tap/qemu antimatter-studios/tap/virtiofsd
```

Create the shared directory and boot from this directory:

```sh
mkdir -p share
printf 'from-host\n' > share/host.txt
vagrant up --provider=qemu
vagrant ssh -c 'mount | grep virtiofs'
vagrant ssh -c 'cat /mnt/virtiofs-smoke/host.txt'
vagrant halt
vagrant destroy -f
```

The CI smoke test copies this Vagrantfile into a temporary directory and also
checks guest-to-host writes and daemon cleanup. It sets `VAGRANT_TEST_FORCE_TCG=1`
so the guest can run on hosted runners without hardware virtualization.
