require "spec_helper"
require "timeout"
require "socket"

describe "open issue regressions" do
  let(:app) { double("app", call: nil) }

  describe "direct SSH with the default NIC disabled (#71)" do
    it "does not add a synthetic SSH forwarding rule" do
      ctx = mock_vagrant_env(provider_config_overrides: { net_device: nil, ssh_port: 22, ssh_auto_correct: true })
      VagrantPlugins::QEMU::Action::PrepareForwardedPortCollisionParams.new(app, ctx[:env]).call(ctx[:env])
      expect(ctx[:vm_config]).not_to have_received(:network)
      expect(app).to have_received(:call).with(ctx[:env])
    end

    it "disables an inherited SSH forward without changing user forwards" do
      ssh = { id: "ssh", host: 2222, guest: 22 }
      web = { guest: 80, host: 8080 }
      ctx = mock_vagrant_env(provider_config_overrides: { net_device: nil },
        networks: [[:forwarded_port, ssh], [:forwarded_port, web]])
      VagrantPlugins::QEMU::Action::PrepareForwardedPortCollisionParams.new(app, ctx[:env]).call(ctx[:env])
      expect(ssh[:disabled]).to eq true
      expect(web).to eq(guest: 80, host: 8080)
    end

    it "ignores an inherited corrected SSH port when there is no provider NIC" do
      ctx = mock_vagrant_env(provider_config_overrides: { net_device: nil, ssh_port: 22 },
        networks: [[:forwarded_port, { id: "ssh", host: 2200, guest: 22 }]])
      options = nil
      allow(ctx[:driver]).to receive(:start) { |opts| options = opts }
      VagrantPlugins::QEMU::Action::StartInstance.new(app, ctx[:env]).call(ctx[:env])
      expect(options[:ssh_port]).to eq 22
    end
  end

  describe "firmware paths during macOS cross-architecture emulation (#59/#50)" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("QEMU_DIR").and_return(nil)
      allow(ENV).to receive(:[]).with("HOMEBREW_PREFIX").and_return(nil)
      allow(RbConfig::CONFIG).to receive(:[]).and_call_original
      allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("darwin")
    end

    { "aarch64" => ["x86_64", "/opt/homebrew/share/qemu"],
      "x86_64" => ["aarch64", "/usr/local/share/qemu"] }.each do |host, (guest, path)|
      it "uses the #{host} host's Homebrew installation for a #{guest} guest" do
        config = VagrantPlugins::QEMU::Config.new
        allow(config).to receive(:host_arch).and_return(host)
        config.arch = guest
        config.finalize!
        expect(config.qemu_dir).to eq path
        expect(config.machine).to include("accel=tcg")
        expect(config.cpu).to eq "max"
      end
    end
  end

  describe "primary disk selection (#66)" do
    around do |example|
      with_temp_dir do |dir|
        @driver = VagrantPlugins::QEMU::Driver.new("vm", dir.join("data"), dir.join("tmp"))
        FileUtils.mkdir_p(@driver.disk_dir)
        FileUtils.touch(@driver.disk_dir.join("linked-box.img"))
        example.run
      end
    end

    let(:machine) { double("machine", provider: double("provider", driver: @driver)) }
    let(:disk) do
      double("disk", type: :disk, name: "root", disk_ext: "qcow2", size: 107374182400,
        id: "root-id", primary: true, provider_config: nil)
    end

    before do
      allow(@driver).to receive(:execute).and_return('{"virtual-size":68719476736}')
    end

    it "grows the existing boot overlay instead of attaching a blank disk" do
      path = @driver.disk_dir.join("linked-box.img").to_s
      metadata = VagrantPlugins::QEMU::Cap::Disk.configure_disks(machine, [disk])
      expect(@driver).to have_received(:execute).with("qemu-img", "resize", path, "107374182400")
      expect(metadata[:disk].first[:Path]).to eq path
      expect(@driver.attached_drives[:disk]).to be_empty
      expect(@driver).not_to have_received(:execute).with("qemu-img", "create", any_args)
    end

    it "does not resize a primary disk again when it is already large enough" do
      allow(@driver).to receive(:execute).and_return('{"virtual-size":107374182400}')
      VagrantPlugins::QEMU::Cap::Disk.configure_disks(machine, [disk])
      expect(@driver).not_to have_received(:execute).with("qemu-img", "resize", any_args)
      expect(@driver.attached_drives[:disk]).to be_empty
    end

    it "never shrinks the boot disk to a smaller requested size" do
      allow(disk).to receive(:size).and_return(1024)
      VagrantPlugins::QEMU::Cap::Disk.configure_disks(machine, [disk])
      expect(@driver).not_to have_received(:execute).with("qemu-img", "resize", any_args)
      expect(@driver).not_to have_received(:execute).with("qemu-img", "create", any_args)
    end
  end

  describe "shutdown with a monitor that keeps its connection open (#21)" do
    it "keeps the read side open for a bounded wait when the monitor does not reply" do
      with_temp_dir do |dir|
        driver = VagrantPlugins::QEMU::Driver.new("vm", dir, dir)
        server = TCPServer.new("127.0.0.1", 0)
        received = Queue.new
        release = Queue.new
        peer = nil
        worker = Thread.new do
          peer = server.accept
          received << peer.gets
          release.pop
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Timeout.timeout(2) do
          driver.send(:send_monitor, { control_port: server.addr[1], graceful_timeout: 1 }, "quit")
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(elapsed).to be >= 0.8
        expect(Timeout.timeout(2) { received.pop }).to eq "quit\n"
      ensure
        worker&.kill
        worker&.join
        peer&.close
        server&.close
      end
    end

    it "reaches the kill fallback without waiting for monitor EOF" do
      with_temp_dir do |dir|
        driver = VagrantPlugins::QEMU::Driver.new("vm", dir, dir)
        server = TCPServer.new("127.0.0.1", 0)
        clients = []
        received = Queue.new
        worker = Thread.new do
          loop do
            sock = server.accept
            clients << sock
            received << sock.gets
            # Leave the monitor open, as a stalled QEMU monitor can do.
          end
        end
        allow(driver).to receive(:running?).and_return(true)
        allow(driver).to receive(:force_kill)
        Timeout.timeout(2) { driver.stop(control_port: server.addr[1], graceful_timeout: 0) }
        expect(driver).to have_received(:force_kill)
        commands = Timeout.timeout(2) { [received.pop, received.pop] }
        expect(commands).to eq ["system_powerdown\n", "quit\n"]
      ensure
        worker&.kill
        worker&.join
        clients&.each { |sock| sock.close rescue nil }
        server&.close
      end
    end
  end
end
