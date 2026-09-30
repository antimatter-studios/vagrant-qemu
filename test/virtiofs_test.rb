require "minitest/autorun"
require "fileutils"
require "json"
require "ostruct"
require "pathname"
require "rbconfig"
require "securerandom"
require "tmpdir"

# Keep command construction tests independent of Vagrant's installation and
# Ruby version. The test exercises the provider classes and their real process
# launching path with a small stand-in for virtiofsd.
class TestVagrantConfig < Object
  UNSET_VALUE = Object.new
end

module Vagrant
  def self.plugin(_version, type = nil)
    type == :config ? TestVagrantConfig : Object
  end
end

module Log4r
  class Logger
    def initialize(*); end
  end
end

$LOADED_FEATURES << "vagrant.rb"
$LOADED_FEATURES << "log4r.rb"

require_relative "../lib/vagrant-qemu/config"
require_relative "../lib/vagrant-qemu/synced_folder_virtiofs"
require_relative "../lib/vagrant-qemu/action/mount_virtiofs"

class VirtiofsTest < Minitest::Test
  Machine = Struct.new(:provider_name, :provider_config, :data_dir, :id, :ui, :communicate, :config)

  class UI
    attr_reader :messages

    def initialize
      @messages = []
    end

    def info(message)
      @messages << message
    end
  end

  class Communicator
    attr_reader :commands

    def initialize
      @commands = []
    end

    def sudo(command)
      @commands << command
    end
  end

  def setup
    @dir = Dir.mktmpdir("vagrant-qemu-test-")
    @folder = File.join(@dir, "host share")
    FileUtils.mkdir_p(@folder)
    @machine = Machine.new(
      :qemu,
      OpenStruct.new(
        virtiofsd_bin: nil,
        memory: "256M",
        virtiofs_guest_uid: 1000,
        virtiofs_guest_gid: 1000,
        extra_virtiofsd_args: [],
        extra_qemu_args: []
      ),
      Pathname.new(File.join(@dir, "machine")),
      SecureRandom.hex(8),
      UI.new,
      Communicator.new,
      nil
    )
  end

  def teardown
    socket_path_file = @machine&.data_dir&.join("virtiofs", "virtiofs0.sock_path")
    if socket_path_file&.file?
      args_file = "#{File.read(socket_path_file).strip}.args.json"
      File.delete(args_file) if File.exist?(args_file)
    end
    VagrantPlugins::QEMU::SyncedFolderVirtioFS.new.cleanup(@machine, {}) if @machine
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_linux_and_macos_provider_defaults
    config = VagrantPlugins::QEMU::Config.new
    config.finalize!

    arch = RbConfig::CONFIG["host_cpu"] =~ /arm|aarch64/ ? "aarch64" : "x86_64"
    base_machine = arch == "aarch64" ? "virt,highmem=on" : "q35"
    accelerator = RUBY_PLATFORM.include?("darwin") ? "hvf" : "kvm"
    assert_equal arch, config.arch
    assert_equal "#{base_machine},accel=#{accelerator}", config.machine
    assert_equal "host", config.cpu
    assert_equal(arch == "aarch64" ? "virtio-net-device" : "virtio-net-pci", config.net_device)
  end

  def test_cross_architecture_defaults_use_tcg
    config = VagrantPlugins::QEMU::Config.new
    host_arch = RbConfig::CONFIG["host_cpu"] =~ /arm|aarch64/ ? "aarch64" : "x86_64"
    config.arch = host_arch == "aarch64" ? "x86_64" : "aarch64"
    config.finalize!

    assert_equal "max", config.cpu
    assert_match(/,accel=tcg\z/, config.machine)
    assert_equal(config.arch == "aarch64" ? "virtio-net-device" : "virtio-net-pci", config.net_device)
  end

  def test_modern_virtiofsd_options_and_qemu_shared_memory
    configure_fake_daemon("--socket-path --shared-dir --sandbox --inode-file-handles --translate-uid --translate-gid")
    @machine.provider_config.extra_virtiofsd_args = ["--cache=always"]

    VagrantPlugins::QEMU::SyncedFolderVirtioFS.new.prepare(@machine, folders, {})
    args = daemon_args

    assert_includes args, "--shared-dir=#{@folder}"
    assert_includes args, "--sandbox=none"
    assert_includes args, "--inode-file-handles=never"
    assert_includes args, "--translate-uid"
    assert_includes args, "--translate-gid"
    assert_includes args, "--cache=always"
    assert_includes @machine.provider_config.extra_qemu_args, "-device"
    assert_includes @machine.provider_config.extra_qemu_args, "vhost-user-fs-pci,chardev=char_virtiofs0,tag=virtiofs0"

    memory_arg = @machine.provider_config.extra_qemu_args.find { |arg| arg.start_with?("memory-backend-") }
    if RUBY_PLATFORM.include?("linux")
      assert_equal "memory-backend-memfd,id=mem,size=256M,share=on", memory_arg
    elsif RUBY_PLATFORM.include?("darwin")
      assert_match(/\Amemory-backend-file,id=mem,size=256M,mem-path=.*?,share=on\z/, memory_arg)
    end
  end

  def test_legacy_virtiofsd_options
    configure_fake_daemon("--socket-path -o source=DIR, sandbox=none")

    VagrantPlugins::QEMU::SyncedFolderVirtioFS.new.prepare(@machine, folders, {})
    args = daemon_args

    assert_includes args.each_cons(2).to_a, ["-o", "source=#{@folder}"]
    assert_includes args.each_cons(2).to_a, ["-o", "sandbox=none"]
    refute args.any? { |arg| arg.start_with?("--shared-dir") }
    refute args.any? { |arg| arg.start_with?("--translate-uid") }
  end

  def test_mount_quotes_guest_path
    @machine.config = OpenStruct.new(
      vm: OpenStruct.new(
        synced_folders: {
          "share" => { type: "virtiofs", guestpath: "/mnt/a shared folder" }
        }
      )
    )
    called = false
    app = ->(_env) { called = true }

    VagrantPlugins::QEMU::Action::MountVirtioFS.new(app, {}).call(machine: @machine)

    assert_equal [
      "mkdir -p /mnt/a\\ shared\\ folder",
      "mount -t virtiofs virtiofs0 /mnt/a\\ shared\\ folder"
    ], @machine.communicate.commands
    assert called
  end

  private

  def folders
    { "share" => { hostpath: @folder, guestpath: "/vagrant" } }
  end

  def configure_fake_daemon(help_text)
    help_path = File.join(@dir, "help.txt")
    File.write(help_path, help_text)
    daemon_path = File.join(@dir, "virtiofsd")
    File.write(daemon_path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      if ARGV.include?("--help")
        puts File.read(#{help_path.inspect})
        exit
      end
      socket = ARGV.find { |arg| arg.start_with?("--socket-path=") }.split("=", 2).last
      File.write(socket + ".args.json", JSON.generate(ARGV))
      File.write(socket, "")
      sleep 60
    RUBY
    FileUtils.chmod(0755, daemon_path)
    @machine.provider_config.virtiofsd_bin = daemon_path
  end

  def daemon_args
    socket_path_file = @machine.data_dir.join("virtiofs", "virtiofs0.sock_path")
    socket_path = File.read(socket_path_file).strip
    JSON.parse(File.read("#{socket_path}.args.json"))
  end
end
