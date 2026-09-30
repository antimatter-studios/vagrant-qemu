#!/usr/bin/env ruby
require "fileutils"
require "tmpdir"

# Boot a real Vagrant guest and verify both directions of a VirtioFS share.
# The plugin must already be installed in this Vagrant installation.
def run!(*command, chdir:)
  puts "+ #{command.join(' ')}"
  raise "#{command.first} failed" unless system(*command, chdir: chdir)
end

def print_virtiofsd_diagnostics(dir)
  paths = Dir.glob(File.join(dir, ".vagrant", "machines", "*", "qemu", "virtiofs", "*"))
  warn "VirtioFS diagnostics: #{paths.empty? ? 'no daemon files found' : paths.length.to_s + ' daemon files'}"
  paths.sort.each do |path|
    next unless File.file?(path)

    warn "--- #{path} ---"
    warn File.read(path)
    if path.end_with?(".pid")
      pid = File.read(path).strip
      system("ps", "-o", "pid,ppid,stat,command", "-p", pid)
    end
  end
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
        qemu.extra_virtiofsd_args = ["--seccomp=none"]
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
    daemon_dirs = Dir.glob(File.join(dir, ".vagrant", "machines", "*", "qemu", "virtiofs"))
    raise "Expected one virtiofsd state directory, found #{daemon_dirs.length}" unless daemon_dirs.length == 1
    daemon_dir = daemon_dirs.first
    socket_path = File.read(File.join(daemon_dir, "virtiofs0.sock_path")).strip
    raise "virtiofsd socket disappeared while guest was running" unless File.socket?(socket_path)

    run!("vagrant", "halt", chdir: dir)
    raise "vagrant halt left virtiofsd state behind" if File.exist?(daemon_dir)
    raise "vagrant halt left the virtiofsd socket behind" if File.exist?(socket_path)
    puts "Vagrant guest mounted VirtioFS and read/wrote the host share"
  rescue StandardError
    print_virtiofsd_diagnostics(dir)
    raise
  ensure
    system("vagrant", "destroy", "-f", chdir: dir)
  end
end
