#!/usr/bin/env ruby

# Build a renamed distribution without keeping its Vagrant loader in source.
root = File.expand_path("..", __dir__)
name = ARGV.fetch(0, "vagrant-qemu")
abort "Invalid gem name: #{name}" unless name.match?(/\A[a-z0-9][a-z0-9-]*\z/)

entrypoint = name == "vagrant-qemu" ? nil : File.join(root, "lib", "#{name}.rb")
abort "Refusing to overwrite #{entrypoint}" if entrypoint && File.exist?(entrypoint)

begin
  File.write(entrypoint, "require \"vagrant-qemu\"\n") if entrypoint
  success = system(
    { "VAGRANT_QEMU_GEM_NAME" => name },
    "gem", "build", "vagrant-qemu.gemspec",
    chdir: root
  )
  abort "gem build failed" unless success
ensure
  File.delete(entrypoint) if entrypoint && File.exist?(entrypoint)
end
