require 'spec_helper'
require 'actions/stack_create'
require 'messages/stack_create_message'

module VCAP::CloudController
  RSpec.describe StackCreate do
    describe 'create' do
      it 'creates a stack' do
        message = VCAP::CloudController::StackCreateMessage.new(
          name: 'the-name',
          description: 'the-description',
          metadata: {
            labels: {
              release: 'stable',
              'seriouseats.com/potato' => 'mashed'
            },
            annotations: {
              tomorrow: 'land',
              backstreet: 'boys'
            }
          }
        )
        stack = StackCreate.new.create(message)

        expect(stack.name).to eq('the-name')
        expect(stack.description).to eq('the-description')

        expect(stack).to have_labels(
          { prefix: 'seriouseats.com', key_name: 'potato', value: 'mashed' },
          { prefix: nil, key_name: 'release', value: 'stable' }
        )
        expect(stack).to have_annotations(
          { key_name: 'tomorrow', value: 'land' },
          { key_name: 'backstreet', value: 'boys' }
        )
      end

      context 'when a model validation fails' do
        it 'raises an error' do
          errors = Sequel::Model::Errors.new
          errors.add(:blork, 'is busted')
          expect(VCAP::CloudController::Stack).to receive(:create).
            and_raise(Sequel::ValidationFailed.new(errors))

          message = VCAP::CloudController::StackCreateMessage.new(name: 'foobar')
          expect do
            StackCreate.new.create(message)
          end.to raise_error(StackCreate::Error, 'blork is busted')
        end
      end

      context 'when it is a uniqueness error' do
        let(:name) { 'Olsen' }

        before do
          VCAP::CloudController::Stack.create(name:)
        end

        it 'raises a human-friendly error' do
          message = VCAP::CloudController::StackCreateMessage.new(name:)
          expect do
            StackCreate.new.create(message)
          end.to raise_error(StackCreate::Error, 'Name must be unique')
        end
      end

      context 'when creating stack with the same name concurrently' do
        let(:name) { 'Gaby' }

        it 'ensures one creation is successful and the other fails due to name conflict' do
          message = VCAP::CloudController::StackCreateMessage.new(name:)
          # First request, should succeed
          expect do
            StackCreate.new.create(message)
          end.not_to raise_error

          # Mock the validation for the second request to simulate the race condition and trigger a unique constraint violation
          allow_any_instance_of(Stack).to receive(:validate).and_return(true)

          # Second request, should fail with correct error
          expect do
            StackCreate.new.create(message)
          end.to raise_error(StackCreate::Error, 'Name must be unique')
        end
      end
    end
  end
end
