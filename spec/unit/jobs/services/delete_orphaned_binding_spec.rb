require 'spec_helper'

module VCAP::CloudController
  module Jobs::Services
    RSpec.describe DeleteOrphanedBinding, job_context: :worker do
      let(:client) { instance_double(VCAP::Services::ServiceBrokers::V2::Client) }
      let(:service_binding) { VCAP::CloudController::ServiceBinding.make }
      let(:binding_info) { OrphanedBindingInfo.new(service_binding) }

      let(:name) { 'fake-name' }

      subject(:job) { VCAP::CloudController::Jobs::Services::DeleteOrphanedBinding.new(name, binding_info) }

      describe '#perform' do
        before do
          allow(client).to receive(:unbind).with(binding_info.to_binding, accepts_incomplete: true)
          allow(VCAP::Services::ServiceClientProvider).to receive(:provide).and_return(client)
        end

        it 'unbinds the binding' do
          expect(VCAP::Services::ServiceClientProvider).to receive(:provide).
            with(instance: service_binding.service_instance)

          Jobs::Enqueuer.new({ queue: Jobs::Queues.generic, run_at: Delayed::Job.db_time_now }).enqueue(job)
          execute_all_jobs(expected_successes: 1, expected_failures: 0)

          expect(client).to have_received(:unbind) do |binding|
            expect(binding.guid).to eq(service_binding.guid)
            expect(binding.service_instance.guid).to eq(service_binding.service_instance.guid)
            expect(binding.service_instance.name).to eq(service_binding.service_instance.name)
            expect(binding.service.broker_provided_id).to eq(service_binding.service.broker_provided_id)
            expect(binding.service_plan.broker_provided_id).to eq(service_binding.service_plan.broker_provided_id)
          end
        end
      end

      describe '#job_name_in_configuration' do
        it 'returns the name of the job' do
          expect(job.job_name_in_configuration).to eq(:delete_orphaned_binding)
        end
      end

      describe '#reschedule_at' do
        it 'uses exponential backoff' do
          now = Time.now

          run_at = job.reschedule_at(now, 5)
          expect(run_at).to eq(now + (2**5).minutes)
        end
      end

      describe 'exponential backoff when the job fails' do
        def run_job
          expect(Delayed::Job.count).to eq 1
          execute_all_jobs(expected_successes: 0, expected_failures: 1)
        end

        it 'retries 10 times, doubling its back_off time with each attempt' do
          allow(client).to receive(:unbind).and_raise(StandardError.new('I always fail'))
          allow(VCAP::Services::ServiceBrokers::V2::Client).to receive(:new).and_return(client)

          start = Delayed::Job.db_time_now
          opts = { queue: Jobs::Queues.generic, run_at: start }
          Jobs::Enqueuer.new(opts).enqueue(job)

          run_at_time = start
          10.times do |i|
            Timecop.travel(run_at_time)
            run_job
            expect(Delayed::Job.first.run_at).to be_within(1.second).of(run_at_time + (2**(i + 1)).minutes)
            run_at_time = Delayed::Job.first.run_at
          end

          Timecop.travel(run_at_time)
          run_job
          execute_all_jobs(expected_successes: 0, expected_failures: 0) # not running any jobs

          expect(run_at_time).to be_within(1.minute).of(start + (2**11).minutes - 2.minutes)
        end
      end
    end
  end
end
