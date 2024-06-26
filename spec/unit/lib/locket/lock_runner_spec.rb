require 'support/paths'
require 'locket/lock_runner'
require 'rspec/wait'

RSpec.describe Locket::LockRunner do
  let(:locket_service) { instance_double(Models::Locket::Stub) }
  let(:key) { 'lock-key' }
  let(:owner) { 'lock-owner' }
  let(:host) { 'locket.capi.land' }
  let(:port) { '1234' }
  let(:client_ca_path) { File.join(Paths::FIXTURES, 'certs/bbs_ca.crt') }
  let(:client_cert_path) { File.join(Paths::FIXTURES, 'certs/bbs_client.crt') }
  let(:client_key_path) { File.join(Paths::FIXTURES, 'certs/bbs_client.key') }
  let(:credentials) { instance_double(GRPC::Core::ChannelCredentials) }
  let(:lock_request) do
    Models::LockRequest.new(
      {
        resource: { key: key, owner: owner, type_code: Models::TypeCode::LOCK },
        ttl_in_seconds: 15
      }
    )
  end

  let(:client) do
    Locket::LockRunner.new(
      key:,
      owner:,
      host:,
      port:,
      client_ca_path:,
      client_key_path:,
      client_cert_path:
    )
  end

  before do
    client_ca = File.read(client_ca_path)
    client_key = File.read(client_key_path)
    client_cert = File.read(client_cert_path)

    allow(GRPC::Core::ChannelCredentials).to receive(:new).
      with(client_ca, client_key, client_cert).
      and_return(credentials)

    allow(Models::Locket::Stub).to receive(:new).
      with("#{host}:#{port}", credentials).
      and_return(locket_service)

    allow(client).to receive(:sleep)
  end

  after do
    client.stop
  end

  describe '#start' do
    it 'continuously attempts to re-acquire the lock' do
      call_count = 0
      allow(locket_service).to receive(:lock) { call_count += 1 }

      client.start

      wait_for { call_count }.to be >= 3

      expect(locket_service).to have_received(:lock).with(lock_request).at_least(3).times
    end

    it 'raises an error when restarted after it has already been started' do
      allow(locket_service).to receive(:lock)

      client.start

      expect do
        client.start
      end.to raise_error(Locket::LockRunner::Error, 'Cannot start more than once')
    end
  end

  describe '#lock_acquired?' do
    context 'initialization' do
      it 'does not report that it has a lock before start is called' do
        expect(client.lock_acquired?).to be(false)
      end
    end

    context 'when attempting to acquire a lock' do
      let(:fake_logger) { instance_double(Steno::Logger, info: nil) }

      before do
        allow(Steno).to receive(:logger).and_return(fake_logger)
      end

      context 'when it does not acquire a lock' do
        it 'reports it does not have the lock exactly once' do
          error = GRPC::Unknown.new
          call_count = 0
          allow(locket_service).to receive(:lock) { call_count += 1 }.and_raise(error)

          client.start

          wait_for { call_count }.to be >= 3

          expect(locket_service).to have_received(:lock).with(lock_request).at_least(3).times
          expect(client.lock_acquired?).to be(false)
          expect(fake_logger).to have_received(:info).with("Failed to acquire lock '#{key}' for owner '#{owner}': #{error.message}").exactly(:once)
        end
      end

      context 'when it does acquire a lock' do
        it 'reports that it has a lock exactly once' do
          call_count = 0
          allow(locket_service).to receive(:lock) { call_count += 1 }

          client.start

          wait_for { call_count }.to be >= 3

          expect(locket_service).to have_received(:lock).with(lock_request).at_least(3).times
          expect(client.lock_acquired?).to be(true)
          expect(fake_logger).to have_received(:info).with("Acquired lock '#{key}' for owner '#{owner}'").exactly(:once)
        end
      end
    end
  end
end
