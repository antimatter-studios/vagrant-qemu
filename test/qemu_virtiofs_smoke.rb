#!/usr/bin/env ruby
require "fileutils"
require "json"
require "ostruct"
require "pathname"
require "rbconfig"
require "securerandom"
require "socket"
require "tmpdir"

# This smoke test starts the provider's virtiofsd configuration and lets QEMU
# connect to it. It needs Linux, QEMU, and a real virtiofsd, but no guest image.
module Vagrant
  def self.plugin(*)
    Object
  end
end

module Log4r
  class Logger
    def initialize(*); end
  end
end

$LOADED_FEATURES << "log4r.rb"
require_relative "../lib/vagrant-qemu/synced_folder_virtiofs"

def executable(name)
  ENV.fetch("PATH").split(File::PATH_SEPARATOR)
    .map { |dir| File.join(dir, name) }
    .find { |path| File.executable?(path) }
end

arch = RbConfig::CONFIG.fetch("host_cpu")
qemu_binary, machine_type = case arch
when "x86_64"
  ["qemu-system-x86_64", "q35,accel=tcg"]
when "aarch64"
  ["qemu-system-aarch64", "virt,accel=tcg"]
else
  abort "Unsupported smoke-test host architecture: #{arch}"
end

virtiofsd = ENV["VIRTIOFSD_BIN"] || executable("virtiofsd") ||
  ["/usr/libexec/virtiofsd", "/usr/lib/qemu/virtiofsd"].find { |path| File.executable?(path) }
abort "virtiofsd is missing" unless virtiofsd
abort "#{qemu_binary} is missing" unless executable(qemu_binary)

dir = Dir.mktmpdir("vagrant-qemu-smoke-")
data_dir = Pathname.new(File.join(dir, "machine"))
shared_dir = File.join(dir, "shared")
FileUtils.mkdir_p(shared_dir)
File.write(File.join(shared_dir, "host.txt"), "virtiofs host smoke")
qmp_socket = File.join(dir, "qmp.sock")
qemu_log = File.join(dir, "qemu.log")
config = OpenStruct.new(
  virtiofsd_bin: virtiofsd,
  memory: "256M",
  virtiofs_guest_uid: 1000,
  virtiofs_guest_gid: 1000,
  extra_virtiofsd_args: [],
  extra_qemu_args: [],
  virtiofs_qemu_args: []
)
ui = Object.new
def ui.info(_message); end
machine = OpenStruct.new(provider_config: config, data_dir: data_dir, id: SecureRandom.hex(8), ui: ui)
folder = { "share" => { hostpath: shared_dir, guestpath: "/mnt/share" } }
adapter = VagrantPlugins::QEMU::SyncedFolderVirtioFS.new
qemu_pid = nil

begin
  adapter.prepare(machine, folder, {})
  command = [
    qemu_binary, "-machine", machine_type, "-cpu", "max", "-m", "256M",
    "-S", "-nodefaults", "-display", "none", "-monitor", "none",
    "-qmp", "unix:#{qmp_socket},server=on,wait=off",
    *config.extra_qemu_args, *config.virtiofs_qemu_args
  ]
  qemu_pid = Process.spawn(*command, [:out, :err] => [qemu_log, "w"])
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  until File.socket?(qmp_socket)
    if Process.waitpid(qemu_pid, Process::WNOHANG)
      qemu_pid = nil
      abort "QEMU exited before its monitor opened:\n#{File.read(qemu_log)}"
    end
    abort "Timed out waiting for QEMU:\n#{File.read(qemu_log)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end

  UNIXSocket.open(qmp_socket) do |socket|
    greeting = JSON.parse(socket.gets)
    raise "QMP greeting missing" unless greeting.key?("QMP")
    socket.puts JSON.generate(execute: "qmp_capabilities")
    capabilities = JSON.parse(socket.gets)
    raise "QMP capability negotiation failed: #{capabilities}" unless capabilities.key?("return")
    socket.puts JSON.generate(execute: "query-status")
    status = JSON.parse(socket.gets)
    raise "QEMU did not stay stopped: #{status}" unless %w[paused prelaunch].include?(status.dig("return", "status"))
    socket.puts JSON.generate(execute: "quit")
  end
  puts "QEMU connected to provider-started virtiofsd via #{config.virtiofs_qemu_args.grep(/memory-backend/).first}"
ensure
  if qemu_pid
    Process.kill("TERM", qemu_pid) rescue nil
    Process.waitpid(qemu_pid) rescue nil
  end
  adapter.cleanup(machine, {})
  memory_file = File.join(Dir.tmpdir, "vagrant-qemu-#{machine.id}-mem")
  File.delete(memory_file) if File.exist?(memory_file)
  FileUtils.remove_entry(dir) if File.exist?(dir)
end
