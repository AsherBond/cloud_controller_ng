require 'spec_helper'

module VCAP::CloudController
  RSpec.describe SystemEnvPresenter do
    subject(:system_env_presenter) { SystemEnvPresenter.new(app) }

    shared_examples 'k8s service bindings' do
      context 'when k8s service bindings are enabled' do
        before do
          app.update(service_binding_k8s_enabled: true)
        end

        it 'does not contain vcap_services' do
          expect(system_env_presenter.system_env).not_to have_key(:VCAP_SERVICES)
        end

        it 'contains service_binding_root' do
          expect(system_env_presenter.system_env[:SERVICE_BINDING_ROOT]).to eq('/etc/cf-service-bindings')
        end
      end
    end

    shared_examples 'file-based VCAP service bindings' do
      context 'when file-based VCAP service bindings are enabled' do
        before do
          app.update(file_based_vcap_services_enabled: true)
        end

        it 'does not contain vcap_services' do
          expect(system_env_presenter.system_env).not_to have_key(:VCAP_SERVICES)
        end

        it 'contains service_binding_root' do
          expect(system_env_presenter.system_env[:VCAP_SERVICES_FILE_PATH]).to eq('/etc/cf-service-bindings/vcap_services')
        end
      end
    end

    describe '#system_env' do
      context 'when there are no services' do
        let(:app) { AppModel.make(environment_variables: { 'jesse' => 'awesome' }) }

        it 'contains an empty vcap_services' do
          expect(system_env_presenter.system_env[:VCAP_SERVICES]).to eq({})
        end

        include_examples 'k8s service bindings'
        include_examples 'file-based VCAP service bindings'
      end

      context 'when there are services' do
        let(:space) { Space.make }
        let(:app) { AppModel.make(environment_variables: { 'jesse' => 'awesome' }, space: space) }
        let(:service) { Service.make(label: 'elephantsql-n/a') }
        let(:service_alt) { Service.make(label: 'giraffesql-n/a') }
        let(:service_plan) { ServicePlan.make(service:) }
        let(:service_plan_alt) { ServicePlan.make(service: service_alt) }
        let(:service_instance) { ManagedServiceInstance.make(space: space, service_plan: service_plan, name: 'elephantsql-vip-uat', tags: ['excellent']) }
        let(:service_instance_same_label) { ManagedServiceInstance.make(space: space, service_plan: service_plan, name: 'elephantsql-2') }
        let(:service_instance_diff_label) { ManagedServiceInstance.make(space: space, service_plan: service_plan_alt, name: 'giraffesql-vip-uat') }
        let!(:service_binding) { ServiceBinding.make(app: app, service_instance: service_instance, syslog_drain_url: 'logs.go-here.com') }

        it 'contains a populated vcap_services' do
          expect(system_env_presenter.system_env[:VCAP_SERVICES]).not_to eq({})
          expect(system_env_presenter.system_env[:VCAP_SERVICES]).to have_key(service.label.to_sym)
          expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym]).to have(1).services
        end

        it 'includes service binding and instance information' do
          expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym]).to have(1).items
          binding = system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym].first.to_hash

          expect(binding[:credentials]).to eq(service_binding.credentials)
          expect(binding[:name]).to eq('elephantsql-vip-uat')
        end

        context 'when a create service binding is in progress' do
          let(:service_binding_operation) { ServiceBindingOperation.make(type: 'create', state: 'in progress') }
          let!(:service_binding) { ServiceBinding.make(app:, service_instance:) }

          before do
            service_binding.service_binding_operation = service_binding_operation
          end

          it 'does not include service binding and instance information' do
            expect(system_env_presenter.system_env[:VCAP_SERVICES]).to be_empty
          end
        end

        context 'when a service binding has successfully been asynchronously created' do
          let(:service_binding_operation) { ServiceBindingOperation.make(state: 'succeeded') }
          let!(:service_binding) { ServiceBinding.make(app:, service_instance:) }

          before do
            service_binding.service_binding_operation = service_binding_operation
          end

          it 'includes service binding and instance information' do
            expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym]).to have(1).items
            binding = system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym].first.to_hash

            expect(binding[:credentials]).to eq(service_binding.credentials)
            expect(binding[:name]).to eq('elephantsql-vip-uat')
          end
        end

        context 'when a delete service binding is in progress' do
          let(:service_binding_operation) { ServiceBindingOperation.make(type: 'delete', state: 'in progress') }
          let!(:service_binding) { ServiceBinding.make(app:, service_instance:) }

          before do
            service_binding.service_binding_operation = service_binding_operation
          end

          it 'does not include service binding and instance information' do
            expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym]).to be_nil
          end
        end

        context 'when a delete service binding failed' do
          let(:service_binding_operation) { ServiceBindingOperation.make(type: 'delete', state: 'failed') }
          let!(:service_binding) { ServiceBinding.make(app:, service_instance:) }

          before do
            service_binding.service_binding_operation = service_binding_operation
          end

          it 'does not include service binding and instance information' do
            expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym]).to be_nil
          end
        end

        describe 'volume mounts' do
          context 'when the service binding has volume mounts' do
            let!(:service_binding) do
              ServiceBinding.make(
                app: app,
                service_instance: service_instance,
                syslog_drain_url: 'logs.go-here.com',
                volume_mounts: [{
                  container_dir: '/data/images',
                  mode: 'r',
                  device_type: 'shared',
                  device: {
                    driver: 'cephfs',
                    volume_id: 'abc',
                    mount_config: {
                      key: 'value'
                    }
                  }
                }]
              )
            end

            it 'includes only the public volume information' do
              expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym][0].to_hash[:volume_mounts]).to eq([{ 'container_dir' => '/data/images',
                                                                                                                                'mode' => 'r',
                                                                                                                                'device_type' => 'shared' }])
            end
          end

          context 'when the service binding has no volume mounts' do
            it 'is an empty array' do
              expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym][0].to_hash[:volume_mounts]).to eq([])
            end
          end
        end

        context 'when the service is user-provided' do
          let(:service_instance) { UserProvidedServiceInstance.make(space: space, name: 'elephantsql-vip-uat') }

          it 'includes service binding and instance information' do
            expect(system_env_presenter.system_env[:VCAP_SERVICES][:'user-provided']).to have(1).items
            binding = system_env_presenter.system_env[:VCAP_SERVICES][:'user-provided'].first.to_hash
            expect(binding[:credentials]).to eq(service_binding.credentials)
            expect(binding[:name]).to eq('elephantsql-vip-uat')
          end
        end

        describe 'grouping' do
          before do
            ServiceBinding.make(app: app, service_instance: service_instance_same_label)
            ServiceBinding.make(app: app, service_instance: service_instance_diff_label)
          end

          it 'groups services by label' do
            expect(system_env_presenter.system_env[:VCAP_SERVICES]).to have(2).groups
            expect(system_env_presenter.system_env[:VCAP_SERVICES][service.label.to_sym]).to have(2).services
            expect(system_env_presenter.system_env[:VCAP_SERVICES][service_alt.label.to_sym]).to have(1).service
          end
        end

        include_examples 'k8s service bindings'
        include_examples 'file-based VCAP service bindings'
      end
    end
  end
end
