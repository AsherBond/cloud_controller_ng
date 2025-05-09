require 'spec_helper'

module VCAP::CloudController
  module Diego
    RSpec.describe TaskRecipeBuilder do
      subject(:task_recipe_builder) { TaskRecipeBuilder.new }
      let(:org) { Organization.make(name: 'MyOrg', guid: 'org-guid') }
      let(:space) { Space.make(name: 'MySpace', guid: 'space-guid', organization: org) }
      let(:app) { AppModel.make(name: 'MyApp', guid: 'banana-guid', space: space) }

      describe '#build_staging_task' do
        let(:staging_details) do
          Diego::StagingDetails.new.tap do |details|
            details.staging_guid = droplet.guid
            details.package = package
            details.environment_variables = [::Diego::Bbs::Models::EnvironmentVariable.new(name: 'nightshade_fruit', value: 'potato')]
            details.staging_memory_in_mb  = 42
            details.staging_disk_in_mb    = 51
            details.staging_log_rate_limit_bytes_per_second = 67
            details.start_after_staging   = true
            details.lifecycle             = lifecycle
            details.isolation_segment     = isolation_segment
          end
        end
        let(:lifecycle) do
          LifecycleProvider.provide(package, staging_message)
        end
        let(:staging_message) { BuildCreateMessage.new(lifecycle: { data: request_data, type: lifecycle_type }) }
        let(:request_data) do
          {
            stack: 'cool-stack'
          }
        end
        let(:package) { PackageModel.make(app:) }
        let(:expected_network) do
          ::Diego::Bbs::Models::Network.new(
            properties: {
              'policy_group_id' => app.guid,
              'app_id' => app.guid,
              'space_id' => app.space.guid,
              'org_id' => app.organization.guid,
              'ports' => '',
              'container_workload' => Protocol::ContainerNetworkInfo::STAGING
            }
          )
        end
        let(:config) do
          Config.new({
                       tls_port: tls_port,
                       internal_service_hostname: internal_service_hostname,
                       staging: {
                         timeout_in_seconds: 90
                       },
                       diego: {
                         use_privileged_containers_for_staging: false,
                         stager_url: 'http://stager.example.com',
                         pid_limit: 100
                       }
                     })
        end
        let(:isolation_segment) { 'potato-segment' }
        let(:internal_service_hostname) { 'internal.awesome.sauce' }
        let(:tls_port) { '7773' }
        let(:rule_dns_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol: 'udp',
            destinations: ['0.0.0.0/0'],
            ports: [53],
            annotations: ['security_group_id:guid1']
          )
        end
        let(:rule_http_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol: 'tcp',
            destinations: ['0.0.0.0/0'],
            ports: [80],
            log: true,
            annotations: ['security_group_id:guid2']
          )
        end
        let(:rule_staging_specific) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol: 'tcp',
            destinations: ['0.0.0.0/0'],
            ports: [443],
            log: true,
            annotations: ['security_group_id:guid3']
          )
        end
        let(:certificate_properties) do
          ::Diego::Bbs::Models::CertificateProperties.new(
            organizational_unit: [
              "organization:#{app.organization.guid}",
              "space:#{app.space.guid}",
              "app:#{app.guid}"
            ]
          )
        end
        let(:lifecycle_protocol) do
          instance_double(VCAP::CloudController::Diego::Buildpack::LifecycleProtocol,
                          staging_action_builder: lifecycle_action_builder)
        end

        before do
          SecurityGroup.make(guid: 'guid1',
                             rules: [{ 'protocol' => 'udp', 'ports' => '53', 'destination' => '0.0.0.0/0' }],
                             staging_default: true)
          SecurityGroup.make(guid: 'guid2',
                             rules: [{ 'protocol' => 'tcp', 'ports' => '80', 'destination' => '0.0.0.0/0', 'log' => true }],
                             staging_default: true)
          security_group = SecurityGroup.make(guid: 'guid3',
                                              rules: [{ 'protocol' => 'tcp', 'ports' => '443', 'destination' => '0.0.0.0/0', 'log' => true }],
                                              staging_default: false)
          security_group.add_staging_space(app.space)
          allow(LifecycleProtocol).to receive(:protocol_for_type).with(lifecycle_type).and_return(lifecycle_protocol)
        end

        context 'with a buildpack backend' do
          let(:droplet) { DropletModel.make(:buildpack, package:, app:) }

          let(:buildpack_staging_action) { ::Diego::Bbs::Models::RunAction.new }
          let(:lifecycle_environment_variables) { [::Diego::Bbs::Models::EnvironmentVariable.new(name: 'the-buildpack-env-var', value: 'the-buildpack-value')] }
          let(:lifecycle_cached_dependencies) { [::Diego::Bbs::Models::CachedDependency.new(name: 'buildpack_cached_deps')] }
          let(:lifecycle_image_layers) { [::Diego::Bbs::Models::ImageLayer.new(name: 'some-cache-key')] }
          let(:lifecycle_action_builder) do
            instance_double(
              Buildpack::StagingActionBuilder,
              stack: 'preloaded:potato-stack',
              action: buildpack_staging_action,
              task_environment_variables: lifecycle_environment_variables,
              cached_dependencies: lifecycle_cached_dependencies,
              image_layers: lifecycle_image_layers
            )
          end

          let(:lifecycle_type) { 'buildpack' }

          it 'constructs a TaskDefinition with staging instructions' do
            result = task_recipe_builder.build_staging_task(config, staging_details)

            expect(result.root_fs).to eq('preloaded:potato-stack')
            expect(result.log_guid).to eq('banana-guid')
            expect(result.metrics_guid).to eq('')
            expect(result.log_source).to eq('STG')
            expect(result.result_file).to eq('/tmp/result.json')
            expect(result.privileged).to be(false)
            expect(result.legacy_download_user).to eq('vcap')

            expect(result.memory_mb).to eq(42)
            expect(result.disk_mb).to eq(51)
            expect(result.log_rate_limit.bytes_per_second).to eq(67)
            expect(result.image_layers).to eq(lifecycle_image_layers)
            expect(result.cpu_weight).to eq(50)

            expect(result.metric_tags.keys.size).to eq(7)
            expect(result.metric_tags['source_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_id'].static).to eq('org-guid')
            expect(result.metric_tags['space_id'].static).to eq('space-guid')
            expect(result.metric_tags['app_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_name'].static).to eq('MyOrg')
            expect(result.metric_tags['space_name'].static).to eq('MySpace')
            expect(result.metric_tags['app_name'].static).to eq('MyApp')

            expect(result.completion_callback_url).to eq("https://#{internal_service_hostname}:#{tls_port}" \
                                                         "/internal/v3/staging/#{droplet.guid}/build_completed?start=#{staging_details.start_after_staging}")

            timeout_action = result.action.timeout_action
            expect(timeout_action).not_to be_nil
            expect(timeout_action.timeout_ms).to eq(90 * 1000)

            expect(timeout_action.action.run_action).to eq(buildpack_staging_action)

            expect(result.egress_rules).to contain_exactly(rule_dns_everywhere, rule_http_everywhere, rule_staging_specific)

            expect(result.image_layers).to eq(lifecycle_image_layers)
            expect(result.cached_dependencies).to eq(lifecycle_cached_dependencies)
            expect(result.placement_tags).to eq(['potato-segment'])
            expect(result.max_pids).to eq(100)
            expect(result.certificate_properties).to eq(certificate_properties)

            expect(result.volume_mounted_files).to be_empty
          end

          it 'gives the task a TrustedSystemCertificatesPath' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.trusted_system_certificates_path).to eq('/etc/cf-system-certificates')
          end

          it 'sets the env vars' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.environment_variables).to eq(lifecycle_environment_variables)
          end

          context 'when there is no isolation segment' do
            let(:isolation_segment) { nil }

            it 'sets PlacementTags to an empty array' do
              result = task_recipe_builder.build_staging_task(config, staging_details)

              expect(result.placement_tags).to eq([])
            end
          end

          context 'when k8s service bindings are enabled' do
            before do
              app = staging_details.package.app
              app.update(service_binding_k8s_enabled: true)
              VCAP::CloudController::ServiceBinding.make(service_instance: ManagedServiceInstance.make(space: app.space), app: app)
            end

            it 'includes volume mounted files' do
              result = task_recipe_builder.build_staging_task(config, staging_details)
              expect(result.volume_mounted_files.size).to be > 1
            end
          end

          context 'when file-based VCAP service bindings are enabled' do
            before do
              app = staging_details.package.app
              app.update(file_based_vcap_services_enabled: true)
              VCAP::CloudController::ServiceBinding.make(service_instance: ManagedServiceInstance.make(space: app.space), app: app)
            end

            it 'includes volume mounted files' do
              result = task_recipe_builder.build_staging_task(config, staging_details)
              expect(result.volume_mounted_files.size).to eq(1)
              expect(result.volume_mounted_files[0].path).to eq('vcap_services')
            end
          end
        end

        context 'with a docker backend' do
          let(:droplet) { DropletModel.make(:docker, package:, app:) }
          let(:package) do
            PackageModel.make(:docker,
                              app: app,
                              docker_username: 'dockeruser',
                              docker_password: 'dockerpass')
          end

          let(:docker_staging_action) { ::Diego::Bbs::Models::RunAction.new }
          let(:lifecycle_type) { 'docker' }
          let(:lifecycle_environment_variables) { [::Diego::Bbs::Models::EnvironmentVariable.new(name: 'the-docker-env-var', value: 'the-docker-value')] }
          let(:lifecycle_cached_dependencies) { [::Diego::Bbs::Models::CachedDependency.new(name: 'docker_cached_deps')] }
          let(:lifecycle_action_builder) do
            instance_double(
              Docker::StagingActionBuilder,
              stack: 'preloaded:docker-stack',
              action: docker_staging_action,
              task_environment_variables: lifecycle_environment_variables,
              cached_dependencies: lifecycle_cached_dependencies,
              image_layers: []
            )
          end

          before do
            allow(Docker::StagingActionBuilder).to receive(:new).and_return(lifecycle_action_builder)
          end

          it 'sets the log guid' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.log_guid).to eq('banana-guid')
          end

          it 'sets the log source' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.log_source).to eq('STG')
          end

          it 'sets the metric tags' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.metric_tags.keys.size).to eq(7)
            expect(result.metric_tags['source_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_id'].static).to eq('org-guid')
            expect(result.metric_tags['space_id'].static).to eq('space-guid')
            expect(result.metric_tags['app_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_name'].static).to eq('MyOrg')
            expect(result.metric_tags['space_name'].static).to eq('MySpace')
            expect(result.metric_tags['app_name'].static).to eq('MyApp')
          end

          it 'does not set the image layers' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.image_layers).to be_empty
          end

          it 'sets the result file' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.result_file).to eq('/tmp/result.json')
          end

          it 'sets privileged container to the config value' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.privileged).to be(false)
          end

          it 'sets the cached dependencies' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.cached_dependencies).to eq(lifecycle_cached_dependencies)
          end

          it 'sets the memory' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.memory_mb).to eq(42)
          end

          it 'sets the disk' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.disk_mb).to eq(51)
          end

          it 'sets the network information' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.network).to eq(expected_network)
          end

          it 'sets the egress rules' do
            result = task_recipe_builder.build_staging_task(config, staging_details)

            expect(result.egress_rules).to contain_exactly(rule_dns_everywhere, rule_http_everywhere, rule_staging_specific)
          end

          it 'sets the rootfs' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.root_fs).to eq('preloaded:docker-stack')
          end

          it 'sets the completion callback' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.completion_callback_url).to eq("https://#{internal_service_hostname}:#{tls_port}" \
                                                         "/internal/v3/staging/#{droplet.guid}/build_completed?start=#{staging_details.start_after_staging}")
          end

          it 'sets the trusted cert path' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.trusted_system_certificates_path).to eq('/etc/cf-system-certificates')
          end

          it 'sets the timeout and sets the run action' do
            result = task_recipe_builder.build_staging_task(config, staging_details)

            timeout_action = result.action.timeout_action
            expect(timeout_action).not_to be_nil
            expect(timeout_action.timeout_ms).to eq(90 * 1000)

            expect(timeout_action.action.run_action).to eq(docker_staging_action)
          end

          it 'sets the placement tags' do
            result = task_recipe_builder.build_staging_task(config, staging_details)

            expect(result.placement_tags).to eq(['potato-segment'])
          end

          it 'sets the max_pids' do
            result = task_recipe_builder.build_staging_task(config, staging_details)

            expect(result.max_pids).to eq(100)
          end

          it 'sets the certificate_properties' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.certificate_properties).to eq(certificate_properties)
          end

          it 'sets the docker credentials' do
            result = task_recipe_builder.build_staging_task(config, staging_details)
            expect(result.image_username).to eq('dockeruser')
            expect(result.image_password).to eq('dockerpass')
          end
        end
      end

      describe '#build_app_task' do
        let(:task) do
          TaskModel.create(
            name: 'potato-task',
            state: TaskModel::PENDING_STATE,
            droplet: droplet,
            command: 'bin/start',
            app: app,
            disk_in_mb: 1024,
            memory_in_mb: 2048,
            log_rate_limit: 3072,
            sequence_id: 9
          )
        end

        let(:expected_network) do
          ::Diego::Bbs::Models::Network.new(
            properties: {
              'policy_group_id' => app.guid,
              'app_id' => app.guid,
              'space_id' => app.space.guid,
              'org_id' => app.organization.guid,
              'ports' => '',
              'container_workload' => Protocol::ContainerNetworkInfo::TASK
            }
          )
        end

        let(:config) do
          Config.new({
                       tls_port: tls_port,
                       internal_service_hostname: internal_service_hostname,
                       diego: {
                         lifecycle_bundles: { 'buildpack/potato-stack': 'potato_lifecycle_bundle_url' },
                         pid_limit: 100,
                         use_privileged_containers_for_running: false
                       }
                     })
        end
        let(:isolation_segment) { 'potato-segment' }
        let(:internal_service_hostname) { 'internal.awesome.sauce' }
        let(:tls_port) { '7777' }
        let(:rule_dns_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol: 'udp',
            destinations: ['0.0.0.0/0'],
            ports: [53],
            annotations: ['security_group_id:guid1']
          )
        end
        let(:rule_http_everywhere) do
          ::Diego::Bbs::Models::SecurityGroupRule.new(
            protocol: 'tcp',
            destinations: ['0.0.0.0/0'],
            ports: [80],
            log: true,
            annotations: ['security_group_id:guid2']
          )
        end

        before do
          allow(VCAP::CloudController::IsolationSegmentSelector).to receive(:for_space).and_return(isolation_segment)

          SecurityGroup.make(guid: 'guid1', rules: [{ 'protocol' => 'udp', 'ports' => '53', 'destination' => '0.0.0.0/0' }], running_default: true)
          app.space.add_security_group(
            SecurityGroup.make(guid: 'guid2', rules: [{ 'protocol' => 'tcp', 'ports' => '80', 'destination' => '0.0.0.0/0', 'log' => true }])
          )
        end

        let(:task_action) { ::Diego::Bbs::Models::Action.new }
        let(:lifecycle_environment_variables) do
          [
            ::Diego::Bbs::Models::EnvironmentVariable.new(name: 'VCAP_APPLICATION', value: '{"greg":"pants"}'),
            ::Diego::Bbs::Models::EnvironmentVariable.new(name: 'MEMORY_LIMIT', value: '256m'),
            ::Diego::Bbs::Models::EnvironmentVariable.new(name: 'VCAP_SERVICES', value: '{}')
          ]
        end

        let(:lifecycle_cached_dependencies) do
          [::Diego::Bbs::Models::CachedDependency.new(
            from: 'http://file-server.service.cf.internal:8080/v1/static/potato_lifecycle_bundle_url',
            to: '/tmp/lifecycle',
            cache_key: 'buildpack-potato-stack-lifecycle'
          )]
        end

        let(:lifecycle_image_layers) { [::Diego::Bbs::Models::ImageLayer.new(name: 'some-layer')] }

        let(:certificate_properties) do
          ::Diego::Bbs::Models::CertificateProperties.new(
            organizational_unit: [
              "organization:#{task.app.organization.guid}",
              "space:#{task.app.space.guid}",
              "app:#{task.app.guid}"
            ]
          )
        end

        context 'with a buildpack backend' do
          let(:droplet) { DropletModel.make(:buildpack, app:) }

          let(:task_action_builder) do
            instance_double(
              Buildpack::TaskActionBuilder,
              action: task_action,
              task_environment_variables: lifecycle_environment_variables,
              stack: 'preloaded:potato-stack',
              cached_dependencies: lifecycle_cached_dependencies,
              image_layers: lifecycle_image_layers
            )
          end

          let(:lifecycle_protocol) do
            instance_double(VCAP::CloudController::Diego::Buildpack::LifecycleProtocol,
                            task_action_builder:)
          end

          before do
            allow(LifecycleProtocol).to receive(:protocol_for_type).with('buildpack').and_return(lifecycle_protocol)
            calculator = instance_double(TaskCpuWeightCalculator, calculate: 25)
            allow(TaskCpuWeightCalculator).to receive(:new).with(memory_in_mb: task.memory_in_mb).and_return(calculator)
          end

          it 'constructs a TaskDefinition with app task instructions' do
            result = task_recipe_builder.build_app_task(config, task)
            expected_callback_url = "https://#{internal_service_hostname}:#{tls_port}/internal/v4/tasks/#{task.guid}/completed"

            expect(result.log_guid).to eq(app.guid)
            expect(result.memory_mb).to eq(2048)
            expect(result.disk_mb).to eq(1024)
            expect(result.log_rate_limit.bytes_per_second).to eq(3072)
            expect(result.environment_variables).to eq(lifecycle_environment_variables)
            expect(result.legacy_download_user).to eq('vcap')
            expect(result.root_fs).to eq('preloaded:potato-stack')
            expect(result.completion_callback_url).to eq(expected_callback_url)
            expect(result.network).to eq(expected_network)
            expect(result.privileged).to be(false)
            expect(result.volume_mounts).to eq([])
            expect(result.egress_rules).to eq([
              rule_dns_everywhere,
              rule_http_everywhere
            ])
            expect(result.trusted_system_certificates_path).to eq('/etc/cf-system-certificates')
            expect(result.log_source).to eq(TASK_LOG_SOURCE)

            expect(result.action).to eq(task_action)
            expect(result.image_layers).to eq(lifecycle_image_layers)
            expect(result.cached_dependencies).to eq(lifecycle_cached_dependencies)

            expect(result.metrics_guid).to eq('')
            expect(result.cpu_weight).to eq(25)
            expect(result.placement_tags).to eq([isolation_segment])
            expect(result.max_pids).to eq(100)
            expect(result.certificate_properties).to eq(certificate_properties)

            expect(result.metric_tags.keys.size).to eq(7)
            expect(result.metric_tags['source_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_id'].static).to eq('org-guid')
            expect(result.metric_tags['space_id'].static).to eq('space-guid')
            expect(result.metric_tags['app_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_name'].static).to eq('MyOrg')
            expect(result.metric_tags['space_name'].static).to eq('MySpace')
            expect(result.metric_tags['app_name'].static).to eq('MyApp')

            expect(result.volume_mounted_files).to be_empty
          end

          context 'when a volume mount is provided' do
            let(:service_instance) { ManagedServiceInstance.make space: app.space }
            let(:multiple_volume_mounts) do
              [
                {
                  container_dir: '/data/images',
                  mode: 'r',
                  device_type: 'shared',
                  driver: 'cephfs',
                  device: {
                    volume_id: 'abc',
                    mount_config: {
                      key: 'value'
                    }
                  }
                },
                {
                  container_dir: '/data/scratch',
                  mode: 'rw',
                  device_type: 'shared',
                  driver: 'local',
                  device: {
                    volume_id: 'def',
                    mount_config: {}
                  }
                }
              ]
            end

            before do
              ServiceBinding.make(app: app, service_instance: service_instance, volume_mounts: multiple_volume_mounts)
            end

            it 'desires the mount' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.volume_mounts).to eq([
                ::Diego::Bbs::Models::VolumeMount.new(
                  driver: 'cephfs',
                  container_dir: '/data/images',
                  mode: 'r',
                  shared: ::Diego::Bbs::Models::SharedDevice.new(volume_id: 'abc', mount_config: { 'key' => 'value' }.to_json)
                ),
                ::Diego::Bbs::Models::VolumeMount.new(
                  driver: 'local',
                  container_dir: '/data/scratch',
                  mode: 'rw',
                  shared: ::Diego::Bbs::Models::SharedDevice.new(volume_id: 'def', mount_config: '')
                )
              ])
            end
          end

          describe 'privileged' do
            it 'is false when it is false in the config' do
              config.set(:diego, config.get(:diego).merge(use_privileged_containers_for_running: false))

              result = task_recipe_builder.build_app_task(config, task)
              expect(result.privileged).to be(false)
            end

            it 'is true when it is true in the config' do
              config.set(:diego, config.get(:diego).merge(use_privileged_containers_for_running: true))

              result = task_recipe_builder.build_app_task(config, task)
              expect(result.privileged).to be(true)
            end
          end

          context 'when isolation segment is not set' do
            let(:isolation_segment) { nil }

            it 'configures no placement tags' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.placement_tags).to eq([])
            end
          end

          context 'when k8s service bindings are enabled' do
            before do
              app = task.app
              app.update(service_binding_k8s_enabled: true)
              VCAP::CloudController::ServiceBinding.make(service_instance: ManagedServiceInstance.make(space: app.space), app: app)
            end

            it 'includes volume mounted files' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.volume_mounted_files.size).to be > 1
            end
          end

          context 'when file-based VCAP service bindings are enabled' do
            before do
              app = task.app
              app.update(file_based_vcap_services_enabled: true)
              VCAP::CloudController::ServiceBinding.make(service_instance: ManagedServiceInstance.make(space: app.space), app: app)
            end

            it 'includes volume mounted files' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.volume_mounted_files.size).to eq(1)
              expect(result.volume_mounted_files[0].path).to eq('vcap_services')
            end
          end
        end

        context 'with a docker backend' do
          let(:package) { PackageModel.make(:docker, app:) }
          let(:droplet) do
            DropletModel.make(:docker,
                              app: app,
                              docker_receipt_username: 'dockerusername',
                              docker_receipt_password: 'dockerpassword')
          end

          let(:task_action_builder) do
            instance_double(
              Docker::TaskActionBuilder,
              action: task_action,
              task_environment_variables: lifecycle_environment_variables,
              cached_dependencies: lifecycle_cached_dependencies,
              image_layers: [],
              stack: 'docker://potato-stack'
            )
          end

          let(:lifecycle_protocol) do
            instance_double(VCAP::CloudController::Diego::Docker::LifecycleProtocol,
                            task_action_builder:)
          end

          before do
            allow(LifecycleProtocol).to receive(:protocol_for_type).with('docker').and_return(lifecycle_protocol)
            calculator = instance_double(TaskCpuWeightCalculator, calculate: 25)
            allow(TaskCpuWeightCalculator).to receive(:new).with(memory_in_mb: task.memory_in_mb).and_return(calculator)
          end

          it 'constructs a TaskDefinition with app task instructions' do
            result = task_recipe_builder.build_app_task(config, task)
            expected_callback_url = "https://#{internal_service_hostname}:#{tls_port}/internal/v4/tasks/#{task.guid}/completed"

            expect(result.disk_mb).to eq(1024)
            expect(result.memory_mb).to eq(2048)
            expect(result.log_rate_limit.bytes_per_second).to eq(3072)
            expect(result.log_guid).to eq(app.guid)
            expect(result.privileged).to be(false)
            expect(result.egress_rules).to eq([
              rule_dns_everywhere,
              rule_http_everywhere
            ])
            expect(result.completion_callback_url).to eq(expected_callback_url)
            expect(result.log_source).to eq(TASK_LOG_SOURCE)
            expect(result.trusted_system_certificates_path).to eq('/etc/cf-system-certificates')
            expect(result.volume_mounts).to eq([])
            expect(result.environment_variables).to eq(lifecycle_environment_variables)
            expect(result.network).to eq(expected_network)

            expect(result.root_fs).to eq('docker://potato-stack')
            expect(result.cached_dependencies).to eq(lifecycle_cached_dependencies)
            expect(result.image_layers).to be_empty
            expect(result.action).to eq(task_action)

            expect(result.metrics_guid).to eq('')
            expect(result.cpu_weight).to eq(25)
            expect(result.placement_tags).to eq([isolation_segment])
            expect(result.max_pids).to eq(100)
            expect(result.certificate_properties).to eq(certificate_properties)

            expect(result.metric_tags.keys.size).to eq(7)
            expect(result.metric_tags['source_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_id'].static).to eq('org-guid')
            expect(result.metric_tags['space_id'].static).to eq('space-guid')
            expect(result.metric_tags['app_id'].static).to eq('banana-guid')
            expect(result.metric_tags['organization_name'].static).to eq('MyOrg')
            expect(result.metric_tags['space_name'].static).to eq('MySpace')
            expect(result.metric_tags['app_name'].static).to eq('MyApp')

            expect(result.image_username).to eq('dockerusername')
            expect(result.image_password).to eq('dockerpassword')

            expect(result.volume_mounted_files).to be_empty
          end

          context 'when a volume mount is provided' do
            let(:service_instance) { ManagedServiceInstance.make space: app.space }
            let(:multiple_volume_mounts) do
              [
                {
                  container_dir: '/data/images',
                  mode: 'r',
                  device_type: 'shared',
                  driver: 'cephfs',
                  device: {
                    volume_id: 'abc',
                    mount_config: {
                      key: 'value'
                    }
                  }
                },
                {
                  container_dir: '/data/scratch',
                  mode: 'rw',
                  device_type: 'shared',
                  driver: 'local',
                  device: {
                    volume_id: 'def',
                    mount_config: {}
                  }
                }
              ]
            end

            before do
              ServiceBinding.make(app: app, service_instance: service_instance, volume_mounts: multiple_volume_mounts)
            end

            it 'desires the mount' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.volume_mounts).to eq([
                ::Diego::Bbs::Models::VolumeMount.new(
                  driver: 'cephfs',
                  container_dir: '/data/images',
                  mode: 'r',
                  shared: ::Diego::Bbs::Models::SharedDevice.new(volume_id: 'abc', mount_config: { 'key' => 'value' }.to_json)
                ),
                ::Diego::Bbs::Models::VolumeMount.new(
                  driver: 'local',
                  container_dir: '/data/scratch',
                  mode: 'rw',
                  shared: ::Diego::Bbs::Models::SharedDevice.new(volume_id: 'def', mount_config: '')
                )
              ])
            end
          end

          describe 'privileged' do
            it 'is false when it is false in the config' do
              config.set(:diego, config.get(:diego).merge(use_privileged_containers_for_running: false))

              result = task_recipe_builder.build_app_task(config, task)
              expect(result.privileged).to be(false)
            end

            it 'is true when it is true in the config' do
              config.set(:diego, config.get(:diego).merge(use_privileged_containers_for_running: true))

              result = task_recipe_builder.build_app_task(config, task)
              expect(result.privileged).to be(true)
            end
          end

          context 'when isolation segment is not set' do
            let(:isolation_segment) { nil }

            it 'configures no placement tags' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.placement_tags).to eq([])
            end
          end

          context 'when k8s service bindings are enabled' do
            before do
              app = task.app
              app.update(service_binding_k8s_enabled: true)
              VCAP::CloudController::ServiceBinding.make(service_instance: ManagedServiceInstance.make(space: app.space), app: app)
            end

            it 'includes volume mounted files' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.volume_mounted_files.size).to be > 1
            end
          end

          context 'when file-based VCAP service bindings are enabled' do
            before do
              app = task.app
              app.update(file_based_vcap_services_enabled: true)
              VCAP::CloudController::ServiceBinding.make(service_instance: ManagedServiceInstance.make(space: app.space), app: app)
            end

            it 'includes volume mounted files' do
              result = task_recipe_builder.build_app_task(config, task)
              expect(result.volume_mounted_files.size).to eq(1)
              expect(result.volume_mounted_files[0].path).to eq('vcap_services')
            end
          end
        end
      end
    end
  end
end
