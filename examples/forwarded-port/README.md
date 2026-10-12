# HTTP port forwarding

Install QEMU and this plugin, then run from this directory:

```sh
vagrant up --provider=qemu
curl --fail --max-time 10 http://127.0.0.1:8080/
```

Expected response: `vagrant-qemu HTTP forwarding works`.

The Vagrantfile provisions a real HTTP service on guest port 80. It disables
the default synced folder so SMB setup cannot interrupt this networking example.
It uses a Debian cloud box matching the host architecture and the provider's
native acceleration defaults (HVF on macOS, KVM on Linux).

On Debian ARM64, install `qemu-efi-aarch64`. If your firmware package uses
`AAVMF_CODE.no-secboot.fd` and `AAVMF_VARS.fd`, provide the names expected by
the plugin in a project-local directory:

```sh
mkdir -p firmware
ln -s /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd firmware/edk2-aarch64-code.fd
ln -s /usr/share/AAVMF/AAVMF_VARS.fd firmware/edk2-arm-vars.fd
QEMU_DIR="$PWD/firmware" vagrant up --provider=qemu
```

Keep `QEMU_DIR` set when importing a fresh VM. Existing firmware copies are
stored with that VM. macOS Homebrew QEMU normally supplies the expected names.

If host port 8080 is occupied, use an available port explicitly:

```sh
FORWARDED_PORT=8082 vagrant up --provider=qemu
curl --fail --max-time 10 http://127.0.0.1:8082/
```

Forwarding uses QEMU user networking. It does not require `advanced_network`
and does not assign a private IP reachable directly from the host. The guest
service must listen on its network interface (here `0.0.0.0`), and its firewall
must allow the guest port. `host_ip: "127.0.0.1"` restricts access to the host.
Disabling the QEMU NIC with `net_device = nil` disables these forwards.

For diagnosis:

```sh
vagrant ssh -c 'sudo systemctl status vagrant-forwarded-port --no-pager'
vagrant ssh -c 'curl --fail http://127.0.0.1/'
vagrant ssh -c 'sudo ss -lntp'
```

A successful guest request followed by a failed host request narrows the problem
to forwarding, host ports, or firewall rules. A failed guest request means the
HTTP service itself needs attention. Finish with `vagrant destroy -f`.
