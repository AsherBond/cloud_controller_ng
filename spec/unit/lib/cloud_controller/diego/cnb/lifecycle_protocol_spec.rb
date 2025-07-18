require 'spec_helper'
require 'cloud_controller/blobstore/url_generator'
require 'cloud_controller/diego/cnb/lifecycle_protocol'
require_relative '../lifecycle_protocol_shared'

module VCAP
  module CloudController
    module Diego
      module CNB
        RSpec.describe LifecycleProtocol do
          subject(:lifecycle_protocol) { LifecycleProtocol.new(blobstore_url_generator, droplet_url_generator) }
          let(:droplet_url_generator) { instance_double(DropletUrlGenerator, perma_droplet_download_url: 'www.droplet.com') }
          let(:blobstore_url_generator) do
            instance_double(::CloudController::Blobstore::UrlGenerator,
                            buildpack_cache_download_url: 'cache-download-url',
                            buildpack_cache_upload_url: 'cache-upload-url',
                            package_download_url: 'package-download-url',
                            droplet_upload_url: 'droplet-upload-url',
                            droplet_download_url: droplet_download_url)
          end
          let(:droplet_download_url) { 'droplet-download-url' }

          it_behaves_like 'a lifecycle protocol' do
            let(:app) { AppModel.make(:cnb) }
            let(:package) { PackageModel.make(:cnb, app_guid: app.guid) }
            let(:droplet) { DropletModel.make(:cnb, package_guid: package.guid, app_guid: app.guid) }
            let(:process) { ProcessModel.make(app:) }
            let(:staging_details) do
              Diego::StagingDetails.new.tap do |details|
                details.staging_guid = droplet.guid
                details.package      = package
                details.lifecycle    = instance_double(CNBLifecycle, staging_stack: 'potato-stack', buildpack_infos: buildpack_infos,
                                                                     credentials: '{"registry":{"username":"password"}}')
              end
            end
            let(:buildpack_infos) { [BuildpackInfo.new('http://some-buildpack.url', nil)] }

            before do
              app.update(droplet_guid: droplet.guid)
            end
          end

          before do
            Stack.create(name: 'potato-stack')
            VCAP::CloudController::Buildpack.create(name: 'ruby', stack: 'potato-stack', key: 'ruby-buildpack-key', position: 2)
            allow(blobstore_url_generator).to receive(:admin_buildpack_download_url).and_return('bp-download-url')
          end

          describe '#lifecycle_data' do
            let(:app) { AppModel.make(:cnb) }
            let(:package) { PackageModel.make(app:) }
            let(:droplet) { DropletModel.make(:cnb, package:, app:) }
            let(:buildpack) { nil }
            let(:buildpack_infos) { [BuildpackInfo.new(buildpack, VCAP::CloudController::Buildpack.find(name: buildpack))] }

            let(:staging_details) do
              Diego::StagingDetails.new.tap do |details|
                details.staging_guid          = droplet.guid
                details.package               = package
                details.environment_variables = { 'nightshade_fruit' => 'potato' }
                details.staging_memory_in_mb  = 42
                details.staging_disk_in_mb    = 51
                details.lifecycle             = instance_double(CNBLifecycle, staging_stack: 'potato-stack', buildpack_infos: buildpack_infos,
                                                                              credentials: '{"registry":{"username":"password"}}')
              end
            end

            context 'when a custom buildpack is requested' do
              let(:buildpack) { 'http://custom.com' }

              it 'sends buildpacks with skip detect' do
                lifecycle_data = lifecycle_protocol.lifecycle_data(staging_details)

                expect(lifecycle_data[:buildpacks]).to have(1).items
                bp = lifecycle_data[:buildpacks][0]
                expect(bp).to include(url: buildpack, skip_detect: true)
              end
            end

            context 'when buildpack_infos is empty' do
              let(:buildpack_infos) { [] }

              it 'sets auto_detect: true' do
                lifecycle_data = lifecycle_protocol.lifecycle_data(staging_details)

                expect(lifecycle_data[:auto_detect]).to be true
              end
            end

            context 'when the generated message has invalid data' do
              let(:buildpack_infos) { [] }

              context 'when the package is missing a download uri (probably due to blobstore outages)' do
                before do
                  allow(blobstore_url_generator).to receive(:package_download_url).and_return(nil)
                end

                it 'raises an InvalidDownloadUri error' do
                  expect do
                    lifecycle_protocol.lifecycle_data(staging_details)
                  end.to raise_error LifecycleProtocol::InvalidDownloadUri, /Failed to get blobstore download url for package #{staging_details.package.guid}/
                end
              end

              context 'when the message is invalid for other reasons' do
                before do
                  allow(blobstore_url_generator).to receive(:droplet_upload_url).and_return(nil)
                end

                it 're-raises the error' do
                  expect do
                    lifecycle_protocol.lifecycle_data(staging_details)
                  end.to raise_error Membrane::SchemaValidationError, '{ droplet_upload_uri => Expected instance of String, given an instance of NilClass }'
                end
              end
            end
          end

          describe '#staging_action_builder' do
            let(:config) { Config.new({ some: 'config' }) }
            let(:package) { PackageModel.make(:cnb) }
            let(:droplet) { DropletModel.make(:cnb) }
            let(:staging_details) do
              StagingDetails.new.tap do |details|
                details.lifecycle    = instance_double(CNBLifecycle, staging_stack: 'potato-stack', buildpack_infos: 'some buildpack info',
                                                                     credentials: '{"registry":{"username":"password"}}')
                details.package      = package
                details.staging_guid = droplet.guid
              end
            end

            before do
              allow_any_instance_of(BuildpackEntryGenerator).to receive(:buildpack_entries).and_return(['buildpacks'])
              package.app.update(buildpack_cache_sha256_checksum: 'bp-cache-checksum')
            end

            it 'returns a StagingActionBuilder' do
              staging_action_builder = instance_double(StagingActionBuilder)
              allow(StagingActionBuilder).to receive(:new).and_return staging_action_builder

              expect(lifecycle_protocol.staging_action_builder(config, staging_details)).to be staging_action_builder

              expect(StagingActionBuilder).to have_received(:new).with(config, staging_details, hash_including({
                                                                                                                 app_bits_download_uri: 'package-download-url',
                                                                                                                 build_artifacts_cache_download_uri: 'cache-download-url',
                                                                                                                 buildpacks: ['buildpacks'],
                                                                                                                 stack: 'potato-stack',
                                                                                                                 build_artifacts_cache_upload_uri: 'cache-upload-url',
                                                                                                                 droplet_upload_uri: 'droplet-upload-url',
                                                                                                                 buildpack_cache_checksum: 'bp-cache-checksum',
                                                                                                                 app_bits_checksum: package.checksum_info,
                                                                                                                 credentials: '{"registry":{"username":"password"}}'
                                                                                                               }))
            end
          end

          describe '#task_action_builder' do
            let(:task) { TaskModel.make(:cnb) }
            let(:config) { Config.new({ some: 'config' }) }

            it 'returns a TaskActionBuilder' do
              task.app.update(cnb_lifecycle_data: CNBLifecycleDataModel.make(stack: 'potato-stack'))

              task_action_builder = instance_double(Buildpack::TaskActionBuilder)
              allow(Buildpack::TaskActionBuilder).to receive(:new).and_return task_action_builder

              expect(lifecycle_protocol.task_action_builder(config, task)).to be task_action_builder

              expect(Buildpack::TaskActionBuilder).to have_received(:new).with(config, task, {
                                                                                 droplet_uri: 'droplet-download-url',
                                                                                 stack: 'potato-stack'
                                                                               },
                                                                               'root',
                                                                               ['--', task.command],
                                                                               'cnb')
            end

            context 'when the blobstore_url_generator returns nil' do
              let(:droplet_download_url) { nil }

              it 'returns an error' do
                expect do
                  lifecycle_protocol.task_action_builder(config, task)
                end.to raise_error(
                  VCAP::CloudController::Diego::CNB::LifecycleProtocol::InvalidDownloadUri,
                  /Failed to get blobstore download url for droplet #{task.droplet.guid}/
                )
              end
            end
          end

          describe '#desired_lrp_builder' do
            let(:config) { Config.new({}) }
            let(:app) { AppModel.make(:cnb, droplet:) }
            let(:droplet) { DropletModel.make(:cnb) }
            let(:process) do
              ProcessModel.make(
                :cnb,
                type: 'worker',
                app: app,
                diego: true,
                command: 'go go go',
                metadata: {},
                ports: [1234, 5678]
              )
            end
            let(:builder_opts) do
              {
                ports: [1234, 5678],
                stack: process.app.lifecycle_data.stack,
                droplet_uri: 'www.droplet.com',
                droplet_hash: droplet.droplet_hash,
                process_guid: ProcessGuid.from_process(process),
                checksum_algorithm: 'sha256',
                checksum_value: droplet.sha256_checksum,
                start_command: 'go go go',
                action_user: 'vcap',
                additional_container_env_vars: []
              }
            end

            it 'creates a diego DesiredLrpBuilder' do
              expect(VCAP::CloudController::Diego::CNB::DesiredLrpBuilder).to receive(:new).with(
                config,
                builder_opts
              )
              lifecycle_protocol.desired_lrp_builder(config, process)
            end

            context 'when the droplet has a sha256 checksum calculated' do
              before do
                droplet.update(sha256_checksum: 'droplet-sha256-checksum')
              end

              it 'uses it' do
                builder_opts.merge!(checksum_algorithm: 'sha256', checksum_value: 'droplet-sha256-checksum')
                expect(VCAP::CloudController::Diego::CNB::DesiredLrpBuilder).to receive(:new).with(
                  config,
                  builder_opts
                )
                lifecycle_protocol.desired_lrp_builder(config, process)
              end
            end

            context 'when a start command is not set' do
              before do
                process.update(command: nil)
                allow(process).to receive(:detected_start_command).and_return('/usr/bin/nc')
              end

              it 'uses the detected start command' do
                builder_opts[:start_command] = '/usr/bin/nc'
                expect(VCAP::CloudController::Diego::CNB::DesiredLrpBuilder).to receive(:new).with(
                  config,
                  builder_opts
                )
                lifecycle_protocol.desired_lrp_builder(config, process)
              end
            end

            context 'when revisions are enabled' do
              before do
                app.update(revisions_enabled: true)
              end

              context 'and theres a revision on the process' do
                let(:new_droplet) do
                  DropletModel.make(
                    :cnb,
                    app: app,
                    process_types: {
                      'worker' => 'something else',
                      'web' => 'not this'
                    }
                  )
                end
                let(:revision) { RevisionModel.make(app: app, droplet_guid: new_droplet.guid) }

                before do
                  process.update(revision:)
                end

                it 'uses the droplet from the revision and the command in the droplet' do
                  builder_opts.merge!(start_command: 'something else', droplet_hash: new_droplet.droplet_hash, checksum_value: new_droplet.sha256_checksum)
                  expect(VCAP::CloudController::Diego::CNB::DesiredLrpBuilder).to receive(:new).with(
                    config,
                    builder_opts
                  )
                  lifecycle_protocol.desired_lrp_builder(config, process)
                end

                context 'when revision has specified process command' do
                  before do
                    RevisionProcessCommandModel.where(revision: revision, process_type: 'worker').update(process_command: 'stop stop stop')
                  end

                  it 'uses the command from the revision' do
                    builder_opts.merge!(start_command: 'stop stop stop', droplet_hash: new_droplet.droplet_hash, checksum_value: new_droplet.sha256_checksum)
                    expect(VCAP::CloudController::Diego::CNB::DesiredLrpBuilder).to receive(:new).with(
                      config,
                      builder_opts
                    )
                    lifecycle_protocol.desired_lrp_builder(config, process)
                  end
                end
              end

              context 'but there is not a revision on the process' do
                it 'uses the droplet from the process' do
                  builder_opts.merge!(droplet_hash: droplet.droplet_hash, checksum_value: droplet.sha256_checksum)
                  expect(VCAP::CloudController::Diego::CNB::DesiredLrpBuilder).to receive(:new).with(
                    config,
                    builder_opts
                  )
                  lifecycle_protocol.desired_lrp_builder(config, process)
                end

                it 'uses the command from the process' do
                  builder_opts[:start_command] = 'go go go'
                  expect(VCAP::CloudController::Diego::CNB::DesiredLrpBuilder).to receive(:new).with(
                    config,
                    builder_opts
                  )
                  lifecycle_protocol.desired_lrp_builder(config, process)
                end
              end
            end
          end
        end
      end
    end
  end
end
