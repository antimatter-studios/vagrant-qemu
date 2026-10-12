require "spec_helper"
require "vagrant-qemu/synced_folder_virtiofs"

describe "VirtioFS with the pending #89 recovery" do
  it "stops a real share daemon after the actual StartInstance recovery stops QEMU" do
    with_temp_dir do |dir|
      ctx = mock_vagrant_env(provider_config_overrides: { memory: "256M", control_port: 33333, virtiofsd_bin: RbConfig.ruby })
      allow(ctx[:machine]).to receive(:data_dir).and_return(dir)
      allow(ctx[:machine]).to receive(:ui).and_return(ctx[:ui])
      allow(ctx[:ui]).to receive(:error)
      running = false
      allow(ctx[:driver]).to receive(:running?) { running }
      allow(ctx[:driver]).to receive(:start) { running = true }
      expect(ctx[:driver]).to receive(:stop).with(control_port: 33333, graceful_timeout: 10, quit_only: true) { running = false }
      pid = nil
      prepare = lambda do |_env|
        socket = dir.join("owned.sock").to_s
        pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", "--", "--socket-path=#{socket}")
        runtime = dir.join("virtiofs")
        FileUtils.mkdir_p(runtime)
        File.write(runtime.join("virtiofs0.pid"), pid.to_s)
        File.write(runtime.join("virtiofs0.sock_path"), socket)
        identity = VagrantPlugins::QEMU::SyncedFolderVirtioFS.new.send(:process_identity, pid)
        File.write(runtime.join("virtiofs0.process.json"), JSON.generate("identity" => identity, "binary" => RbConfig.ruby))
        File.write(runtime.join("mounts.json"), '{}')
        File.write(runtime.join("virtiofs0.log"), 'kept daemon diagnostic')
        ctx[:config].virtiofs_qemu_args = ["-device", "vhost-user-fs-pci"]
      end
      error = Vagrant::Errors::VMBootTimeout.new
      actions = [VagrantPlugins::QEMU::Action::ResetVirtioFSArgs, prepare,
        VagrantPlugins::QEMU::Action::StartInstance, ->(_) { raise error }]
      warden = Vagrant::Action::Warden.new(actions, ctx[:env])
      expect { warden.call(ctx[:env]) }.to raise_error(error)
      Process.wait(pid)
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      expect(dir.join("virtiofs/mounts.json")).not_to exist
      expect(File.read(dir.join("virtiofs/virtiofs0.log"))).to eq('kept daemon diagnostic')
      expect(ctx[:env]["vagrant.error"]).to equal(error)
      expect(ctx[:config].virtiofs_qemu_args).to be_empty
    ensure
      Process.kill("TERM", pid) rescue Errno::ESRCH if pid
      Process.wait(pid) rescue Errno::ECHILD if pid
    end
  end
end
