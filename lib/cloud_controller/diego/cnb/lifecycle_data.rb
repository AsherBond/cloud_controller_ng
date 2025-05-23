module VCAP::CloudController
  module Diego
    module CNB
      class LifecycleData
        attr_accessor :app_bits_download_uri, :build_artifacts_cache_download_uri, :build_artifacts_cache_upload_uri,
                      :buildpacks, :app_bits_checksum, :droplet_upload_uri, :stack, :buildpack_cache_checksum,
                      :credentials, :auto_detect

        def message
          message = {
            app_bits_download_uri:,
            build_artifacts_cache_upload_uri:,
            droplet_upload_uri:,
            buildpacks:,
            stack:,
            app_bits_checksum:,
            auto_detect:
          }
          message[:build_artifacts_cache_download_uri] = build_artifacts_cache_download_uri if build_artifacts_cache_download_uri
          message[:buildpack_cache_checksum] = buildpack_cache_checksum if buildpack_cache_checksum
          message[:credentials] = credentials if credentials

          schema.validate(message)
          message
        end

        private

        def schema
          @schema ||= Membrane::SchemaParser.parse do
            {
              app_bits_download_uri: String,
              optional(:build_artifacts_cache_download_uri) => String,
              optional(:buildpack_cache_checksum) => String,
              build_artifacts_cache_upload_uri: String,
              droplet_upload_uri: String,
              buildpacks: Array,
              stack: String,
              app_bits_checksum: Hash,
              optional(:credentials) => String,
              auto_detect: bool
            }
          end
        end
      end
    end
  end
end
