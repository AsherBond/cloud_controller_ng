require 'db_spec_helper'
require 'decorators/include_binding_service_instance_decorator'

module VCAP
  module CloudController
    def self.can_be_decorated_with_include_binding_service_instance_decorator(klazz)
      RSpec.describe IncludeBindingServiceInstanceDecorator do
        subject(:decorator) { described_class }

        let(:bindings) do
          [
            klazz.make(service_instance: ManagedServiceInstance.make(:routing, created_at: Time.now.utc - 1.second)),
            klazz.make
          ]
        end

        let(:instances) do
          bindings.map { |b| Presenters::V3::ServiceInstancePresenter.new(b.service_instance).to_hash }
        end

        it 'decorates the given hash with service instances from bindings in the correct order' do
          dict = { foo: 'bar' }
          hash = subject.decorate(dict, bindings)
          expect(hash[:foo]).to eq('bar')
          expect(hash[:included][:service_instances]).to eq(instances)
        end

        it 'does not overwrite other included fields' do
          dict = { foo: 'bar', included: { fruits: %w[tomato banana] } }
          hash = subject.decorate(dict, bindings)
          expect(hash[:foo]).to eq('bar')
          expect(hash[:included][:service_instances]).to match_array(instances)
          expect(hash[:included][:fruits]).to match_array(%w[tomato banana])
        end

        it 'does not include duplicates' do
          hash = subject.decorate({}, bindings << klazz.make(service_instance: bindings[0].service_instance))
          expect(hash[:included][:service_instances]).to have(2).items
        end

        describe '.match?' do
          it 'matches include arrays containing "app"' do
            expect(decorator.match?(%w[potato service_instance turnip])).to be(true)
          end

          it 'does not match other include arrays' do
            expect(decorator.match?(%w[potato turnip])).not_to be(true)
          end
        end
      end
    end

    [
      ServiceBinding,
      ServiceKey,
      RouteBinding
    ].each do |type|
      can_be_decorated_with_include_binding_service_instance_decorator(type)
    end
  end
end
