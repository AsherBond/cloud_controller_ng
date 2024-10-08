require 'spec_helper'
require 'actions/isolation_segment_create'

module VCAP::CloudController
  RSpec.describe IsolationSegmentCreate do
    describe 'create' do
      it 'creates a isolation segment' do
        message = VCAP::CloudController::IsolationSegmentCreateMessage.new({
                                                                             name: 'my-iso-seg',
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
                                                                           })
        iso_seg = IsolationSegmentCreate.create(message)

        expect(iso_seg.name).to eq('my-iso-seg')
        expect(iso_seg).to have_labels(
          { prefix: 'seriouseats.com', key_name: 'potato', value: 'mashed' },
          { prefix: nil, key_name: 'release', value: 'stable' }
        )
        expect(iso_seg).to have_annotations(
          { key_name: 'tomorrow', value: 'land' },
          { key_name: 'backstreet', value: 'boys' }
        )
      end

      context 'when a model validation fails' do
        it 'raises an error' do
          errors = Sequel::Model::Errors.new
          errors.add(:blork, 'is busted')
          expect(VCAP::CloudController::IsolationSegmentModel).to receive(:create).
            and_raise(Sequel::ValidationFailed.new(errors))

          message = VCAP::CloudController::IsolationSegmentCreateMessage.new(name: 'foobar')
          expect do
            IsolationSegmentCreate.create(message)
          end.to raise_error(IsolationSegmentCreate::Error, 'blork is busted')
        end
      end

      context 'when creating isolation segments concurrently' do
        it 'ensures one creation is successful and the other fails due to name conflict' do
          # First request, should succeed
          message = VCAP::CloudController::IsolationSegmentCreateMessage.new(name: 'foobar')
          expect do
            IsolationSegmentCreate.create(message)
          end.not_to raise_error

          # Mock the validation for the second request to simulate the race condition and trigger a unique constraint violation
          allow_any_instance_of(IsolationSegmentModel).to receive(:validate).and_return(true)

          # Second request, should fail with correct error
          expect do
            IsolationSegmentCreate.create(message)
          end.to raise_error(IsolationSegmentCreate::Error, 'name unique')
        end
      end
    end
  end
end
