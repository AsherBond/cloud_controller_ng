require 'spec_helper'
require 'actions/deployment_create'
require 'messages/deployment_create_message'

module VCAP::CloudController
  RSpec.describe DeploymentCreate do
    let(:app) { AppModel.make(desired_state: ProcessModel::STARTED) }

    let!(:web_process) { ProcessModel.make(app: app, instances: original_instances, memory: 500, disk_quota: 1024, log_rate_limit: 101, state: process_state) }
    let(:original_droplet) { DropletModel.make(app: app, process_types: { 'web' => 'asdf' }) }
    let(:next_droplet) { DropletModel.make(app: app, process_types: { 'web' => '1234' }) }
    let!(:route1) { Route.make(space: app.space) }
    let!(:route_mapping1) { RouteMappingModel.make(app: app, route: route1, process_type: web_process.type) }
    let!(:route2) { Route.make(space: app.space) }
    let!(:route_mapping2) { RouteMappingModel.make(app: app, route: route2, process_type: web_process.type) }
    let(:user_audit_info) { UserAuditInfo.new(user_guid: '123', user_email: 'connor@example.com', user_name: 'braa') }
    let(:runner) { instance_double(Diego::Runner) }

    let(:process_state) { ProcessModel::STARTED }

    let(:strategy) { 'rolling' }
    let(:max_in_flight) { 1 }
    let(:original_instances) { 3 }
    let(:web_instances) { nil }
    let(:memory_in_mb) { nil }
    let(:disk_in_mb) { nil }
    let(:log_rate_limit_in_bytes_per_second) { nil }

    let(:message) do
      DeploymentCreateMessage.new({
                                    relationships: { app: { data: { guid: app.guid } } },
                                    droplet: { guid: next_droplet.guid },
                                    strategy: strategy,
                                    options: { max_in_flight:, web_instances:, memory_in_mb:, disk_in_mb:, log_rate_limit_in_bytes_per_second: }
                                  })
    end

    let(:restart_message) do
      DeploymentCreateMessage.new({
                                    relationships: { app: { data: { guid: app.guid } } },
                                    droplet: { guid: original_droplet.guid }
                                  })
    end

    before do
      app.update(droplet: original_droplet)
    end

    describe '#create' do
      context 'when the old process has metadata' do
        before do
          ProcessLabelModel.make(
            key_name: 'freaky',
            value: 'wednesday',
            resource_guid: web_process.guid
          )
          ProcessAnnotationModel.make(
            key_name: 'tokyo',
            value: 'grapes',
            resource_guid: web_process.guid
          )
        end

        it 'assigns the old process metadata to the new process' do
          deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
          deploying_web_process = deployment.deploying_web_process

          expect(deploying_web_process).to have_labels({ key_name: 'freaky', value: 'wednesday' })
          expect(deploying_web_process).to have_annotations({ key_name: 'tokyo', value: 'grapes' })
        end
      end

      context 'when a droplet is provided on the message' do
        context 'when a new droplet is provided' do
          it 'creates a deployment with the provided droplet' do
            deployment = nil

            expect do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(DeploymentModel, :count).by(1)

            expect(deployment.state).to eq(DeploymentModel::DEPLOYING_STATE)
            expect(deployment.status_value).to eq(DeploymentModel::ACTIVE_STATUS_VALUE)
            expect(deployment.status_reason).to eq(DeploymentModel::DEPLOYING_STATUS_REASON)
            expect(deployment.app_guid).to eq(app.guid)
            expect(deployment.droplet_guid).to eq(next_droplet.guid)
            expect(deployment.previous_droplet).to eq(original_droplet)
            expect(deployment.original_web_process_instance_count).to eq(3)
            expect(deployment.last_healthy_at).to eq(deployment.created_at)
          end

          it 'creates a revision associated with the provided droplet' do
            expect do
              DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(RevisionModel, :count).by(1)

            revision = RevisionModel.last
            expect(revision.droplet_guid).to eq(next_droplet.guid)

            deploying_web_process = app.reload.newest_web_process
            expect(deploying_web_process.revision).to eq(app.latest_revision)
          end

          it 'records the created revision on the deployment' do
            deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

            revision = RevisionModel.last

            expect(deployment.revision_guid).to eq(revision.guid)
            expect(deployment.revision_version).to eq(revision.version)
          end

          it 'has the reason for the initial revision' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            revision = RevisionModel.last

            expect(revision.description).to eq('Initial revision.')
          end

          it 'has the reason for a droplet changed' do
            RevisionModel.make(app: app, droplet_guid: app.droplet.guid, environment_variables: app.environment_variables)
            DeploymentCreate.create(app:, message:, user_audit_info:)

            revision = RevisionModel.last

            expect(revision.description).to eq('New droplet deployed.')
          end

          it 'keeps a record of the revision even if it is deleted' do
            deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

            revision = RevisionModel.last
            revision_guid = revision.guid
            revision_version = revision.version
            RevisionDelete.delete(revision)

            deployment.reload

            expect(deployment.revision_guid).to eq(revision_guid)
            expect(deployment.revision_version).to eq(revision_version)
          end

          it 'records an audit event for the deployment with the revision' do
            deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

            event = VCAP::CloudController::Event.find(type: 'audit.app.deployment.create')
            expect(event).not_to be_nil
            expect(event.actor).to eq('123')
            expect(event.actor_type).to eq('user')
            expect(event.actor_name).to eq('connor@example.com')
            expect(event.actor_username).to eq('braa')
            expect(event.actee).to eq(app.guid)
            expect(event.actee_type).to eq('app')
            expect(event.actee_name).to eq(app.name)
            expect(event.timestamp).to be
            expect(event.space_guid).to eq(app.space_guid)
            expect(event.organization_guid).to eq(app.space.organization.guid)
            expect(event.metadata).to eq({
                                           'droplet_guid' => next_droplet.guid,
                                           'deployment_guid' => deployment.guid,
                                           'type' => nil,
                                           'revision_guid' => RevisionModel.last.guid,
                                           'request' => message.audit_hash,
                                           'strategy' => 'rolling'
                                         })
          end

          it 'sets the current droplet of the app to be the provided droplet' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            expect(app.droplet).to eq(next_droplet)
          end

          it 'creates a process of web type with the same characteristics as the existing web process' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            deploying_web_process = app.reload.newest_web_process

            expect(deploying_web_process.type).to eq(ProcessTypes::WEB)
            expect(deploying_web_process.state).to eq(ProcessModel::STARTED)
            expect(deploying_web_process.instances).to eq(1)
            expect(deploying_web_process.command).to eq(web_process.command)
            expect(deploying_web_process.user).to eq(web_process.user)
            expect(deploying_web_process.memory).to eq(web_process.memory)
            expect(deploying_web_process.file_descriptors).to eq(web_process.file_descriptors)
            expect(deploying_web_process.disk_quota).to eq(web_process.disk_quota)
            expect(deploying_web_process.log_rate_limit).to eq(web_process.log_rate_limit)
            expect(deploying_web_process.metadata).to eq(web_process.metadata)
            expect(deploying_web_process.detected_buildpack).to eq(web_process.detected_buildpack)
            expect(deploying_web_process.health_check_timeout).to eq(web_process.health_check_timeout)
            expect(deploying_web_process.health_check_interval).to eq(web_process.health_check_interval)
            expect(deploying_web_process.health_check_type).to eq(web_process.health_check_type)
            expect(deploying_web_process.health_check_http_endpoint).to eq(web_process.health_check_http_endpoint)
            expect(deploying_web_process.health_check_invocation_timeout).to eq(web_process.health_check_invocation_timeout)
            expect(deploying_web_process.readiness_health_check_type).to eq(web_process.readiness_health_check_type)
            expect(deploying_web_process.readiness_health_check_http_endpoint).to eq(web_process.readiness_health_check_http_endpoint)
            expect(deploying_web_process.readiness_health_check_invocation_timeout).to eq(web_process.readiness_health_check_invocation_timeout)
            expect(deploying_web_process.readiness_health_check_interval).to eq(web_process.readiness_health_check_interval)
            expect(deploying_web_process.enable_ssh).to eq(web_process.enable_ssh)
            expect(deploying_web_process.ports).to eq(web_process.ports)
            expect(deploying_web_process.revision).to eq(app.latest_revision)
          end

          it 'desires an LRP via the ProcessObserver', isolation: :truncation do
            allow(runner).to receive(:start)
            allow(Diego::Runner).to receive(:new).and_return(runner)

            DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)

            expect(runner).to have_received(:start).at_least(:once)
          end

          context 'when there are multiple web processes' do
            let!(:web_process) do
              ProcessModel.make(
                app: app,
                type: ProcessTypes::WEB,
                created_at: Time.now - 24.hours,
                command: 'old command!',
                instances: 3,
                memory: 1,
                file_descriptors: 3,
                disk_quota: 5,
                metadata: { foo: 'bar' },
                detected_buildpack: 'ruby yo',
                health_check_timeout: 7,
                health_check_type: 'http',
                health_check_http_endpoint: '/old_dawg',
                health_check_invocation_timeout: 9,
                health_check_interval: 10,
                readiness_health_check_type: 'http',
                readiness_health_check_http_endpoint: '/ready',
                readiness_health_check_invocation_timeout: 21,
                readiness_health_check_interval: 11,
                log_rate_limit: 11,
                enable_ssh: true,
                ports: []
              )
            end

            let!(:newer_web_process) do
              ProcessModel.make(
                app: app,
                type: ProcessTypes::WEB,
                created_at: Time.now - 23.hours,
                command: 'new command!',
                instances: 4,
                memory: 2,
                file_descriptors: 4,
                disk_quota: 6,
                metadata: { qux: 'baz' },
                detected_buildpack: 'golang',
                health_check_timeout: 8,
                health_check_type: 'port',
                health_check_http_endpoint: '/new_cat',
                health_check_invocation_timeout: 10,
                health_check_interval: 11,
                readiness_health_check_type: 'http',
                readiness_health_check_http_endpoint: '/new_ready',
                readiness_health_check_invocation_timeout: 22,
                readiness_health_check_interval: 15,
                log_rate_limit: 12,
                enable_ssh: false,
                ports: nil
              )
            end

            it 'creates a process of web type with the same characteristics as the newer web process' do
              DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)

              deploying_web_process = app.reload.newest_web_process

              expect(deploying_web_process.type).to eq(ProcessTypes::WEB)
              expect(deploying_web_process.state).to eq(ProcessModel::STARTED)
              expect(deploying_web_process.instances).to eq(1)
              expect(deploying_web_process.command).to eq(newer_web_process.command)
              expect(deploying_web_process.memory).to eq(newer_web_process.memory)
              expect(deploying_web_process.file_descriptors).to eq(newer_web_process.file_descriptors)
              expect(deploying_web_process.disk_quota).to eq(newer_web_process.disk_quota)
              expect(deploying_web_process.log_rate_limit).to eq(newer_web_process.log_rate_limit)
              expect(deploying_web_process.metadata).to eq(newer_web_process.metadata)
              expect(deploying_web_process.detected_buildpack).to eq(newer_web_process.detected_buildpack)
              expect(deploying_web_process.health_check_timeout).to eq(newer_web_process.health_check_timeout)
              expect(deploying_web_process.health_check_type).to eq(newer_web_process.health_check_type)
              expect(deploying_web_process.health_check_http_endpoint).to eq(newer_web_process.health_check_http_endpoint)
              expect(deploying_web_process.health_check_invocation_timeout).to eq(newer_web_process.health_check_invocation_timeout)
              expect(deploying_web_process.health_check_interval).to eq(newer_web_process.health_check_interval)
              expect(deploying_web_process.readiness_health_check_type).to eq(newer_web_process.readiness_health_check_type)
              expect(deploying_web_process.readiness_health_check_http_endpoint).to eq(newer_web_process.readiness_health_check_http_endpoint)
              expect(deploying_web_process.readiness_health_check_invocation_timeout).to eq(newer_web_process.readiness_health_check_invocation_timeout)
              expect(deploying_web_process.readiness_health_check_interval).to eq(newer_web_process.readiness_health_check_interval)
              expect(deploying_web_process.enable_ssh).to eq(newer_web_process.enable_ssh)
              expect(deploying_web_process.ports).to eq(newer_web_process.ports)
            end
          end

          it 'saves the new web process on the deployment' do
            deployment = DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)

            deploying_web_process = app.reload.newest_web_process
            expect(app.web_processes.count).to eq(2)
            expect(deployment.deploying_web_process_guid).to eq(deploying_web_process.guid)
          end

          it 'creates route mappings for each route mapped to the existing web process' do
            DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)

            deploying_web_process = app.reload.newest_web_process
            expect(deploying_web_process.routes).to contain_exactly(route1, route2)
          end

          it 'records an audit event for the deployment' do
            deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

            event = VCAP::CloudController::Event.find(type: 'audit.app.deployment.create')
            expect(event).not_to be_nil
            expect(event.actor).to eq('123')
            expect(event.actor_type).to eq('user')
            expect(event.actor_name).to eq('connor@example.com')
            expect(event.actor_username).to eq('braa')
            expect(event.actee).to eq(app.guid)
            expect(event.actee_type).to eq('app')
            expect(event.actee_name).to eq(app.name)
            expect(event.timestamp).to be
            expect(event.space_guid).to eq(app.space_guid)
            expect(event.organization_guid).to eq(app.space.organization.guid)
            expect(event.metadata).to eq({
                                           'droplet_guid' => next_droplet.guid,
                                           'deployment_guid' => deployment.guid,
                                           'type' => nil,
                                           'revision_guid' => app.latest_revision.guid,
                                           'request' => message.audit_hash,
                                           'strategy' => 'rolling'
                                         })
          end

          it 'creates a DeploymentProcessModel to save historical information about the deploying processes' do
            deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

            expect(
              deployment.historical_related_processes.map(&:deployment_guid)
            ).to contain_exactly(deployment.guid)

            expect(
              deployment.historical_related_processes.map(&:process_guid)
            ).to contain_exactly(deployment.deploying_web_process.guid)

            expect(
              deployment.historical_related_processes.map(&:process_type)
            ).to contain_exactly(deployment.deploying_web_process.type)
          end

          context 'when the app does not have a droplet set' do
            let(:app_without_current_droplet) { AppModel.make }
            let(:next_droplet) { DropletModel.make(app: app_without_current_droplet, process_types: { 'web' => 'asdf' }) }

            it 'sets the droplet on the deployment' do
              deployment = DeploymentCreate.create(app: app_without_current_droplet, message: message, user_audit_info: user_audit_info)

              expect(deployment.app).to eq(app_without_current_droplet)
              expect(deployment.droplet).to eq(next_droplet)
            end

            it 'has a nil previous droplet' do
              deployment = DeploymentCreate.create(app: app_without_current_droplet, message: message, user_audit_info: user_audit_info)

              expect(deployment.previous_droplet).to be_nil
            end

            it 'records an audit event for the deployment' do
              deployment = DeploymentCreate.create(app: app_without_current_droplet, message: message, user_audit_info: user_audit_info)

              event = Event.last
              expect(event.type).to eq('audit.app.deployment.create')
              expect(event.actor).to eq('123')
              expect(event.actor_type).to eq('user')
              expect(event.actor_name).to eq('connor@example.com')
              expect(event.actor_username).to eq('braa')
              expect(event.actee).to eq(app_without_current_droplet.guid)
              expect(event.actee_type).to eq('app')
              expect(event.actee_name).to eq(app_without_current_droplet.name)
              expect(event.timestamp).to be
              expect(event.space_guid).to eq(app_without_current_droplet.space_guid)
              expect(event.organization_guid).to eq(app_without_current_droplet.space.organization.guid)
              expect(event.metadata).to eq({
                                             'droplet_guid' => next_droplet.guid,
                                             'deployment_guid' => deployment.guid,
                                             'type' => nil,
                                             'revision_guid' => app_without_current_droplet.latest_revision.guid,
                                             'request' => message.audit_hash,
                                             'strategy' => 'rolling'
                                           })
            end
          end

          context 'when the current droplet assignment fails' do
            let(:unaffiliated_droplet) { DropletModel.make }
            let(:message) do
              DeploymentCreateMessage.new({
                                            relationships: { app: { data: { guid: app.guid } } },
                                            droplet: { guid: unaffiliated_droplet.guid }
                                          })
            end

            it 'raises a AppAssignDroplet error' do
              expect do
                DeploymentCreate.create(app:, message:, user_audit_info:)
              end.to raise_error DeploymentCreate::Error, /Ensure the droplet exists and belongs to this app/
            end
          end

          context 'when there is an existing deployment' do
            let(:originally_desired_instance_count) { 10 }
            let!(:existing_deployment) do
              DeploymentModel.make(
                app: app,
                state: existing_state,
                droplet: nil,
                previous_droplet: original_droplet,
                original_web_process_instance_count: originally_desired_instance_count
              )
            end

            before do
              web_process.update(instances: 5)
              web_process.save
            end

            context 'when the existing deployment is DEPLOYING' do
              let(:existing_state) { DeploymentModel::DEPLOYING_STATE }

              it 'creates a new deployment with the instance count from the existing deployment' do
                deployment = nil

                expect do
                  deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                end.to change(DeploymentModel, :count).by(1)

                expect(deployment.state).to eq(DeploymentModel::DEPLOYING_STATE)
                expect(deployment.status_value).to eq(DeploymentModel::ACTIVE_STATUS_VALUE)
                expect(deployment.status_reason).to eq(DeploymentModel::DEPLOYING_STATUS_REASON)
                expect(deployment.app_guid).to eq(app.guid)
                expect(deployment.droplet_guid).to eq(next_droplet.guid)
                expect(deployment.previous_droplet).to eq(original_droplet)
                expect(deployment.original_web_process_instance_count).to eq(originally_desired_instance_count)
              end

              it 'sets the existing deployment to DEPLOYED, with reason SUPERSEDED' do
                DeploymentCreate.create(app:, message:, user_audit_info:)
                existing_deployment.reload

                expect(existing_deployment.state).to eq(DeploymentModel::DEPLOYED_STATE)
                expect(existing_deployment.status_value).to eq(DeploymentModel::FINALIZED_STATUS_VALUE)
                expect(existing_deployment.status_reason).to eq(DeploymentModel::SUPERSEDED_STATUS_REASON)
              end
            end

            context 'when the existing deployment is CANCELING' do
              let(:existing_state) { DeploymentModel::CANCELING_STATE }

              it 'sets the existing deployment to CANCELED, with reason SUPERSEDED' do
                DeploymentCreate.create(app:, message:, user_audit_info:)
                existing_deployment.reload

                expect(existing_deployment.state).to eq(DeploymentModel::CANCELED_STATE)
                expect(existing_deployment.status_value).to eq(DeploymentModel::FINALIZED_STATUS_VALUE)
                expect(existing_deployment.status_reason).to eq(DeploymentModel::SUPERSEDED_STATUS_REASON)
              end
            end
          end

          context 'when the message specifies metadata' do
            let(:message) do
              DeploymentCreateMessage.new({
                                            'metadata' => {
                                              labels: {
                                                release: 'stable',
                                                'seriouseats.com/potato': 'mashed'
                                              },
                                              annotations: {
                                                superhero: 'Bummer-boy',
                                                superpower: 'Bums you out'
                                              }
                                            }
                                          })
            end

            it 'saves the metadata to the new deployment' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

              expect(deployment).to have_labels(
                { prefix: 'seriouseats.com', key_name: 'potato', value: 'mashed' },
                { prefix: nil, key_name: 'release', value: 'stable' }
              )
              expect(deployment).to have_annotations(
                { key_name: 'superhero', value: 'Bummer-boy' },
                { key_name: 'superpower', value: 'Bums you out' }
              )
            end
          end

          context 'when the app is stopped' do
            let(:max_in_flight) { 3 }
            let(:strategy) { 'canary' }
            let(:process_state) { ProcessModel::STOPPED }

            before do
              app.update(desired_state: ProcessModel::STOPPED)
              app.save
            end

            it 'sets the current droplet of the app to be the provided droplet' do
              DeploymentCreate.create(app:, message:, user_audit_info:)

              expect(app.droplet).to eq(next_droplet)
            end

            it 'starts the app' do
              DeploymentCreate.create(app:, message:, user_audit_info:)

              expect(app.reload.desired_state).to eq(ProcessModel::STARTED)
            end

            it 'creates a deployment with the provided droplet in DEPLOYED state' do
              deployment = nil

              expect do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              end.to change(DeploymentModel, :count).by(1)

              expect(deployment.state).to eq(DeploymentModel::DEPLOYED_STATE)
              expect(deployment.status_value).to eq(DeploymentModel::FINALIZED_STATUS_VALUE)
              expect(deployment.status_reason).to eq(DeploymentModel::DEPLOYED_STATUS_REASON)
              expect(deployment.app_guid).to eq(app.guid)
              expect(deployment.droplet_guid).to eq(next_droplet.guid)
              expect(deployment.previous_droplet).to eq(original_droplet)
              expect(deployment.original_web_process_instance_count).to eq(3)
              expect(deployment.last_healthy_at).to eq(deployment.created_at)
              expect(deployment.strategy).to eq('canary')
              expect(deployment.max_in_flight).to eq(3)
            end

            it 'records an audit event for the deployment' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

              event = VCAP::CloudController::Event.find(type: 'audit.app.deployment.create')
              expect(event).not_to be_nil
              expect(event.actor).to eq('123')
              expect(event.actor_type).to eq('user')
              expect(event.actor_name).to eq('connor@example.com')
              expect(event.actor_username).to eq('braa')
              expect(event.actee).to eq(app.guid)
              expect(event.actee_type).to eq('app')
              expect(event.actee_name).to eq(app.name)
              expect(event.timestamp).to be
              expect(event.space_guid).to eq(app.space_guid)
              expect(event.organization_guid).to eq(app.space.organization.guid)
              expect(event.metadata).to eq({
                                             'droplet_guid' => next_droplet.guid,
                                             'deployment_guid' => deployment.guid,
                                             'type' => nil,
                                             'revision_guid' => app.latest_revision.guid,
                                             'request' => message.audit_hash,
                                             'strategy' => 'canary'
                                           })
            end

            context 'when the message specifies metadata' do
              let(:message) do
                DeploymentCreateMessage.new({
                                              'metadata' => {
                                                labels: {
                                                  release: 'stable',
                                                  'seriouseats.com/potato': 'mashed'
                                                },
                                                annotations: {
                                                  superhero: 'Bummer-boy',
                                                  superpower: 'Bums you out'
                                                }
                                              }
                                            })
              end

              it 'saves the metadata to the new deployment' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

                expect(deployment).to have_labels(
                  { prefix: 'seriouseats.com', key_name: 'potato', value: 'mashed' },
                  { prefix: nil, key_name: 'release', value: 'stable' }
                )
                expect(deployment).to have_annotations(
                  { key_name: 'superhero', value: 'Bummer-boy' },
                  { key_name: 'superpower', value: 'Bums you out' }
                )
              end
            end

            context 'uses the max_in_flight from the message' do
              let(:max_in_flight) { 12 }

              it 'saves the max_in_flight' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.max_in_flight).to eq(12)
              end
            end

            context 'uses the web_instances from the message' do
              # stopped apps come up immediately and don't go through the deployment updater
              let(:web_instances) { 12 }

              it 'saves the web_instances' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.web_instances).to eq(12)
                expect(app.reload.newest_web_process.instances).to eq(12)
              end

              context 'when web_instances is not set' do
                let(:web_instances) { nil }

                it 'sets web_instances to nil' do
                  deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                  expect(deployment.web_instances).to be_nil
                  expect(app.reload.newest_web_process.instances).to eq(3)
                end
              end

              context 'quota validations' do
                let!(:web_process) { ProcessModel.make(app: app, instances: 3, memory: 999) }

                before do
                  app.organization.quota_definition = QuotaDefinition.make(app.organization, memory_limit: 10_000)
                  app.organization.save
                end

                context 'when the final state of the resulting web_process will violate a quota' do
                  let(:web_instances) { 11 }

                  it 'throws an error' do
                    expect { DeploymentCreate.create(app:, message:, user_audit_info:) }.to raise_error(DeploymentCreate::Error, 'memory quota_exceeded')
                  end
                end

                context 'when the final state of the resulting web_process does not violate a quota' do
                  let(:web_instances) { 10 }

                  it 'does not throw an error' do
                    deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                    expect(deployment.web_instances).to eq(10)
                  end
                end
              end
            end

            context 'uses the memory_in_mb from the message' do
              let(:memory_in_mb) { 1000 }

              it 'saves the memory_in_mb' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.memory_in_mb).to eq(1000)
                expect(app.reload.newest_web_process.memory).to eq(1000)
              end

              context 'when memory_in_mb is not set' do
                let(:memory_in_mb) { nil }

                it 'sets web_instances to the original web process\'s instance count' do
                  deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                  expect(deployment.memory_in_mb).to be_nil
                  expect(app.reload.newest_web_process.memory).to eq(500)
                end
              end

              context 'quota validations' do
                let!(:web_process) { ProcessModel.make(app: app, instances: 3, memory: 999) }

                before do
                  app.organization.quota_definition = QuotaDefinition.make(app.organization, memory_limit: 10_000)
                  app.organization.save
                end

                context 'when the final state of the resulting web_process will violate a quota' do
                  let(:memory_in_mb) { 4000 }

                  it 'throws an error' do
                    expect { DeploymentCreate.create(app:, message:, user_audit_info:) }.to raise_error(DeploymentCreate::Error, 'memory quota_exceeded')
                  end
                end

                context 'when the final state of the resulting web_process does not violate a quota' do
                  let(:memory_in_mb) { 3000 }

                  it 'does not throw an error' do
                    deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                    expect(deployment.memory_in_mb).to eq(3000)
                    expect(app.reload.newest_web_process.memory).to eq(3000)
                  end
                end
              end
            end

            context 'uses canary steps from the message' do
              let(:strategy) { 'canary' }

              before do
                message.options[:canary] = {
                  steps: [
                    { instance_weight: 40 },
                    { instance_weight: 80 }
                  ]
                }
              end

              it 'saves the canary steps' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                deployment.reload
                expect(deployment.canary_steps).to eq([{ 'instance_weight' => 40 }, { 'instance_weight' => 80 }])
              end
            end

            context 'when the app fails to start' do
              before do
                allow(VCAP::CloudController::AppStart).to receive(:start).and_raise(VCAP::CloudController::AppStart::InvalidApp.new('memory quota_exceeded'))
              end

              it 'raises a DeploymentCreate::Error' do
                expect { DeploymentCreate.create(app:, message:, user_audit_info:) }.to raise_error(DeploymentCreate::Error, 'memory quota_exceeded')
              end
            end
          end
        end

        context 'when the same droplet is provided (zdt-restart)' do
          let!(:revision) do
            RevisionModel.make(app: app, droplet_guid: app.droplet_guid)
          end

          it 'does NOT creates a revision' do
            web_process.update(revision:)
            app.update(revisions_enabled: true)

            expect do
              DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)
            end.not_to(change(RevisionModel, :count))

            deploying_web_process = app.reload.newest_web_process
            expect(deploying_web_process.revision.guid).to eq(revision.guid)
          end

          context 'but the environment variables have changed' do
            let(:new_environment_variables) do
              {
                'new-key' => 'another-new-value'
              }
            end

            it 'does create a new revision' do
              web_process.update(revision:)
              app.update(revisions_enabled: true)
              app.update(environment_variables: new_environment_variables)

              expect do
                DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)
              end.to change(RevisionModel, :count).by(1)

              current_revision = RevisionModel.last
              expect(current_revision.droplet_guid).to eq(revision.droplet_guid)
              expect(current_revision.environment_variables).to eq(new_environment_variables)
              expect(current_revision.environment_variables).not_to eq(revision.environment_variables)

              deploying_web_process = app.reload.newest_web_process
              expect(deploying_web_process.revision).to eq(app.reload.latest_revision)
            end
          end

          context 'but the process commands have changed' do
            let(:new_command) { 'foo rack' }

            it 'does create a new revision' do
              web_process.update(command: new_command)
              app.update(revisions_enabled: true)

              expect do
                DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)
              end.to change(RevisionModel, :count).by(1)

              current_revision = RevisionModel.last
              expect(current_revision.droplet_guid).to eq(revision.droplet_guid)
              expect(current_revision.commands_by_process_type['web']).to eq('foo rack')

              deploying_web_process = app.reload.newest_web_process
              expect(deploying_web_process.revision).to eq(app.reload.latest_revision)
            end

            it 'creates another revision from the newest web_process command' do
              web_process.update(command: new_command)
              app.update(revisions_enabled: true)

              expect do
                DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)
                app.reload.newest_web_process.update(command: 'something else')
                app.reload
                DeploymentCreate.create(app: app, message: restart_message, user_audit_info: user_audit_info)
              end.to change(RevisionModel, :count).by(2)

              expect(app.reload.newest_web_process.command).to eq 'something else'
            end
          end

          context 'when the message specifies max_in_flight' do
            let(:message) do
              DeploymentCreateMessage.new(options: { max_in_flight: 10 })
            end

            it 'saves the max_in_flight' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              expect(deployment.max_in_flight).to eq(10)
            end
          end

          context 'when the message does not specify max_in_flight' do
            let(:message) do
              DeploymentCreateMessage.new({})
            end

            it 'sets the default' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              expect(deployment.max_in_flight).to eq(1)
            end
          end

          context 'uses the web_instances from the message' do
            let(:web_instances) { 12 }

            it 'saves the web_instances' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              expect(deployment.web_instances).to eq(12)
            end

            context 'when web_instances is not set' do
              let(:web_instances) { nil }

              it 'sets web_instances to nil' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.web_instances).to be_nil
              end
            end

            context 'when max_in_flight instances is higher than web_instances' do
              let(:web_instances) { 10 }
              let(:max_in_flight) { 200 }
              let(:original_instances) { 5 }

              it 'creates a web process with web_instances, not original_instances or max_in_flight' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.deploying_web_process.instances).to eq(10)
              end
            end

            context 'web_instances is lower than original_instances' do
              let(:web_instances) { 5 }
              let(:max_in_flight) { 200 }
              let(:original_instances) { 10 }

              it 'creates a web process with web_instances, not original_instances or max_in_flight' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.deploying_web_process.instances).to eq(5)
              end
            end

            context 'quota validations' do
              let!(:web_process) { ProcessModel.make(app: app, instances: 3, memory: 999, state: 'STOPPED') }

              before do
                app.organization.quota_definition = QuotaDefinition.make(app.organization, memory_limit: 10_000)
                app.organization.save
              end

              context 'when the final state of the resulting web_process will violate a quota' do
                let(:web_instances) { 11 }

                it 'throws an error' do
                  expect { DeploymentCreate.create(app:, message:, user_audit_info:) }.to raise_error(DeploymentCreate::Error, 'memory quota_exceeded')
                end
              end

              context 'when the final state of the resulting web_process does not violate a quota' do
                let(:web_instances) { 10 }

                it 'does not throw an error' do
                  deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                  expect(deployment.web_instances).to eq(10)
                end
              end

              context 'when checking quota validations' do
                let(:web_instances) { 10 }

                it 'doesnt alter the state of the current web process' do
                  DeploymentCreate.create(app:, message:, user_audit_info:)
                  expect(app.newest_web_process.instances).to eq(3)
                end
              end
            end
          end

          context 'uses the memory_in_mb from the message' do
            let(:memory_in_mb) { 1000 }

            it 'saves the memory_in_mb' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              expect(deployment.memory_in_mb).to eq(1000)
              expect(app.reload.newest_web_process.memory).to eq(1000)
            end

            context 'when memory_in_mb is not set' do
              let(:memory_in_mb) { nil }

              it 'sets web_instances to the original web process\'s instance count' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.memory_in_mb).to be_nil
                expect(app.reload.newest_web_process.memory).to eq(500)
              end
            end

            context 'quota validations' do
              let!(:web_process) { ProcessModel.make(app: app, instances: 3, memory: 999, state: process_state) }

              before do
                app.organization.quota_definition = QuotaDefinition.make(app.organization, memory_limit: 10_000)
                app.organization.save
              end

              context 'when the final state of the resulting web_process will violate a quota' do
                let(:memory_in_mb) { 4000 }

                it 'throws an error' do
                  expect { DeploymentCreate.create(app:, message:, user_audit_info:) }.to raise_error(DeploymentCreate::Error, 'memory quota_exceeded')
                end
              end

              context 'when the final state of the resulting web_process does not violate a quota' do
                let(:memory_in_mb) { 3000 }

                it 'does not throw an error' do
                  deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                  expect(deployment.memory_in_mb).to eq(3000)
                  expect(app.reload.newest_web_process.memory).to eq(3000)
                end
              end
            end
          end

          context 'uses the disk_in_mb from the message' do
            let(:disk_in_mb) { 1000 }

            it 'saves the disk_in_mb' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              expect(deployment.disk_in_mb).to eq(1000)
              expect(app.reload.newest_web_process.disk_quota).to eq(1000)
            end

            context 'when disk_in_mb is not set' do
              let(:disk_in_mb) { nil }

              it 'sets web_instances to the original web process\'s instance count' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.disk_in_mb).to be_nil
                expect(app.reload.newest_web_process.disk_quota).to eq(1024)
              end
            end

            context 'quota validations' do
              let!(:web_process) { ProcessModel.make(app: app, instances: 3, disk_quota: 999, state: process_state) }

              before do
                TestConfig.override(maximum_app_disk_in_mb: 1000)
              end

              context 'when the final state of the resulting web_process will violate a quota' do
                let(:disk_in_mb) { 4000 }

                it 'throws an error' do
                  expect do
                    DeploymentCreate.create(app:, message:,
                                            user_audit_info:)
                  end.to raise_error(DeploymentCreate::Error, 'disk_quota too much disk requested (requested 4000 MB - must be less than 1000 MB)')
                end
              end

              context 'when the final state of the resulting web_process does not violate a quota' do
                let(:disk_in_mb) { 999 }

                it 'does not throw an error' do
                  deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                  expect(deployment.disk_in_mb).to eq(999)
                  expect(app.reload.newest_web_process.disk_quota).to eq(999)
                end
              end
            end
          end

          context 'uses the log_rate_limit_in_bytes_per_second from the message' do
            let(:log_rate_limit_in_bytes_per_second) { 1000 }

            it 'saves the log_rate_limit_in_bytes_per_second' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              expect(deployment.log_rate_limit_in_bytes_per_second).to eq(1000)
              expect(app.reload.newest_web_process.log_rate_limit).to eq(1000)
            end

            context 'when log_rate_limit_in_bytes_per_second is not set' do
              let(:log_rate_limit_in_bytes_per_second) { nil }

              it 'sets web_instances to the original web process\'s instance count' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment.log_rate_limit_in_bytes_per_second).to be_nil
                expect(app.reload.newest_web_process.log_rate_limit).to eq(101)
              end
            end

            context 'quota validations' do
              let!(:web_process) { ProcessModel.make(app: app, instances: 3, log_rate_limit: 999, memory: 999, state: process_state) }

              before do
                app.organization.quota_definition = QuotaDefinition.make(app.organization, log_rate_limit: 10_000)
                app.organization.save
              end

              context 'when the final state of the resulting web_process will violate a quota' do
                let(:log_rate_limit_in_bytes_per_second) { 4000 }

                it 'throws an error' do
                  expect { DeploymentCreate.create(app:, message:, user_audit_info:) }.to raise_error(DeploymentCreate::Error, 'log_rate_limit exceeds organization log rate quota')
                end
              end

              context 'when the final state of the resulting web_process does not violate a quota' do
                let(:log_rate_limit_in_bytes_per_second) { 3000 }

                it 'does not throw an error' do
                  deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                  expect(deployment.log_rate_limit_in_bytes_per_second).to eq(3000)
                  expect(app.reload.newest_web_process.log_rate_limit).to eq(3000)
                end
              end
            end
          end

          context 'when the app is stopped' do
            before do
              app.update(desired_state: ProcessModel::STOPPED)
              app.save
            end

            it 'starts the app' do
              DeploymentCreate.create(app:, message:, user_audit_info:)

              expect(app.reload.desired_state).to eq(ProcessModel::STARTED)
            end

            it 'creates a deployment with the provided droplet in DEPLOYED state' do
              deployment = nil

              expect do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              end.to change(DeploymentModel, :count).by(1)

              expect(deployment.state).to eq(DeploymentModel::DEPLOYED_STATE)
              expect(deployment.app_guid).to eq(app.guid)
              expect(deployment.droplet_guid).to eq(next_droplet.guid)
              expect(deployment.previous_droplet).to eq(original_droplet)
              expect(deployment.original_web_process_instance_count).to eq(3)
              expect(deployment.last_healthy_at).to eq(deployment.created_at)
            end

            it 'records an audit event for the deployment' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

              event = VCAP::CloudController::Event.find(type: 'audit.app.deployment.create')
              expect(event).not_to be_nil
              expect(event.actor).to eq('123')
              expect(event.actor_type).to eq('user')
              expect(event.actor_name).to eq('connor@example.com')
              expect(event.actor_username).to eq('braa')
              expect(event.actee).to eq(app.guid)
              expect(event.actee_type).to eq('app')
              expect(event.actee_name).to eq(app.name)
              expect(event.timestamp).to be
              expect(event.space_guid).to eq(app.space_guid)
              expect(event.organization_guid).to eq(app.space.organization.guid)
              expect(event.metadata).to eq({
                                             'droplet_guid' => next_droplet.guid,
                                             'deployment_guid' => deployment.guid,
                                             'type' => nil,
                                             'revision_guid' => app.latest_revision.guid,
                                             'request' => message.audit_hash,
                                             'strategy' => 'rolling'
                                           })
            end

            context 'when the message specifies metadata' do
              let(:message) do
                DeploymentCreateMessage.new({
                                              'metadata' => {
                                                labels: {
                                                  release: 'stable',
                                                  'seriouseats.com/potato': 'mashed'
                                                },
                                                annotations: {
                                                  superhero: 'Bummer-boy',
                                                  superpower: 'Bums you out'
                                                }
                                              }
                                            })
              end

              it 'saves the metadata to the new deployment' do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
                expect(deployment).to have_labels(
                  { prefix: 'seriouseats.com', key_name: 'potato', value: 'mashed' },
                  { prefix: nil, key_name: 'release', value: 'stable' }
                )
                expect(deployment).to have_annotations(
                  { key_name: 'superhero', value: 'Bummer-boy' },
                  { key_name: 'superpower', value: 'Bums you out' }
                )
              end
            end
          end
        end
      end

      context 'when a revision is provided on the message (rollback)' do
        let(:revision_droplet) { DropletModel.make(app: app, process_types: { 'web' => '1234' }) }
        let(:rollback_droplet) { DropletModel.make(app: app, process_types: { 'web' => '5678' }) }

        let!(:rollback_revision) do
          RevisionModel.make(
            app_guid: app.guid,
            description: 'rollback revision',
            droplet_guid: rollback_droplet.guid,
            environment_variables: { 'foo' => 'var2' },
            version: 2
          )
        end

        let!(:revision) do
          RevisionModel.make(
            app_guid: app.guid,
            description: 'latest revision',
            droplet_guid: revision_droplet.guid,
            environment_variables: { 'foo' => 'var' },
            version: 3
          )
        end

        let(:message) do
          DeploymentCreateMessage.new({
                                        relationships: { app: { data: { guid: app.guid } } },
                                        revision: { guid: rollback_revision.guid }
                                      })
        end

        before do
          app.update(revisions_enabled: true)
        end

        it 'creates a deployment with the droplet associated with the given revision' do
          deployment = nil

          expect do
            deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
          end.to change(DeploymentModel, :count).by(1)

          expect(deployment.state).to eq(DeploymentModel::DEPLOYING_STATE)
          expect(deployment.app_guid).to eq(app.guid)
          expect(deployment.droplet_guid).to eq(rollback_droplet.guid)
          expect(deployment.previous_droplet).to eq(original_droplet)
          expect(deployment.original_web_process_instance_count).to eq(3)
        end

        it 'creates a revision associated with the droplet from the associated revision' do
          expect do
            DeploymentCreate.create(app:, message:, user_audit_info:)
          end.to change(RevisionModel, :count).by(1)

          revision = RevisionModel.last
          expect(revision.droplet_guid).to eq(rollback_droplet.guid)

          deploying_web_process = app.reload.newest_web_process
          expect(deploying_web_process.revision).to eq(app.latest_revision)
        end

        it 'sets the current droplet of the app to be the droplet associated with the revision' do
          DeploymentCreate.create(app:, message:, user_audit_info:)

          expect(app.droplet).to eq(rollback_droplet)
        end

        it 'sets the environment variables of the app to those of the associated revision' do
          DeploymentCreate.create(app:, message:, user_audit_info:)

          expect(app.environment_variables).to eq({ 'foo' => 'var2' })
        end

        context 'when the revision has an process command that didnt come from its droplet' do
          before do
            rollback_revision.process_commands_dataset.first(process_type: 'web').update(process_command: 'bundle exec earlier_app')
          end

          it 'sets the process command of the new web process to that of the associated revision' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            expect(app.reload.newest_web_process.command).to eq('bundle exec earlier_app')
          end
        end

        it 'creates a revision associated with the environment variables of the associated revision' do
          expect do
            DeploymentCreate.create(app:, message:, user_audit_info:)
          end.to change(RevisionModel, :count).by(1)

          revision = RevisionModel.last
          expect(revision.environment_variables).to eq({ 'foo' => 'var2' })

          deploying_web_process = app.reload.newest_web_process
          expect(deploying_web_process.revision).to eq(app.latest_revision)
        end

        it 'sets the rollback description' do
          DeploymentCreate.create(app:, message:, user_audit_info:)
          revision = RevisionModel.last
          expect(revision.description).to include('Rolled back to revision 2.')
        end

        it 'records a rollback deployment event' do
          deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

          event = VCAP::CloudController::Event.find(type: 'audit.app.deployment.create')
          expect(event).not_to be_nil
          expect(event.actor).to eq('123')
          expect(event.actor_type).to eq('user')
          expect(event.actor_name).to eq('connor@example.com')
          expect(event.actor_username).to eq('braa')
          expect(event.actee).to eq(app.guid)
          expect(event.actee_type).to eq('app')
          expect(event.actee_name).to eq(app.name)
          expect(event.timestamp).to be
          expect(event.space_guid).to eq(app.space_guid)
          expect(event.organization_guid).to eq(app.space.organization.guid)
          expect(event.metadata).to eq({
                                         'droplet_guid' => rollback_droplet.guid,
                                         'deployment_guid' => deployment.guid,
                                         'type' => 'rollback',
                                         'revision_guid' => RevisionModel.last.guid,
                                         'request' => message.audit_hash,
                                         'strategy' => 'rolling'
                                       })
        end

        it 'fails if the droplet does not exist' do
          rollback_droplet.delete

          expect do
            DeploymentCreate.create(app:, message:, user_audit_info:)
          end.to raise_error(DeploymentCreate::Error, /Unable to deploy this revision, the droplet for this revision no longer exists./)
        end

        it 'fails if the droplet is expired' do
          rollback_droplet.update(state: DropletModel::EXPIRED_STATE)

          expect do
            DeploymentCreate.create(app:, message:, user_audit_info:)
          end.to raise_error(DeploymentCreate::Error, /Unable to deploy this revision, the droplet for this revision no longer exists./)
        end

        context 'when trying to roll back to a revision where the code and config has not changed' do
          let!(:initial_revision) do
            RevisionModel.make(
              app_guid: app.guid,
              droplet_guid: revision.droplet_guid,
              environment_variables: revision.environment_variables,
              version: 1
            )
          end

          let(:message) do
            DeploymentCreateMessage.new({
                                          relationships: { app: { data: { guid: app.guid } } },
                                          revision: { guid: initial_revision.guid }
                                        })
          end

          it 'raises a DeploymentCreate::Error with the correct message' do
            expect do
              expect do
                DeploymentCreate.create(app:, message:, user_audit_info:)
              end.to raise_error(DeploymentCreate::Error, 'Unable to rollback. The code and configuration you are rolling back to is the same as the deployed revision.')
            end.not_to(change(RevisionModel, :count))
          end
        end

        context 'when the app is stopped' do
          before do
            app.update(desired_state: ProcessModel::STOPPED)
            app.save
          end

          it 'sets the current droplet of the app to be the droplet associated with the revision' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            expect(app.droplet).to eq(rollback_droplet)
          end

          it 'starts the app' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            expect(app.reload.desired_state).to eq(ProcessModel::STARTED)
          end

          it 'creates a deployment with the provided droplet in DEPLOYED state' do
            deployment = nil

            expect do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(DeploymentModel, :count).by(1)

            expect(deployment.state).to eq(DeploymentModel::DEPLOYED_STATE)
            expect(deployment.app_guid).to eq(app.guid)
            expect(deployment.droplet_guid).to eq(rollback_droplet.guid)
            expect(deployment.previous_droplet).to eq(original_droplet)
            expect(deployment.original_web_process_instance_count).to eq(3)
            expect(deployment.last_healthy_at).to eq(deployment.created_at)
          end

          it 'records an audit event for the deployment' do
            deployment = DeploymentCreate.create(app:, message:, user_audit_info:)

            revision = RevisionModel.last
            event = VCAP::CloudController::Event.find(type: 'audit.app.deployment.create')
            expect(event).not_to be_nil
            expect(event.actor).to eq('123')
            expect(event.actor_type).to eq('user')
            expect(event.actor_name).to eq('connor@example.com')
            expect(event.actor_username).to eq('braa')
            expect(event.actee).to eq(app.guid)
            expect(event.actee_type).to eq('app')
            expect(event.actee_name).to eq(app.name)
            expect(event.timestamp).to be
            expect(event.space_guid).to eq(app.space_guid)
            expect(event.organization_guid).to eq(app.space.organization.guid)
            expect(event.metadata).to eq({
                                           'droplet_guid' => rollback_droplet.guid,
                                           'deployment_guid' => deployment.guid,
                                           'type' => 'rollback',
                                           'revision_guid' => revision.guid,
                                           'request' => message.audit_hash,
                                           'strategy' => 'rolling'
                                         })
          end

          context 'when the message specifies metadata' do
            let(:message) do
              DeploymentCreateMessage.new({
                                            'metadata' => {
                                              labels: {
                                                release: 'stable',
                                                'seriouseats.com/potato': 'mashed'
                                              },
                                              annotations: {
                                                superhero: 'Bummer-boy',
                                                superpower: 'Bums you out'
                                              }
                                            }
                                          })
            end

            it 'saves the metadata to the new deployment' do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              expect(deployment).to have_labels(
                { prefix: 'seriouseats.com', key_name: 'potato', value: 'mashed' },
                { prefix: nil, key_name: 'release', value: 'stable' }
              )
              expect(deployment).to have_annotations(
                { key_name: 'superhero', value: 'Bummer-boy' },
                { key_name: 'superpower', value: 'Bums you out' }
              )
            end
          end
        end
      end

      context 'strategy' do
        context 'when the strategy is rolling' do
          let(:strategy) { 'rolling' }
          let(:max_in_flight) { 2 }

          it 'creates the deployment with the rolling strategy' do
            deployment = nil

            expect do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(DeploymentModel, :count).by(1)

            expect(deployment.strategy).to eq(DeploymentModel::ROLLING_STRATEGY)
          end

          it 'creates a process with max_in_flight instances' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            deploying_web_process = app.reload.newest_web_process
            expect(deploying_web_process.instances).to eq(2)
          end

          it 'sets the deployment state to DEPLOYING' do
            deployment = nil

            expect do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(DeploymentModel, :count).by(1)

            expect(deployment.state).to eq(DeploymentModel::DEPLOYING_STATE)
          end

          context 'when max_in_flight is more than desired instances' do
            let(:max_in_flight) { 100 }

            it 'creates a process with number of desired instances' do
              DeploymentCreate.create(app:, message:, user_audit_info:)

              deploying_web_process = app.reload.newest_web_process
              expect(deploying_web_process.instances).to eq(3)
            end
          end
        end

        context 'when the strategy is canary' do
          let(:strategy) { 'canary' }

          it 'creates the deployment with the canary strategy' do
            deployment = nil

            expect do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(DeploymentModel, :count).by(1)

            expect(deployment.strategy).to eq(DeploymentModel::CANARY_STRATEGY)
          end

          it 'creates a process with a single canary instance' do
            DeploymentCreate.create(app:, message:, user_audit_info:)

            deploying_web_process = app.reload.newest_web_process
            expect(deploying_web_process.instances).to eq(1)
          end

          it 'sets the deployment state to PREPAUSED' do
            deployment = nil

            expect do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(DeploymentModel, :count).by(1)

            expect(deployment.state).to eq(DeploymentModel::PREPAUSED_STATE)
          end

          context 'and there are canary options with steps' do
            let(:message) do
              DeploymentCreateMessage.new({
                                            relationships: { app: { data: { guid: app.guid } } },
                                            droplet: { guid: next_droplet.guid },
                                            strategy: strategy,
                                            options: {
                                              max_in_flight: max_in_flight,
                                              canary: { steps: [{ instance_weight: 33 }, { instance_weight: 99 }] }
                                            }
                                          })
            end

            it 'sets the deployment canary steps' do
              deployment = nil

              expect do
                deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
              end.to change(DeploymentModel, :count).by(1)

              deployment.reload

              expect(deployment.canary_steps).to eq([{ 'instance_weight' => 33 }, { 'instance_weight' => 99 }])
            end

            it 'sets starting instances to max in flight' do
              DeploymentCreate.create(app:, message:, user_audit_info:)

              deploying_web_process = app.reload.newest_web_process
              expect(deploying_web_process.instances).to eq(1)
            end

            context 'when max_in_flight is more than first canary step' do
              let!(:max_in_flight) { 100 }

              it 'creates a process with first canary step' do
                DeploymentCreate.create(app:, message:, user_audit_info:)

                deploying_web_process = app.reload.newest_web_process
                expect(deploying_web_process.instances).to eq(1)
              end
            end
          end
        end

        context 'when the strategy is nil' do
          let(:strategy) { nil }

          it 'defaults to the rolling strategy' do
            deployment = nil

            expect do
              deployment = DeploymentCreate.create(app:, message:, user_audit_info:)
            end.to change(DeploymentModel, :count).by(1)

            expect(deployment.strategy).to eq(DeploymentModel::ROLLING_STRATEGY)
          end
        end
      end
    end
  end
end
