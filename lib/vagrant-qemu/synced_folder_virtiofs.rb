require "fileutils"
require "log4r"
require "open3"
require "shellwords"
require "tmpdir"

module VagrantPlugins
  module QEMU
    class SyncedFolderVirtioFS < Vagrant.plugin("2", :synced_folder)

      def usable?(machine, raise_error = false)
        return false unless machine.provider_name == :qemu

        if machine.provider_config.virtiofsd_bin.nil?
          if raise_error
            raise Errors::VirtiofsdNotFound
          end
          return false
        end

        true
      end

      def prepare(machine, folders, opts)
        @logger = Log4r::Logger.new("vagrant_qemu::synced_folder_virtiofs")

        # Use /tmp for socket files — Unix domain sockets have a 104-byte path limit
        # on macOS, and Vagrant data_dir paths are often too long.
        # PID files and logs stay in the data dir for persistence.
        virtiofs_dir = machine.data_dir.join("virtiofs")
        FileUtils.mkdir_p(virtiofs_dir)
        socket_dir = Dir.tmpdir
        virtiofsd = machine.provider_config.virtiofsd_bin
        memory = machine.provider_config.memory

        if RUBY_PLATFORM.include?("linux")
          # Linux can export an anonymous shared memory object to virtiofsd.
          # This avoids a large temporary file and is the recommended QEMU
          # backend for vhost-user devices on Linux.
          extra_args = %W(
            -object memory-backend-memfd,id=mem,size=#{memory},share=on
            -numa node,memdev=mem
          )
        else
          # macOS QEMU needs a file-backed shared memory object.
          mem_path = File.join(Dir.tmpdir, "vagrant-qemu-#{machine.id}-mem")
          extra_args = %W(
            -object memory-backend-file,id=mem,size=#{memory},mem-path=#{mem_path},share=on
            -numa node,memdev=mem
          )
        end

        virtiofsd_help = virtiofsd_help_text(virtiofsd)

        sorted_folders = folders.sort_by { |_id, opts| opts[:guestpath] }
        sorted_folders.each_with_index do |(_id, folder_opts), i|
          hostpath = File.expand_path(folder_opts[:hostpath])
          tag = "virtiofs#{i}"
          socket_id = "vqemu-#{machine.id}-#{tag}"
          socket_path = File.join(socket_dir, "#{socket_id}.sock")
          pid_file = virtiofs_dir.join("#{tag}.pid").to_s

          # Clean up any stale virtiofsd from a previous run
          cleanup_virtiofsd(pid_file, socket_path)

          # Start virtiofsd
          log_file = virtiofs_dir.join("#{tag}.log").to_s
          host_uid = Process.uid
          host_gid = Process.gid
          virtiofsd_args = [virtiofsd, "--socket-path=#{socket_path}"]

          # Current standalone virtiofsd uses --shared-dir, while the older
          # QEMU packaged daemon uses the -o source= form.
          if virtiofsd_help.include?("--shared-dir")
            virtiofsd_args << "--shared-dir=#{hostpath}"
          else
            virtiofsd_args += ["-o", "source=#{hostpath}"]
          end

          if virtiofsd_help.include?("--sandbox")
            virtiofsd_args << "--sandbox=none"
          elsif virtiofsd_help.match?(/(?:^|[\s,])sandbox(?:[=\s,]|$)/)
            virtiofsd_args += ["-o", "sandbox=none"]
          end

          virtiofsd_args << "--inode-file-handles=never" if virtiofsd_help.include?("--inode-file-handles")

          # Add UID/GID mapping if virtiofsd supports it (v1.13+)
          translate_supported = virtiofsd_help.include?("--translate-uid")
          if translate_supported
            virtiofsd_args += [
              "--translate-uid", "map:#{machine.provider_config.virtiofs_guest_uid}:#{host_uid}:1",
              "--translate-gid", "map:#{machine.provider_config.virtiofs_guest_gid}:#{host_gid}:1",
            ]
          end
          # Append user-supplied extra virtiofsd args from provider config
          extra_vfs = machine.provider_config.extra_virtiofsd_args
          virtiofsd_args += extra_vfs if extra_vfs.is_a?(Array) && !extra_vfs.empty?
          # Keep the daemon outside Vagrant's process group so it survives
          # after `vagrant up` exits and continues serving mounted folders.
          pid = spawn(*virtiofsd_args, in: File::NULL, [:out, :err] => [log_file, "w"], pgroup: true)
          waiter = Process.detach(pid)

          # The path can appear before the daemon starts listening.
          30.times do
            break if File.socket?(socket_path)
            sleep 0.1
          end

          sleep 0.2 if File.socket?(socket_path)

          alive = process_alive?(pid)
          unless File.socket?(socket_path) && alive
            status = waiter.value unless alive
            log = File.read(log_file)
            machine.ui.error("virtiofsd pid #{pid} exited with #{status.inspect}") if status
            machine.ui.error("virtiofsd log (#{log_file}):\n#{log.empty? ? '(empty)' : log}")
            Process.kill("TERM", pid) rescue nil
            raise Errors::VirtiofsdStartFailed,
              hostpath: hostpath,
              log_file: log_file
          end

          File.write(pid_file, pid.to_s)
          # Store socket path alongside pid so cleanup can find it
          File.write(virtiofs_dir.join("#{tag}.sock_path").to_s, socket_path)
          machine.ui.info("virtiofsd started (pid #{pid}) sharing #{hostpath}")

          extra_args += %W(
            -chardev socket,id=char_#{tag},path=#{socket_path}
            -device vhost-user-fs-pci,chardev=char_#{tag},tag=#{tag}
          )
        end

        machine.provider_config.virtiofs_qemu_args = extra_args
      end

      def enable(machine, folders, opts)
        # Mounting happens in MountVirtioFS action after boot,
        # since the guest isn't available when SyncedFolders runs.
      end

      def disable(machine, folders, opts)
        folders.each do |_id, folder_opts|
          guestpath = folder_opts[:guestpath]
          machine.communicate.sudo("umount #{Shellwords.escape(guestpath)} 2>/dev/null || true")
        end
      end

      def cleanup(machine, opts)
        virtiofs_dir = machine.data_dir.join("virtiofs")
        return unless virtiofs_dir.directory?

        Dir.glob(virtiofs_dir.join("*.pid").to_s).each do |pid_file|
          sock_path_file = pid_file.sub(/\.pid$/, ".sock_path")
          sock_file = File.exist?(sock_path_file) ? File.read(sock_path_file).strip : nil
          cleanup_virtiofsd(pid_file, sock_file)
          File.delete(sock_path_file) if File.exist?(sock_path_file)
        end

        FileUtils.rm_rf(virtiofs_dir)
        machine.ui.info("virtiofsd stopped") if machine.ui
      end

      private

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      def cleanup_virtiofsd(pid_file, socket_path)
        if File.exist?(pid_file)
          pid = File.read(pid_file).strip.to_i
          begin
            Process.kill("TERM", pid)
            5.times do
              begin
                Process.kill(0, pid)
                sleep 0.5
              rescue Errno::ESRCH
                break
              end
            end
            Process.kill("KILL", pid) rescue nil
          rescue Errno::ESRCH
            # Already dead
          end
          File.delete(pid_file) rescue nil
        end
        File.delete(socket_path) if socket_path && File.exist?(socket_path)
      end

      def virtiofsd_help_text(binary)
        output, status = Open3.capture2e(binary, "--help")
        status.success? ? output : ""
      rescue Errno::ENOENT, Errno::EACCES
        ""
      end
    end
  end
end
