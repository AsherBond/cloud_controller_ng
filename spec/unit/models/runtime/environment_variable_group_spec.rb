require "spec_helper"

module VCAP::CloudController
  describe EnvironmentVariableGroup, type: :model do
    subject(:env_group) { EnvironmentVariableGroup.make(name: "something") }

    it { is_expected.to have_timestamp_columns }

    describe "Serialization" do
      it { is_expected.to export_attributes :name, :environment_json }
      it { is_expected.to import_attributes :environment_json }
    end

    describe "#staging" do
      context "when the corresponding db object does not exist" do
        it "creates a new database object with the right name" do
          expect(EnvironmentVariableGroup).to receive(:create).with(:name => "staging")
          EnvironmentVariableGroup.staging
        end

        it "initializes the object with an empty environment" do
          expect(EnvironmentVariableGroup.staging.environment_json).to eq({})
        end

        it "updates the object on save" do
          staging = EnvironmentVariableGroup.staging
          staging.environment_json = { "abc" => "easy as 123" }
          staging.save

          expect(EnvironmentVariableGroup.staging.environment_json).to eq({"abc" => "easy as 123"})
        end
      end

      context "when the corresponding db object exists" do
        it "returns the existing object" do
          EnvironmentVariableGroup.make(name: "staging", environment_json: {"abc" => 123})
          expect(EnvironmentVariableGroup.staging.environment_json).to eq("abc" => 123)
        end
      end
    end

    describe "#running" do
      context "when the corresponding db object does not exist" do
        it "creates a new database object with the right name" do
          expect(EnvironmentVariableGroup).to receive(:create).with(:name => "running")
          EnvironmentVariableGroup.running
        end

        it "initializes the object with an empty environment" do
          expect(EnvironmentVariableGroup.running.environment_json).to eq({})
        end

        it "updates the object on save" do
          running = EnvironmentVariableGroup.running
          running.environment_json = { "abc" => "easy as 123" }
          running.save

          expect(EnvironmentVariableGroup.running.environment_json).to eq({"abc" => "easy as 123"})
        end
      end

      context "when the corresponding db object exists" do
        it "returns the existing object" do
          EnvironmentVariableGroup.make(name: "running", environment_json: {"abc" => 123})
          expect(EnvironmentVariableGroup.running.environment_json).to eq("abc" => 123)
        end
      end
    end
  end
end
