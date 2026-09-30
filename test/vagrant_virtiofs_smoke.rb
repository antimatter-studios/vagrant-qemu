#!/usr/bin/env ruby
require "fileutils"
require "tmpdir"

# Boot a real Vagrant guest and verify both directions of a VirtioFS share.
# The plugin must already be installed in this Vagrant installation.
def run!(*command, chdir:)
  puts "+ #{command.join(' ')}"
  raise "#{command.first} failed" unless system(*command, chdir: chdir)
end

box = ENV.fetch("VAGRANT_TEST_BOX", "cloud-image/debian-12")
architecture = ENV.fetch("VAGRANT_TEST_ARCH", "amd64")
raise "Unsupported architecture: #{architecture}" unless %w[amd64 arm64].include?(architecture)

Dir.mktmpdir("vagrant-qemu-guest-smoke-") do |dir|
  share = File.join(dir, "share")
  FileUtils.mkdir_p(share)
  File.write(File.join(share, "host.txt"), "from-host\n")

  File.write(File.join(dir, "Vagrantfile"), <<~VAGRANTFILE)
    Vagrant.configure("2") do |config|
      config.vm.box = #{box.inspect}
      config.vm.box_architecture = #{architecture.inspect}
      config.vm.box_check_update = false
      config.vagrant.plugins = []
      config.vm.synced_folder ".", "/vagrant", disabled: true
      config.vm.synced_folder #{share.inspect}, "/mnt/virtiofs-smoke", type: "virtiofs"
      config.vm.provider "qemu" do |qemu|
        qemu.memory = "1G"
        qemu.qemu_dir = #{ENV["VAGRANT_TEST_QEMU_DIR"].inspect} if #{!ENV["VAGRANT_TEST_QEMU_DIR"].nil?}
        if #{ENV["VAGRANT_TEST_FORCE_TCG"] == "1"}
          qemu.machine = #{(architecture == "amd64" ? "q35,accel=tcg" : "virt,highmem=on,accel=tcg").inspect}
          qemu.cpu = "max"
        end
      end
    end
  VAGRANTFILE

  begin
    run!("vagrant", "up", "--provider=qemu", "--no-provision", chdir: dir)
    guest_command = "sudo sh -c 'findmnt -n -o FSTYPE /mnt/virtiofs-smoke | grep -qx virtiofs && grep -qx from-host /mnt/virtiofs-smoke/host.txt && printf from-guest > /mnt/virtiofs-smoke/guest.txt'"
    run!("vagrant", "ssh", "-c", guest_command, chdir: dir)
    raise "Guest write did not reach host" unless File.read(File.join(share, "guest.txt")) == "from-guest"
    puts "Vagrant guest mounted VirtioFS and read/wrote the host share"
  ensure
    system("vagrant", "destroy", "-f", chdir: dir)
  end
end
