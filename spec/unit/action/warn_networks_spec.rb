require "spec_helper"

describe VagrantPlugins::QEMU::Action::WarnNetworks do
  let(:app) { double("app", call: nil) }

  it "does nothing when no private_network configured" do
    ctx = mock_vagrant_env(networks: [
      [:forwarded_port, { guest: 80, host: 8080 }]
    ])
    action = described_class.new(app, ctx[:env])
    action.call(ctx[:env])

    expect(ctx[:ui]).not_to have_received(:warn)
    expect(ctx[:ui]).not_to have_received(:info)
  end

  it "warns when private_network configured but advanced_network=false" do
    ctx = mock_vagrant_env(
      provider_config_overrides: { advanced_network: false },
      networks: [[:private_network, { ip: "192.168.105.10" }]]
    )
    action = described_class.new(app, ctx[:env])
    action.call(ctx[:env])

    expect(ctx[:ui]).to have_received(:warn)
  end

  it "names only unsupported networks when forwarding is also configured" do
    I18n.backend.load_translations(VagrantPlugins::QEMU.source_root.join("locales/en.yml"))
    ctx = mock_vagrant_env(networks: [
      [:forwarded_port, { guest: 80, host: 8080 }],
      [:public_network, {}]
    ])
    action = described_class.new(app, ctx[:env])
    action.call(ctx[:env])

    expect(ctx[:ui]).to have_received(:warn).with(
      "Warning! The QEMU provider does not support these network types: public_network.\n" \
      "Only these declarations will be ignored. Forwarded ports remain enabled."
    )
  end

  it "outputs info when private_network configured and advanced_network=true" do
    ctx = mock_vagrant_env(
      provider_config_overrides: { advanced_network: true },
      networks: [[:private_network, { ip: "192.168.105.10" }]]
    )
    action = described_class.new(app, ctx[:env])
    action.call(ctx[:env])

    expect(ctx[:ui]).to have_received(:info)
  end
end
