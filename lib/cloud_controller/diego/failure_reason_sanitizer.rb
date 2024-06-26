module VCAP::CloudController
  module Diego
    module CCMessages
      STAGING_ERROR                 = 'StagingError'.freeze
      INSUFFICIENT_RESOURCES        = 'InsufficientResources'.freeze
      NO_COMPATIBLE_CELL            = 'NoCompatibleCell'.freeze
      CELL_COMMUNICATION_ERROR      = 'CellCommunicationError'.freeze
      BUILDPACK_DETECT_FAILED       = 'NoAppDetectedError'.freeze
      BUILDPACK_COMPILE_FAILED      = 'BuildpackCompileFailed'.freeze
      BUILDPACK_RELEASE_FAILED      = 'BuildpackReleaseFailed'.freeze
      CNB_GENERIC_BUILD_FAILED      = 'CNBGenericBuildFailed'.freeze
      CNB_DOWNLOAD_BUILDPACK_FAILED = 'CNBDownloadBuildpackFailed'.freeze
      CNB_DETECTING_FAILED          = 'CNBDetectFailed'.freeze
      CNB_BUILDING_FAILED           = 'CNBBuildFailed'.freeze
      CNB_EXPORTING_FAILED          = 'CNBExportFailed'.freeze
      CNB_LAUNCHING_FAILED          = 'CNBLaunchFailed'.freeze
      CNB_RESTORING_FAILED          = 'CNBRestoreFailed'.freeze
    end

    module DiegoErrors
      INSUFFICIENT_RESOURCES_MESSAGE        = 'insufficient resources'.freeze
      MISSING_APP_BITS_DOWNLOAD_URI_MESSAGE = 'missing app bits download uri'.freeze
      MISSING_APP_ID_MESSAGE                = 'missing app id'.freeze
      MISSING_LIFECYCLE_DATA_MESSAGE        = 'missing lifecycle data'.freeze
      NO_COMPILER_DEFINED_MESSAGE           = 'no compiler defined for requested stack'.freeze
      CELL_MISMATCH_MESSAGE                 = 'found no compatible cell'.freeze
      CELL_COMMUNICATION_ERROR              = 'unable to communicate to compatible cells'.freeze
      MISSING_DOCKER_IMAGE_URL              = 'missing docker image download url'.freeze
      MISSING_DOCKER_REGISTRY               = 'missing docker registry'.freeze
      MISSING_DOCKER_CREDENTIALS            = 'missing docker credentials'.freeze
      INVALID_DOCKER_REGISTRY_ADDRESS       = 'invalid docker registry address'.freeze
    end

    class FailureReasonSanitizer
      # rubocop:disable Metrics/CyclomaticComplexity
      def self.sanitize(message)
        staging_failed = 'staging failed'
        id = CCMessages::STAGING_ERROR
        if message.ends_with?('222')
          id = CCMessages::BUILDPACK_DETECT_FAILED
          message = staging_failed
        elsif message.ends_with?('223')
          id = CCMessages::BUILDPACK_COMPILE_FAILED
          message = staging_failed
        elsif message.ends_with?('224')
          id = CCMessages::BUILDPACK_RELEASE_FAILED
          message = staging_failed
        elsif message.ends_with?('231')
          id = CCMessages::CNB_GENERIC_BUILD_FAILED
          message = staging_failed
        elsif message.ends_with?('232')
          id = CCMessages::CNB_DOWNLOAD_BUILDPACK_FAILED
          message = staging_failed
        elsif message.ends_with?('233')
          id = CCMessages::CNB_DETECTING_FAILED
          message = staging_failed
        elsif message.ends_with?('234')
          id = CCMessages::CNB_BUILDING_FAILED
          message = staging_failed
        elsif message.ends_with?('235')
          id = CCMessages::CNB_EXPORTING_FAILED
          message = staging_failed
        elsif message.ends_with?('236')
          id = CCMessages::CNB_LAUNCHING_FAILED
          message = staging_failed
        elsif message.ends_with?('237')
          id = CCMessages::CNB_RESTORING_FAILED
          message = staging_failed
        elsif message.starts_with?(DiegoErrors::INSUFFICIENT_RESOURCES_MESSAGE)
          id = CCMessages::INSUFFICIENT_RESOURCES
        elsif message.starts_with?(DiegoErrors::CELL_MISMATCH_MESSAGE)
          id = CCMessages::NO_COMPATIBLE_CELL
        elsif message == DiegoErrors::CELL_COMMUNICATION_ERROR
          id = CCMessages::CELL_COMMUNICATION_ERROR
        elsif message == DiegoErrors::MISSING_DOCKER_IMAGE_URL
        elsif message == DiegoErrors::MISSING_DOCKER_REGISTRY
        elsif message == DiegoErrors::MISSING_DOCKER_CREDENTIALS
        elsif message == DiegoErrors::INVALID_DOCKER_REGISTRY_ADDRESS
        else
          message = 'staging failed'
        end

        {
          id:,
          message:
        }
      end
      # rubocop:enable Metrics/CyclomaticComplexity
    end
  end
end
