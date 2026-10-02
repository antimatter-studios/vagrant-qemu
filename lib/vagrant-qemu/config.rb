require "json"
require "rbconfig"
require "vagrant"

module VagrantPlugins
  module QEMU
    class Config < Vagrant.plugin("2", :config)
      attr_accessor :ssh_host
      attr_accessor :ssh_port
      attr_accessor :ssh_auto_correct
      attr_accessor :arch
      attr_accessor :machine
      attr_accessor :cpu
      attr_accessor :smp
      attr_accessor :memory
      attr_accessor :net_device
      attr_accessor :drive_interface
      attr_accessor :image_path
      attr_accessor :qemu_bin
      attr_accessor :qemu_dir
      attr_accessor :virtiofsd_bin
      attr_accessor :virtiofs_guest_uid
      attr_accessor :virtiofs_guest_gid
      attr_accessor :extra_virtiofsd_args
      attr_accessor :virtiofs_qemu_args
      attr_accessor :disk_resize
      attr_accessor :extra_qemu_args
      attr_accessor :extra_netdev_args
      attr_accessor :extra_drive_args
      attr_accessor :control_port
      attr_accessor :debug_port
      attr_accessor :no_daemonize
      attr_accessor :firmware_format
      attr_accessor :other_default
      attr_accessor :extra_image_opts

      # Path to the gem-level config file
      GEM_CONFIG_FILE = File.join(File.dirname(__FILE__), "..", "..", "config.json")

      def initialize
        @ssh_host = UNSET_VALUE
        @ssh_port = UNSET_VALUE
        @ssh_auto_correct = UNSET_VALUE
        @arch = UNSET_VALUE
        @machine = UNSET_VALUE
        @cpu = UNSET_VALUE
        @smp = UNSET_VALUE
        @memory = UNSET_VALUE
        @net_device = UNSET_VALUE
        @drive_interface = UNSET_VALUE
        @image_path = UNSET_VALUE
        @qemu_bin = UNSET_VALUE
        @qemu_dir = UNSET_VALUE
        @virtiofsd_bin = UNSET_VALUE
        @virtiofs_guest_uid = UNSET_VALUE
        @virtiofs_guest_gid = UNSET_VALUE
        @extra_virtiofsd_args = UNSET_VALUE
        @virtiofs_qemu_args = []
        @disk_resize = UNSET_VALUE
        @extra_qemu_args = UNSET_VALUE
        @extra_netdev_args = UNSET_VALUE
        @extra_drive_args = UNSET_VALUE
        @control_port = UNSET_VALUE
        @debug_port = UNSET_VALUE
        @no_daemonize = UNSET_VALUE
        @firmware_format = UNSET_VALUE
        @other_default = UNSET_VALUE
        @extra_image_opts = UNSET_VALUE
      end

      #-------------------------------------------------------------------
      # Internal methods.
      #-------------------------------------------------------------------

      def merge(other)
        super.tap do |result|
          # Merge extra_qemu_args from both configs instead of overwriting
          if other.extra_qemu_args != UNSET_VALUE && @extra_qemu_args != UNSET_VALUE
            result.extra_qemu_args = @extra_qemu_args + other.extra_qemu_args
          end
        end
      end

      def finalize!
        # Load gem-level config file defaults
        gem_config = load_gem_config

        @ssh_host = "127.0.0.1" if @ssh_host == UNSET_VALUE
        @ssh_port = 50022 if @ssh_port == UNSET_VALUE
        @ssh_auto_correct = false if @ssh_auto_correct == UNSET_VALUE
        @arch = host_arch if @arch == UNSET_VALUE
        native = @arch == host_arch
        base_machine = @arch == "aarch64" ? "virt,highmem=on" : "q35"
        accelerator = native ? (RUBY_PLATFORM.include?("darwin") ? "hvf" : "kvm") : "tcg"
        @machine = "#{base_machine},accel=#{accelerator}" if @machine == UNSET_VALUE
        @cpu = native ? "host" : "max" if @cpu == UNSET_VALUE
        @smp = "2" if @smp == UNSET_VALUE
        @memory = "4G" if @memory == UNSET_VALUE
        @net_device = @arch == "aarch64" ? "virtio-net-device" : "virtio-net-pci" if @net_device == UNSET_VALUE
        @drive_interface = "virtio" if @drive_interface == UNSET_VALUE
        @image_path = nil if @image_path == UNSET_VALUE
        @qemu_bin = resolve_binary(gem_config["qemu_bin"], "qemu") if @qemu_bin == UNSET_VALUE
        # TODO: I am not happy that we hardcode this qemu_dir fallback value, I think maybe there is a better option
        if @qemu_dir == UNSET_VALUE
          default_qemu_dir = RUBY_PLATFORM.include?("darwin") ? "/opt/homebrew/share/qemu" : "/usr/share/qemu"
          @qemu_dir = resolve_directory(gem_config["qemu_dir"], default_qemu_dir)
        end
        @virtiofsd_bin = resolve_binary(gem_config["virtiofsd_bin"], "virtiofsd") if @virtiofsd_bin == UNSET_VALUE
        @virtiofs_guest_uid = 1000 if @virtiofs_guest_uid == UNSET_VALUE
        @virtiofs_guest_gid = 1000 if @virtiofs_guest_gid == UNSET_VALUE
        @extra_virtiofsd_args = [] if @extra_virtiofsd_args == UNSET_VALUE
        @disk_resize = nil if @disk_resize == UNSET_VALUE
        @extra_qemu_args = [] if @extra_qemu_args == UNSET_VALUE
        @extra_netdev_args = nil if @extra_netdev_args == UNSET_VALUE
        @extra_drive_args = nil if @extra_drive_args == UNSET_VALUE
        @control_port = nil if @control_port == UNSET_VALUE
        @debug_port = nil if @debug_port == UNSET_VALUE
        @no_daemonize = false if @no_daemonize == UNSET_VALUE
        @firmware_format = "raw" if @firmware_format == UNSET_VALUE
        @other_default = %W(-parallel null -monitor none -display none -vga none) if @other_default == UNSET_VALUE
        @extra_image_opts = nil if @extra_image_opts == UNSET_VALUE

        # TODO better error msg
        @ssh_port = Integer(@ssh_port)
      end

      def validate(machine)
        # errors = _detected_errors
        errors = []
        { "QEMU Provider" => errors }
      end

      private

      def host_arch
        RbConfig::CONFIG["host_cpu"] =~ /arm|aarch64/ ? "aarch64" : "x86_64"
      end

      def load_gem_config
        config_path = File.expand_path(GEM_CONFIG_FILE)
        return {} unless File.exist?(config_path)

        JSON.parse(File.read(config_path))
      rescue JSON::ParserError
        {}
      end

      VIRTIOFSD_SEARCH_PATHS = %w(
        /opt/homebrew/bin/virtiofsd
        /usr/local/bin/virtiofsd
        /usr/libexec/virtiofsd
        /usr/lib/virtiofsd
        /usr/lib/qemu/virtiofsd
      ).freeze

      def resolve_binary(config_path, fallback_name)
        if config_path && !config_path.empty?
          return config_path if File.executable?(config_path)
        end

        if fallback_name
          path = `which #{fallback_name} 2>/dev/null`.strip
          return path unless path.empty?

          # Check known paths for virtiofsd
          if fallback_name == "virtiofsd"
            VIRTIOFSD_SEARCH_PATHS.each do |p|
              return p if File.executable?(p)
            end
          end
        end

        nil
      end

      def resolve_directory(config_path, default_path)
        if config_path && !config_path.empty? && Dir.exist?(config_path)
          return config_path
        end

        default_path
      end
    end
  end
end
