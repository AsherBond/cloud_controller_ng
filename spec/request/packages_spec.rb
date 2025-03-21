require 'spec_helper'
require 'request_spec_shared_examples'

RSpec.describe 'Packages' do
  let(:email) { 'potato@house.com' }
  let(:user) { VCAP::CloudController::User.make }
  let(:user_name) { 'clarence' }
  let(:user_header) { headers_for(user, email:, user_name:) }
  let(:org) { VCAP::CloudController::Organization.make(created_at: 3.days.ago) }
  let(:space) { VCAP::CloudController::Space.make(organization: org) }
  let(:space_guid) { space.guid }
  let(:app_model) { VCAP::CloudController::AppModel.make(:docker, space_guid:) }

  describe 'POST /v3/packages' do
    let(:guid) { app_model.guid }

    before do
      space.organization.add_user(user)
      space.add_developer(user)
    end

    let(:type) { 'docker' }
    let(:data) { { image: 'registry/image:latest', username: 'my-docker-username', password: 'my-password' } }
    let(:expected_data) { { image: 'registry/image:latest', username: 'my-docker-username', password: '***' } }
    let(:relationships) { { app: { data: { guid: app_model.guid } } } }
    let(:metadata) do
      {
        labels: {
          release: 'stable',
          'seriouseats.com/potato' => 'mashed'
        },
        annotations: {
          potato: 'idaho'
        }
      }
    end

    describe 'creation' do
      it 'creates a package' do
        expect do
          post '/v3/packages', { type:, data:, relationships:, metadata: }.to_json, user_header
        end.to change(VCAP::CloudController::PackageModel, :count).by(1)

        package = VCAP::CloudController::PackageModel.last

        expected_response = {
          'guid' => package.guid,
          'type' => type,
          'data' => {
            'image' => 'registry/image:latest',
            'username' => 'my-docker-username',
            'password' => '***'
          },
          'state' => 'READY',
          'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
          'metadata' => { 'labels' => { 'release' => 'stable', 'seriouseats.com/potato' => 'mashed' }, 'annotations' => { 'potato' => 'idaho' } },
          'created_at' => iso8601,
          'updated_at' => iso8601,
          'links' => {
            'self' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}" },
            'app' => { 'href' => "#{link_prefix}/v3/apps/#{guid}" }
          }
        }

        expected_event_metadata = {
          package_guid: package.guid,
          request: {
            type: type,
            data: expected_data,
            relationships: relationships,
            metadata: metadata
          }
        }.to_json

        parsed_response = Oj.load(last_response.body)
        expect(last_response.status).to eq(201)
        expect(parsed_response).to be_a_response_like(expected_response)

        event = VCAP::CloudController::Event.last
        expect(event.values).to include({
                                          type: 'audit.app.package.create',
                                          actor: user.guid,
                                          actor_type: 'user',
                                          actor_name: email,
                                          actor_username: user_name,
                                          actee: package.app.guid,
                                          actee_type: 'app',
                                          actee_name: package.app.name,
                                          metadata: expected_event_metadata,
                                          space_guid: space.guid,
                                          organization_guid: space.organization.guid
                                        })
      end

      context 'permissions' do
        before do
          space.remove_developer(user)
          space.organization.remove_user(user)
        end

        let(:api_call) { ->(user_headers) { post '/v3/packages', { type:, data:, relationships:, metadata: }.to_json, user_headers } }
        let(:space) { VCAP::CloudController::Space.make }
        let(:org) { space.organization }
        let(:user) { VCAP::CloudController::User.make }
        let(:expected_codes_and_responses) do
          h = Hash.new({ code: 201 }.freeze)
          h['org_auditor'] = { code: 422 }
          h['org_billing_manager'] = { code: 422 }
          h['no_role'] = { code: 422 }
          %w[admin_read_only global_auditor space_manager space_auditor org_manager space_supporter].each do |r|
            h[r] = { code: 403, errors: CF_NOT_AUTHORIZED }
          end
          h
        end

        it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS

        context 'when organization is suspended' do
          let(:expected_codes_and_responses) do
            h = super()
            h['space_developer'] = { code: 403, errors: CF_ORG_SUSPENDED }
            h
          end

          before do
            org.update(status: VCAP::CloudController::Organization::SUSPENDED)
          end

          it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
        end
      end
    end

    describe 'copying' do
      let!(:source_package) { VCAP::CloudController::PackageModel.make(type: 'docker', app_guid: app_model.guid, docker_image: 'http://awesome-sauce.com') }
      let(:target_space) { space }
      let(:target_org) { target_space.organization }
      let(:target_app) { VCAP::CloudController::AppModel.make(space: target_space) }

      it 'copies a package' do
        expect do
          post "/v3/packages?source_guid=#{source_package.guid}",
               {
                 relationships: {
                   app: { data: { guid: target_app.guid } }
                 }
               }.to_json,
               user_header
        end.to change(VCAP::CloudController::PackageModel, :count).by(1)

        package = VCAP::CloudController::PackageModel.last

        expected_response = {
          'guid' => package.guid,
          'type' => 'docker',
          'data' => {
            'image' => 'http://awesome-sauce.com',
            'username' => nil,
            'password' => nil
          },
          'state' => 'READY',
          'relationships' => { 'app' => { 'data' => { 'guid' => target_app.guid } } },
          'metadata' => { 'labels' => {}, 'annotations' => {} },
          'created_at' => iso8601,
          'updated_at' => iso8601,
          'links' => {
            'self' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}" },
            'app' => { 'href' => "#{link_prefix}/v3/apps/#{target_app.guid}" }
          }
        }

        expect(last_response.status).to eq(201)
        parsed_response = Oj.load(last_response.body)
        expect(parsed_response).to be_a_response_like(expected_response)

        expected_event_metadata = {
          package_guid: package.guid,
          request: {
            source_package_guid: source_package.guid
          }
        }.to_json

        event = VCAP::CloudController::Event.last
        expect(event.values).to include({
                                          type: 'audit.app.package.create',
                                          actor: user.guid,
                                          actor_type: 'user',
                                          actor_name: email,
                                          actor_username: user_name,
                                          actee: package.app.guid,
                                          actee_type: 'app',
                                          actee_name: package.app.name,
                                          metadata: expected_event_metadata,
                                          space_guid: space.guid,
                                          organization_guid: space.organization.guid
                                        })
      end

      context 'permissions' do
        before do
          space.remove_developer(user)
          space.organization.remove_user(user)
        end

        let(:api_call) do
          lambda { |user_headers|
            post "/v3/packages?source_guid=#{source_package.guid}",
                 {
                   relationships: {
                     app: { data: { guid: target_app.guid } }
                   }
                 }.to_json, user_headers
          }
        end
        let(:expected_codes_and_responses) do
          h = Hash.new({ code: 201 }.freeze)
          h['org_auditor'] = { code: 422 }
          h['org_billing_manager'] = { code: 422 }
          h['no_role'] = { code: 422 }
          %w[admin_read_only global_auditor space_manager space_auditor org_manager space_supporter].each do |r|
            h[r] = { code: 403, errors: CF_NOT_AUTHORIZED }
          end
          h
        end

        it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS

        context 'when target organization is suspended' do
          let(:expected_codes_and_responses) do
            h = super()
            h['space_developer'] = { code: 403, errors: CF_ORG_SUSPENDED }
            h
          end

          before do
            target_org.update(status: VCAP::CloudController::Organization::SUSPENDED)
          end

          it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
        end

        context 'when source organization is suspended' do
          let(:target_space) { VCAP::CloudController::Space.make(organization: VCAP::CloudController::Organization.make) }
          let(:source_org) { org }

          let(:expected_codes_and_responses) do
            h = super()
            h['space_developer'] = { code: 403, errors: CF_ORG_SUSPENDED }
            h
          end

          before do
            target_org.add_user(user)
            target_space.add_developer(user)
            source_org.update(status: VCAP::CloudController::Organization::SUSPENDED)
          end

          it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
        end
      end
    end
  end

  describe 'GET /v3/apps/:guid/packages' do
    let!(:package) { VCAP::CloudController::PackageModel.make(app_guid: app_model.guid) }
    let(:app_model) { VCAP::CloudController::AppModel.make(space_guid: space.guid) }
    let(:guid) { app_model.guid }
    let(:page) { 1 }
    let(:per_page) { 2 }
    let(:order_by) { '-created_at' }

    context 'when listing all packages for an app' do
      let(:api_call) { ->(user_headers) { get "/v3/apps/#{app_model.guid}/packages", nil, user_headers } }
      let(:packages_response_objects) do
        [
          {
            'guid' => package.guid,
            'type' => 'bits',
            'data' => {
              'checksum' => { 'type' => 'sha256', 'value' => anything },
              'error' => nil
            },
            'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
            'state' => VCAP::CloudController::PackageModel::CREATED_STATE,
            'metadata' => { 'labels' => {}, 'annotations' => {} },
            'created_at' => iso8601,
            'updated_at' => iso8601,
            'links' => {
              'self' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}" },
              'upload' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}/upload", 'method' => 'POST' },
              'download' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}/download" },
              'app' => { 'href' => "#{link_prefix}/v3/apps/#{guid}" }
            }
          }
        ]
      end

      let(:expected_codes_and_responses) do
        h = Hash.new({ code: 200, response_objects: packages_response_objects }.freeze)
        h['org_auditor'] = { code: 404 }
        h['org_billing_manager'] = { code: 404 }
        h['no_role'] = { code: 404 }
        h
      end

      it_behaves_like 'permissions for list endpoint', ALL_PERMISSIONS
    end

    context 'when listing paginated results of all packages for an app' do
      before do
        space.organization.add_user(user)
        space.add_developer(user)
      end

      it 'lists paginated results' do
        package2 = VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, created_at: package.created_at + 1.hour)

        expected_response = {
          'pagination' => {
            'total_results' => 2,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/apps/#{guid}/packages?order_by=-created_at&page=1&per_page=2" },
            'last' => { 'href' => "#{link_prefix}/v3/apps/#{guid}/packages?order_by=-created_at&page=1&per_page=2" },
            'next' => nil,
            'previous' => nil
          },
          'resources' => [
            {
              'guid' => package2.guid,
              'type' => 'bits',
              'data' => {
                'checksum' => { 'type' => 'sha256', 'value' => anything },
                'error' => nil
              },
              'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
              'state' => VCAP::CloudController::PackageModel::CREATED_STATE,
              'metadata' => { 'labels' => {}, 'annotations' => {} },
              'created_at' => iso8601,
              'updated_at' => iso8601,
              'links' => {
                'self' => { 'href' => "#{link_prefix}/v3/packages/#{package2.guid}" },
                'upload' => { 'href' => "#{link_prefix}/v3/packages/#{package2.guid}/upload", 'method' => 'POST' },
                'download' => { 'href' => "#{link_prefix}/v3/packages/#{package2.guid}/download" },
                'app' => { 'href' => "#{link_prefix}/v3/apps/#{guid}" }
              }
            },
            {
              'guid' => package.guid,
              'type' => 'bits',
              'data' => {
                'checksum' => { 'type' => 'sha256', 'value' => anything },
                'error' => nil
              },
              'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
              'state' => VCAP::CloudController::PackageModel::CREATED_STATE,
              'metadata' => { 'labels' => {}, 'annotations' => {} },
              'created_at' => iso8601,
              'updated_at' => iso8601,
              'links' => {
                'self' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}" },
                'upload' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}/upload", 'method' => 'POST' },
                'download' => { 'href' => "#{link_prefix}/v3/packages/#{package.guid}/download" },
                'app' => { 'href' => "#{link_prefix}/v3/apps/#{guid}" }
              }
            }
          ]
        }

        get "/v3/apps/#{guid}/packages?page=#{page}&per_page=#{per_page}&order_by=#{order_by}", {}, user_header

        parsed_response = Oj.load(last_response.body)

        expect(last_response.status).to eq(200)
        expect(parsed_response).to be_a_response_like(expected_response)
      end

      it_behaves_like 'list_endpoint_with_common_filters' do
        let(:resource_klass) { VCAP::CloudController::PackageModel }
        let(:api_call) do
          ->(headers, filters) { get "/v3/apps/#{guid}/packages?#{filters}", nil, headers }
        end
        let(:additional_resource_params) { { app: app_model } }
        let(:headers) { admin_headers }
      end
    end

    context 'when listing a subset of packages for an app' do
      before do
        space.organization.add_user(user)
        space.add_developer(user)
      end

      it 'filters by types' do
        VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: VCAP::CloudController::PackageModel::BITS_TYPE)
        VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: VCAP::CloudController::PackageModel::BITS_TYPE)
        VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: VCAP::CloudController::PackageModel::DOCKER_TYPE)
        VCAP::CloudController::PackageModel.make(type: VCAP::CloudController::PackageModel::BITS_TYPE)

        get '/v3/packages?types=bits', {}, user_header

        expected_pagination = {
          'total_results' => 3,
          'total_pages' => 1,
          'first' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&types=bits" },
          'last' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&types=bits" },
          'next' => nil,
          'previous' => nil
        }

        parsed_response = Oj.load(last_response.body)

        expect(last_response.status).to eq(200)
        expect(parsed_response['resources'].count).to eq(3)
        expect(parsed_response['resources'].pluck('type').uniq).to eq(['bits'])
        expect(parsed_response['pagination']).to eq(expected_pagination)
      end

      it 'filters by states' do
        VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, state: VCAP::CloudController::PackageModel::PENDING_STATE)
        VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, state: VCAP::CloudController::PackageModel::PENDING_STATE)
        VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, state: VCAP::CloudController::PackageModel::READY_STATE)
        VCAP::CloudController::PackageModel.make(state: VCAP::CloudController::PackageModel::PENDING_STATE)

        get "/v3/apps/#{app_model.guid}/packages?states=PROCESSING_UPLOAD", {}, user_header

        expected_pagination = {
          'total_results' => 2,
          'total_pages' => 1,
          'first' => { 'href' => "#{link_prefix}/v3/apps/#{app_model.guid}/packages?page=1&per_page=50&states=PROCESSING_UPLOAD" },
          'last' => { 'href' => "#{link_prefix}/v3/apps/#{app_model.guid}/packages?page=1&per_page=50&states=PROCESSING_UPLOAD" },
          'next' => nil,
          'previous' => nil
        }

        parsed_response = Oj.load(last_response.body)

        expect(last_response.status).to eq(200)
        expect(parsed_response['resources'].count).to eq(2)
        expect(parsed_response['resources'].pluck('state').uniq).to eq(['PROCESSING_UPLOAD'])
        expect(parsed_response['pagination']).to eq(expected_pagination)
      end

      it 'filters by package guids' do
        package1 = VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
        package2 = VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
        VCAP::CloudController::PackageModel.make

        get "/v3/apps/#{app_model.guid}/packages?guids=#{package1.guid},#{package2.guid}", {}, user_header

        expected_pagination = {
          'total_results' => 2,
          'total_pages' => 1,
          'first' => { 'href' => "#{link_prefix}/v3/apps/#{app_model.guid}/packages?guids=#{package1.guid}%2C#{package2.guid}&page=1&per_page=50" },
          'last' => { 'href' => "#{link_prefix}/v3/apps/#{app_model.guid}/packages?guids=#{package1.guid}%2C#{package2.guid}&page=1&per_page=50" },
          'next' => nil,
          'previous' => nil
        }

        parsed_response = Oj.load(last_response.body)

        expect(last_response.status).to eq(200)
        expect(parsed_response['resources'].pluck('guid')).to contain_exactly(package1.guid, package2.guid)
        expect(parsed_response['pagination']).to eq(expected_pagination)
      end
    end
  end

  describe 'GET /v3/packages' do
    let(:bits_type) { 'bits' }
    let(:docker_type) { 'docker' }
    let(:page) { 1 }
    let(:per_page) { 2 }
    let(:params) do
      {
        guids: %w[foo bar],
        space_guids: %w[foo bar],
        organization_guids: %w[foo bar],
        app_guids: %w[foo bar],
        states: %w[foo bar],
        types: %w[foo bar],
        page: '2',
        per_page: '10',
        order_by: 'updated_at',
        label_selector: 'foo,bar',
        created_ats: "#{Time.now.utc.iso8601},#{Time.now.utc.iso8601}",
        updated_ats: { gt: Time.now.utc.iso8601 }
      }
    end
    let(:bits_package) { VCAP::CloudController::PackageModel.make(type: bits_type, app_guid: app_model.guid) }
    let(:docker_package) do
      VCAP::CloudController::PackageModel.make(
        type: docker_type,
        app_guid: app_model.guid,
        state: VCAP::CloudController::PackageModel::READY_STATE,
        docker_image: 'http://location-of-image.com'
      )
    end
    let(:packages_response_objects) do
      [
        {
          'guid' => bits_package.guid,
          'type' => 'bits',
          'data' => {
            'checksum' => { 'type' => 'sha256', 'value' => anything },
            'error' => nil
          },
          'state' => VCAP::CloudController::PackageModel::CREATED_STATE,
          'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
          'metadata' => { 'labels' => {}, 'annotations' => {} },
          'created_at' => iso8601,
          'updated_at' => iso8601,
          'links' => {
            'self' => { 'href' => "#{link_prefix}/v3/packages/#{bits_package.guid}" },
            'upload' => { 'href' => "#{link_prefix}/v3/packages/#{bits_package.guid}/upload", 'method' => 'POST' },
            'download' => { 'href' => "#{link_prefix}/v3/packages/#{bits_package.guid}/download" },
            'app' => { 'href' => "#{link_prefix}/v3/apps/#{bits_package.app_guid}" }
          }
        },
        {
          'guid' => docker_package.guid,
          'type' => 'docker',
          'data' => {
            'image' => 'http://location-of-image.com',
            'username' => nil,
            'password' => nil
          },
          'state' => VCAP::CloudController::PackageModel::READY_STATE,
          'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
          'metadata' => { 'labels' => {}, 'annotations' => {} },
          'created_at' => iso8601,
          'updated_at' => iso8601,
          'links' => {
            'self' => { 'href' => "#{link_prefix}/v3/packages/#{docker_package.guid}" },
            'app' => { 'href' => "#{link_prefix}/v3/apps/#{docker_package.app_guid}" }
          }
        }
      ]
    end

    context 'when listing all packages' do
      let(:api_call) { ->(user_headers) { get '/v3/packages', { per_page: }, user_headers } }
      let(:message) { VCAP::CloudController::PackagesListMessage }
      let(:request) { '/v3/packages' }
      let(:excluded_params) do
        [
          :app_guid
        ]
      end

      let(:expected_codes_and_responses) do
        h = Hash.new({ code: 200, response_objects: packages_response_objects }.freeze)
        h['org_auditor'] = { code: 200, response_objects: [] }
        h['org_billing_manager'] = { code: 200, response_objects: [] }
        h['no_role'] = { code: 200, response_objects: [] }
        h
      end

      it_behaves_like 'permissions for list endpoint', ALL_PERMISSIONS
    end

    context 'when listing a subset of packages' do
      before do
        space.organization.add_user(user)
        space.add_developer(user)
      end

      it_behaves_like 'list query endpoint' do
        let(:message) { VCAP::CloudController::PackagesListMessage }
        let(:request) { '/v3/packages' }
        let(:excluded_params) do
          [
            :app_guid
          ]
        end
      end

      it_behaves_like 'list_endpoint_with_common_filters' do
        let(:resource_klass) { VCAP::CloudController::PackageModel }
        let(:api_call) do
          ->(headers, filters) { get "/v3/packages?#{filters}", nil, headers }
        end
        let(:headers) { admin_headers }
      end

      context 'faceted search' do
        it 'filters by types' do
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: VCAP::CloudController::PackageModel::BITS_TYPE)
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: VCAP::CloudController::PackageModel::BITS_TYPE)
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: VCAP::CloudController::PackageModel::DOCKER_TYPE)

          another_app_in_same_space = VCAP::CloudController::AppModel.make(space_guid:)
          VCAP::CloudController::PackageModel.make(app_guid: another_app_in_same_space.guid, type: VCAP::CloudController::PackageModel::BITS_TYPE)

          get '/v3/packages?types=bits', {}, user_header

          expected_pagination = {
            'total_results' => 3,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&types=bits" },
            'last' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&types=bits" },
            'next' => nil,
            'previous' => nil
          }

          parsed_response = Oj.load(last_response.body)

          expect(last_response.status).to eq(200)
          expect(parsed_response['resources'].count).to eq(3)
          expect(parsed_response['resources'].pluck('type').uniq).to eq(['bits'])
          expect(parsed_response['pagination']).to eq(expected_pagination)
        end

        it 'filters by states' do
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, state: VCAP::CloudController::PackageModel::PENDING_STATE)
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, state: VCAP::CloudController::PackageModel::PENDING_STATE)
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, state: VCAP::CloudController::PackageModel::READY_STATE)

          another_app_in_same_space = VCAP::CloudController::AppModel.make(space_guid:)
          VCAP::CloudController::PackageModel.make(app_guid: another_app_in_same_space.guid, state: VCAP::CloudController::PackageModel::PENDING_STATE)

          get '/v3/packages?states=PROCESSING_UPLOAD', {}, user_header

          expected_pagination = {
            'total_results' => 3,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&states=PROCESSING_UPLOAD" },
            'last' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&states=PROCESSING_UPLOAD" },
            'next' => nil,
            'previous' => nil
          }

          parsed_response = Oj.load(last_response.body)

          expect(last_response.status).to eq(200)
          expect(parsed_response['resources'].count).to eq(3)
          expect(parsed_response['resources'].pluck('state').uniq).to eq(['PROCESSING_UPLOAD'])
          expect(parsed_response['pagination']).to eq(expected_pagination)
        end

        it 'filters by app guids' do
          app_model2 = VCAP::CloudController::AppModel.make(space_guid:)
          package1 = VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
          package2 = VCAP::CloudController::PackageModel.make(app_guid: app_model2.guid)
          VCAP::CloudController::PackageModel.make

          get "/v3/packages?app_guids=#{app_model.guid},#{app_model2.guid}", {}, user_header

          expected_pagination = {
            'total_results' => 2,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/packages?app_guids=#{app_model.guid}%2C#{app_model2.guid}&page=1&per_page=50" },
            'last' => { 'href' => "#{link_prefix}/v3/packages?app_guids=#{app_model.guid}%2C#{app_model2.guid}&page=1&per_page=50" },
            'next' => nil,
            'previous' => nil
          }

          parsed_response = Oj.load(last_response.body)

          expect(last_response.status).to eq(200)
          expect(parsed_response['resources'].pluck('guid')).to contain_exactly(package1.guid, package2.guid)
          expect(parsed_response['pagination']).to eq(expected_pagination)
        end

        it 'filters by package guids' do
          app_model2 = VCAP::CloudController::AppModel.make(space_guid:)
          package1 = VCAP::CloudController::PackageModel.make(app_guid: app_model2.guid)
          package2 = VCAP::CloudController::PackageModel.make(app_guid: app_model2.guid)
          VCAP::CloudController::PackageModel.make

          get "/v3/packages?guids=#{package1.guid},#{package2.guid}", {}, user_header

          expected_pagination = {
            'total_results' => 2,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/packages?guids=#{package1.guid}%2C#{package2.guid}&page=1&per_page=50" },
            'last' => { 'href' => "#{link_prefix}/v3/packages?guids=#{package1.guid}%2C#{package2.guid}&page=1&per_page=50" },
            'next' => nil,
            'previous' => nil
          }

          parsed_response = Oj.load(last_response.body)

          expect(last_response.status).to eq(200)
          expect(parsed_response['resources'].pluck('guid')).to contain_exactly(package1.guid, package2.guid)
          expect(parsed_response['pagination']).to eq(expected_pagination)
        end

        it 'filters by space guids' do
          package_on_space1 = VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)

          space2 = VCAP::CloudController::Space.make(organization: space.organization)
          space2.add_developer(user)
          app_model2 = VCAP::CloudController::AppModel.make(space_guid: space2.guid)
          package_on_space2 = VCAP::CloudController::PackageModel.make(app_guid: app_model2.guid)

          space3 = VCAP::CloudController::Space.make(organization: space.organization)
          space3.add_developer(user)
          app_model3 = VCAP::CloudController::AppModel.make(space_guid: space3.guid)
          VCAP::CloudController::PackageModel.make(app_guid: app_model3.guid)

          get "/v3/packages?space_guids=#{space2.guid},#{space_guid}", {}, user_header

          expected_pagination = {
            'total_results' => 2,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&space_guids=#{space2.guid}%2C#{space_guid}" },
            'last' => { 'href' => "#{link_prefix}/v3/packages?page=1&per_page=50&space_guids=#{space2.guid}%2C#{space_guid}" },
            'next' => nil,
            'previous' => nil
          }

          parsed_response = Oj.load(last_response.body)

          expect(last_response.status).to eq(200)
          expect(parsed_response['resources'].pluck('guid')).to contain_exactly(package_on_space2.guid, package_on_space1.guid)
          expect(parsed_response['pagination']).to eq(expected_pagination)
        end

        it 'filters by org guids' do
          org1_guid = space.organization.guid

          package_in_org1 = VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)

          space2 = VCAP::CloudController::Space.make
          org2_guid = space2.organization.guid
          app_model2 = VCAP::CloudController::AppModel.make(space_guid: space2.guid)

          space2.organization.add_user(user)
          space2.add_developer(user)

          package_in_org2 = VCAP::CloudController::PackageModel.make(app_guid: app_model2.guid)

          space3 = VCAP::CloudController::Space.make
          space3.organization.add_user(user)
          space3.add_developer(user)
          app_model3 = VCAP::CloudController::AppModel.make(space_guid: space3.guid)
          VCAP::CloudController::PackageModel.make(app_guid: app_model3.guid)

          get "/v3/packages?organization_guids=#{org1_guid},#{org2_guid}", {}, user_header

          expected_pagination = {
            'total_results' => 2,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/packages?organization_guids=#{org1_guid}%2C#{org2_guid}&page=1&per_page=50" },
            'last' => { 'href' => "#{link_prefix}/v3/packages?organization_guids=#{org1_guid}%2C#{org2_guid}&page=1&per_page=50" },
            'next' => nil,
            'previous' => nil
          }

          parsed_response = Oj.load(last_response.body)

          expect(last_response.status).to eq(200)
          expect(parsed_response['resources'].pluck('guid')).to contain_exactly(package_in_org1.guid, package_in_org2.guid)
          expect(parsed_response['pagination']).to eq(expected_pagination)
        end

        it 'filters by label selectors' do
          target = VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
          VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
          VCAP::CloudController::PackageLabelModel.make(key_name: 'fruit', value: 'strawberry', package: target)

          get '/v3/packages?label_selector=fruit=strawberry', {}, user_header

          expected_pagination = {
            'total_results' => 1,
            'total_pages' => 1,
            'first' => { 'href' => "#{link_prefix}/v3/packages?label_selector=fruit%3Dstrawberry&page=1&per_page=50" },
            'last' => { 'href' => "#{link_prefix}/v3/packages?label_selector=fruit%3Dstrawberry&page=1&per_page=50" },
            'next' => nil,
            'previous' => nil
          }

          parsed_response = Oj.load(last_response.body)

          expect(last_response.status).to eq(200)
          expect(parsed_response['resources'].count).to eq(1)
          expect(parsed_response['resources'][0]['guid']).to eq(target.guid)
          expect(parsed_response['pagination']).to eq(expected_pagination)
        end
      end
    end
  end

  describe 'GET /v3/packages/:guid' do
    let(:api_call) { ->(user_headers) { get "v3/packages/#{guid}", nil, user_headers } }
    let(:package_model) do
      VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
    end
    let(:guid) { package_model.guid }
    let(:package_model_response_object) do
      {
        'type' => package_model.type,
        'guid' => guid,
        'data' => {
          'checksum' => { 'type' => 'sha256', 'value' => anything },
          'error' => nil
        },
        'state' => VCAP::CloudController::PackageModel::CREATED_STATE,
        'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
        'metadata' => { 'labels' => {}, 'annotations' => {} },
        'created_at' => iso8601,
        'updated_at' => iso8601,
        'links' => {
          'self' => { 'href' => "#{link_prefix}/v3/packages/#{guid}" },
          'upload' => { 'href' => "#{link_prefix}/v3/packages/#{guid}/upload", 'method' => 'POST' },
          'download' => { 'href' => "#{link_prefix}/v3/packages/#{guid}/download" },
          'app' => { 'href' => "#{link_prefix}/v3/apps/#{app_model.guid}" }
        }
      }
    end
    let(:expected_codes_and_responses) do
      h = Hash.new({ code: 200, response_object: package_model_response_object }.freeze)
      h['org_auditor'] = { code: 404 }
      h['org_billing_manager'] = { code: 404 }
      h['no_role'] = { code: 404 }
      h
    end

    it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
  end

  describe 'POST /v3/packages/:guid/upload' do
    let(:type) { 'bits' }
    let!(:package_model) do
      VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: type)
    end
    let(:space) { VCAP::CloudController::Space.make }
    let(:app_model) { VCAP::CloudController::AppModel.make(guid: 'woof', space_guid: space.guid, name: 'meow') }
    let(:guid) { package_model.guid }
    let(:tmpdir) { Dir.mktmpdir }
    let(:test_config_overrides) do
      { directories: { tmpdir: } }
    end
    let!(:tmpfile) do
      File.open(File.join(tmpdir, 'application.zip'), 'w+') do |f|
        f.write('application code')
        f
      end
    end

    let(:packages_params) do
      {
        bits_name: File.basename(tmpfile.path),
        bits_path: tmpfile.path
      }
    end

    before do
      space.organization.add_user(user)
      space.add_developer(user)
      TestConfig.override(**test_config_overrides)
    end

    shared_examples 'upload bits successfully' do
      it 'uploads the bits for the package' do
        expect(Delayed::Job.count).to eq 0

        post "/v3/packages/#{guid}/upload", packages_params.to_json, user_header

        expect(Delayed::Job.count).to eq 1

        expected_response = {
          'type' => package_model.type,
          'guid' => guid,
          'data' => {
            'checksum' => { 'type' => 'sha256', 'value' => anything },
            'error' => nil
          },
          'state' => VCAP::CloudController::PackageModel::PENDING_STATE,
          'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
          'metadata' => { 'labels' => {}, 'annotations' => {} },
          'created_at' => iso8601,
          'updated_at' => iso8601,
          'links' => {
            'self' => { 'href' => "#{link_prefix}/v3/packages/#{guid}" },
            'upload' => { 'href' => "#{link_prefix}/v3/packages/#{guid}/upload", 'method' => 'POST' },
            'download' => { 'href' => "#{link_prefix}/v3/packages/#{guid}/download" },
            'app' => { 'href' => "#{link_prefix}/v3/apps/#{app_model.guid}" }
          }
        }
        parsed_response = Oj.load(last_response.body)
        expect(last_response.status).to eq(200)
        expect(parsed_response).to be_a_response_like(expected_response)

        expected_metadata = { package_guid: package_model.guid }.to_json

        event = VCAP::CloudController::Event.last
        expect(event.values).to include({
                                          type: 'audit.app.package.upload',
                                          actor: user.guid,
                                          actor_type: 'user',
                                          actor_name: email,
                                          actor_username: user_name,
                                          actee: 'woof',
                                          actee_type: 'app',
                                          actee_name: 'meow',
                                          metadata: expected_metadata,
                                          space_guid: space.guid,
                                          organization_guid: space.organization.guid
                                        })
      end
    end

    context 'with v2 resources' do
      let(:packages_params) do
        {
          bits_name: 'application.zip',
          bits_path: "#{tmpdir}/application.zip",
          resources: '[{"fn":"path/to/content.txt","size":123,"sha1":"b907173290db6a155949ab4dc9b2d019dea0c901"},
                      {"fn":"path/to/code.jar","size":123,"sha1":"ff84f89760317996b9dd180ab996b079f418396f"},
                      {"fn":"path/to/code.jar","size":123,"sha1":"ff84f89760317996b9dd180ab996b079f418396f","mode":"644"}]'
        }
      end

      include_examples 'upload bits successfully'
    end

    context 'with v3 resources' do
      let(:packages_params) do
        {
          bits_name: 'application.zip',
          bits_path: "#{tmpdir}/application.zip",
          resources: '[{"path":"path/to/content.txt","size_in_bytes":123,"checksum": { "value" : "b907173290db6a155949ab4dc9b2d019dea0c901" }},
                      {"path":"path/to/code.jar","size_in_bytes":123,"checksum": { "value" : "ff84f89760317996b9dd180ab996b079f418396f" }},
                      {"path":"path/to/code.jar","size_in_bytes":123,"checksum": { "value" : "ff84f89760317996b9dd180ab996b079f418396f" },"mode":"644"}]'
        }
      end

      include_examples 'upload bits successfully'
    end

    context 'telemetry' do
      it 'logs the required fields when the package uploads' do
        Timecop.freeze do
          expected_json = {
            'telemetry-source' => 'cloud_controller_ng',
            'telemetry-time' => Time.now.to_datetime.rfc3339,
            'upload-package' => {
              'api-version' => 'v3',
              'app-id' => OpenSSL::Digest::SHA256.hexdigest(app_model.guid),
              'user-id' => OpenSSL::Digest::SHA256.hexdigest(user.guid)
            }
          }
          expect_any_instance_of(ActiveSupport::Logger).to receive(:info).with(Oj.dump(expected_json))
          post "/v3/packages/#{guid}/upload", packages_params.to_json, user_header
          expect(last_response.status).to eq(200)
        end
      end
    end

    context 'permissions' do
      before do
        space.remove_developer(user)
        space.organization.remove_user(user)
      end

      let(:api_call) { ->(user_headers) { post "/v3/packages/#{guid}/upload", packages_params.to_json, user_headers } }
      let(:space) { VCAP::CloudController::Space.make }
      let(:org) { space.organization }
      let(:user) { VCAP::CloudController::User.make }
      let(:package_model_response_object) do
        {
          'type' => package_model.type,
          'guid' => guid,
          'data' => {
            'checksum' => { 'type' => 'sha256', 'value' => anything },
            'error' => nil
          },
          'state' => VCAP::CloudController::PackageModel::PENDING_STATE,
          'relationships' => { 'app' => { 'data' => { 'guid' => app_model.guid } } },
          'metadata' => { 'labels' => {}, 'annotations' => {} },
          'created_at' => iso8601,
          'updated_at' => iso8601,
          'links' => {
            'self' => { 'href' => "#{link_prefix}/v3/packages/#{guid}" },
            'upload' => { 'href' => "#{link_prefix}/v3/packages/#{guid}/upload", 'method' => 'POST' },
            'download' => { 'href' => "#{link_prefix}/v3/packages/#{guid}/download" },
            'app' => { 'href' => "#{link_prefix}/v3/apps/#{app_model.guid}" }
          }
        }
      end
      let(:expected_codes_and_responses) do
        h = Hash.new({ code: 200, response_object: package_model_response_object }.freeze)
        h['org_auditor'] = { code: 404 }
        h['org_billing_manager'] = { code: 404 }
        h['no_role'] = { code: 404 }
        %w[admin_read_only global_auditor space_manager space_auditor org_manager space_supporter].each do |r|
          h[r] = { code: 403, errors: CF_NOT_AUTHORIZED }
        end
        h
      end

      it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS

      context 'when organization is suspended' do
        let(:expected_codes_and_responses) do
          h = super()
          h['space_developer'] = { code: 403, errors: CF_ORG_SUSPENDED }
          h
        end

        before do
          org.update(status: VCAP::CloudController::Organization::SUSPENDED)
        end

        it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
      end
    end
  end

  describe 'GET /v3/packages/:guid/download' do
    let(:type) { 'bits' }
    let!(:package_model) do
      VCAP::CloudController::PackageModel.make(app_guid: app_model.guid, type: type)
    end
    let(:app_model) do
      VCAP::CloudController::AppModel.make(guid: 'woof-guid', space_guid: space.guid, name: 'meow')
    end
    let(:space) { VCAP::CloudController::Space.make }
    let(:bits_download_url) { CloudController::DependencyLocator.instance.blobstore_url_generator.package_download_url(package_model) }
    let(:guid) { package_model.guid }
    let(:temp_file) do
      file = File.join(Dir.mktmpdir, 'application.zip')
      TestZip.create(file, 1, 1024)
      file
    end
    let(:upload_body) do
      {
        bits_name: 'application.zip',
        bits_path: temp_file
      }
    end

    before do
      TestConfig.override(directories: { tmpdir: File.dirname(temp_file) }, kubernetes: {})
      space.organization.add_user(user)
      space.add_developer(user)
      post "/v3/packages/#{guid}/upload", upload_body.to_json, user_header
      Delayed::Worker.new.work_off
    end

    it 'downloads the bit(s) for a package' do
      Timecop.freeze do
        get "/v3/packages/#{guid}/download", {}, user_header

        expect(last_response.status).to eq(302)
        expect(last_response.headers['Location']).to eq(bits_download_url)

        expected_metadata = { package_guid: package_model.guid }.to_json

        event = VCAP::CloudController::Event.last
        expect(event.values).to include({
                                          type: 'audit.app.package.download',
                                          actor: user.guid,
                                          actor_type: 'user',
                                          actor_name: email,
                                          actor_username: user_name,
                                          actee: 'woof-guid',
                                          actee_type: 'app',
                                          actee_name: 'meow',
                                          metadata: expected_metadata,
                                          space_guid: space.guid,
                                          organization_guid: space.organization.guid
                                        })
      end
    end

    context 'permissions' do
      before do
        space.remove_developer(user)
        space.organization.remove_user(user)
      end

      let(:api_call) { ->(user_headers) { get "/v3/packages/#{guid}/download", nil, user_headers } }
      let(:space) { VCAP::CloudController::Space.make }
      let(:org) { space.organization }
      let(:user) { VCAP::CloudController::User.make }
      let(:expected_codes_and_responses) do
        h = Hash.new({ code: 302 }.freeze)
        h['global_auditor'] = { code: 403 }
        h['org_auditor'] = { code: 404 }
        h['org_billing_manager'] = { code: 404 }
        h['org_manager'] = { code: 403 }
        h['no_role'] = { code: 404 }
        h['space_auditor'] = { code: 403 }
        h['space_manager'] = { code: 403 }
        h['space_supporter'] = { code: 403 }
        h
      end

      it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
    end
  end

  describe 'PATCH /v3/packages/:guid' do
    let(:app_name) { 'sir meow' }
    let(:app_guid) { 'meow-the-guid' }
    let(:space) { VCAP::CloudController::Space.make }
    let(:app_model) { VCAP::CloudController::AppModel.make(space_guid: space.guid, name: app_name, guid: app_guid) }
    let!(:package_model) do
      VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
    end
    let(:metadata) do
      {
        labels: {
          release: 'stable',
          'seriouseats.com/potato' => 'mashed'
        },
        annotations: { 'checksum' => 'SHA' }
      }
    end

    let(:guid) { package_model.guid }

    before do
      space.organization.add_user user
      space.add_developer user
    end

    it 'updates package metadata' do
      patch "/v3/packages/#{guid}", { metadata: }.to_json, user_header

      expected_metadata = {
        'labels' => {
          'release' => 'stable',
          'seriouseats.com/potato' => 'mashed'
        },
        'annotations' => { 'checksum' => 'SHA' }
      }

      parsed_response = Oj.load(last_response.body)
      expect(last_response.status).to eq(200)
      expect(parsed_response['metadata']).to eq(expected_metadata)
    end

    context 'permissions' do
      before do
        space.remove_developer(user)
        space.organization.remove_user(user)
      end

      let(:api_call) { ->(user_headers) { patch "/v3/packages/#{guid}", { metadata: }.to_json, user_headers } }
      let(:space) { VCAP::CloudController::Space.make }
      let(:org) { space.organization }
      let(:user) { VCAP::CloudController::User.make }
      let(:expected_codes_and_responses) do
        h = Hash.new({ code: 200 }.freeze)
        h['org_auditor'] = { code: 404 }
        h['org_billing_manager'] = { code: 404 }
        h['no_role'] = { code: 404 }
        %w[admin_read_only global_auditor space_manager space_auditor org_manager space_supporter].each do |r|
          h[r] = { code: 403, errors: CF_NOT_AUTHORIZED }
        end
        h
      end

      it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS

      context 'when organization is suspended' do
        let(:expected_codes_and_responses) do
          h = super()
          h['space_developer'] = { code: 403, errors: CF_ORG_SUSPENDED }
          h
        end

        before do
          org.update(status: VCAP::CloudController::Organization::SUSPENDED)
        end

        it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
      end
    end
  end

  describe 'DELETE /v3/packages/:guid' do
    let(:app_name) { 'sir meow' }
    let(:app_guid) { 'meow-the-guid' }
    let(:space) { VCAP::CloudController::Space.make }
    let(:app_model) { VCAP::CloudController::AppModel.make(space_guid: space.guid, name: app_name, guid: app_guid) }
    let!(:package_model) do
      VCAP::CloudController::PackageModel.make(app_guid: app_model.guid)
    end

    let(:guid) { package_model.guid }

    before do
      space.organization.add_user user
      space.add_developer user
    end

    it 'deletes a package asynchronously' do
      delete "/v3/packages/#{guid}", {}, user_header

      expect(last_response.status).to eq(202)
      expect(last_response.body).to eq('')
      expect(last_response.header['Location']).to match(%r{jobs/[a-fA-F0-9-]+})
      execute_all_jobs(expected_successes: 2, expected_failures: 0)
      get "/v3/packages/#{guid}", {}, user_header
      expect(last_response.status).to eq(404)

      expected_metadata = { package_guid: guid }.to_json

      event = VCAP::CloudController::Event.last
      expect(event.values).to include({
                                        type: 'audit.app.package.delete',
                                        actor: user.guid,
                                        actor_type: 'user',
                                        actor_name: email,
                                        actor_username: user_name,
                                        actee: app_guid,
                                        actee_type: 'app',
                                        actee_name: app_name,
                                        metadata: expected_metadata,
                                        space_guid: space.guid,
                                        organization_guid: space.organization.guid
                                      })
    end

    context 'deleting metadata' do
      it_behaves_like 'resource with metadata' do
        let(:resource) { package_model }
        let(:api_call) do
          -> { delete "/v3/packages/#{resource.guid}", nil, user_header }
        end
      end
    end

    context 'permissions' do
      before do
        space.remove_developer(user)
        space.organization.remove_user(user)
      end

      let(:api_call) { ->(user_headers) { delete "/v3/packages/#{guid}", nil, user_headers } }
      let(:space) { VCAP::CloudController::Space.make }
      let(:org) { space.organization }
      let(:user) { VCAP::CloudController::User.make }
      let(:expected_codes_and_responses) do
        h = Hash.new({ code: 202 }.freeze)
        h['org_auditor'] = { code: 404 }
        h['org_billing_manager'] = { code: 404 }
        h['no_role'] = { code: 404 }
        %w[admin_read_only global_auditor space_manager space_auditor org_manager space_supporter].each do |r|
          h[r] = { code: 403, errors: CF_NOT_AUTHORIZED }
        end
        h
      end

      it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
      context 'when organization is suspended' do
        let(:expected_codes_and_responses) do
          h = super()
          h['space_developer'] = { code: 403, errors: CF_ORG_SUSPENDED }
          h
        end

        before do
          org.update(status: VCAP::CloudController::Organization::SUSPENDED)
        end

        it_behaves_like 'permissions for single object endpoint', ALL_PERMISSIONS
      end
    end
  end

  describe 'PATCH /internal/v4/packages/:guid' do
    let!(:package_model) { VCAP::CloudController::PackageModel.make(state: VCAP::CloudController::PackageModel::PENDING_STATE) }
    let(:body) do
      {
        'state' => 'READY',
        'checksums' => [
          {
            'type' => 'sha1',
            'value' => 'potato'
          },
          {
            'type' => 'sha256',
            'value' => 'potatoest'
          }
        ]
      }.to_json
    end
    let(:guid) { package_model.guid }

    it 'updates a package' do
      patch "/internal/v4/packages/#{guid}", body

      expect(last_response.status).to eq(204)
      expect(last_response.body).to eq('')
    end
  end
end
