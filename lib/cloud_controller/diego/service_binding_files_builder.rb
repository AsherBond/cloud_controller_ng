module VCAP::CloudController
  module Diego
    class ServiceBindingFilesBuilder
      class IncompatibleBindings < StandardError; end

      MAX_ALLOWED_BYTESIZE = 1_000_000

      def self.build(app_or_process)
        new(app_or_process).build
      end

      def initialize(app_or_process)
        @app_or_process = app_or_process
        @service_binding_k8s_enabled = app_or_process.service_binding_k8s_enabled
        @file_based_vcap_services = app_or_process.file_based_vcap_services_enabled
        @service_bindings = app_or_process.service_bindings
      end

      def build
        if @service_binding_k8s_enabled
          build_service_binding_k8s
        elsif @file_based_vcap_services
          vcap_services = SystemEnvPresenter.new(@app_or_process).vcap_services[:VCAP_SERVICES]
          build_vcap_service_file(vcap_services)
        end
      end

      private

      def build_service_binding_k8s
        return nil unless @service_binding_k8s_enabled

        service_binding_files = {}
        names = Set.new # to check for duplicate binding names
        total_bytesize = 0 # to check the total bytesize

        @service_bindings.select(&:create_succeeded?).each do |service_binding|
          sb_hash = ServiceBindingPresenter.new(service_binding, include_instance: true).to_hash
          name = sb_hash[:name]
          raise IncompatibleBindings.new("Invalid binding name: '#{name}'. Name must match #{binding_naming_convention.inspect}") unless valid_name?(name)
          raise IncompatibleBindings.new("Duplicate binding name: #{name}") if names.add?(name).nil?

          # add the credentials first
          sb_hash.delete(:credentials)&.each { |k, v| total_bytesize += add_file(service_binding_files, name, k.to_s, v) }

          # add the rest of the hash; already existing credential keys are overwritten
          # VCAP_SERVICES attribute names are transformed (e.g. binding_guid -> binding-guid)
          sb_hash.each { |k, v| total_bytesize += add_file(service_binding_files, name, transform_vcap_services_attribute(k.to_s), v) }

          # add the type and provider
          label = sb_hash[:label]
          total_bytesize += add_file(service_binding_files, name, 'type', label)
          total_bytesize += add_file(service_binding_files, name, 'provider', label)
        end

        raise IncompatibleBindings.new("Bindings exceed the maximum allowed bytesize of #{MAX_ALLOWED_BYTESIZE}: #{total_bytesize}") if total_bytesize > MAX_ALLOWED_BYTESIZE

        service_binding_files.values
      end

      def build_vcap_service_file(vcap_services)
        path = 'vcap_services'
        vcap_services_string = Oj.dump(vcap_services, mode: :compat)
        total_bytesize = vcap_services_string.bytesize + path.bytesize

        raise IncompatibleBindings.new("Bindings exceed the maximum allowed bytesize of #{MAX_ALLOWED_BYTESIZE}: #{total_bytesize}") if total_bytesize > MAX_ALLOWED_BYTESIZE

        [::Diego::Bbs::Models::File.new(path: path, content: vcap_services_string)]
      end

      def binding_naming_convention
        /^[a-z0-9\-.]{1,253}$/
      end

      # - adds a Diego::Bbs::Models::File object to the service_binding_files hash
      # - binding name is used as the directory name, key is used as the file name
      # - returns the bytesize of the path and content
      # - skips (and returns 0) if the value is nil or an empty array or hash
      # - serializes the value to JSON if it is a non-string object
      def add_file(service_binding_files, name, key, value)
        raise IncompatibleBindings.new("Invalid file name: #{key}") unless valid_name?(key)

        path = "#{name}/#{key}"
        content = if value.nil?
                    return 0
                  elsif value.is_a?(String)
                    value
                  else
                    return 0 if (value.is_a?(Array) || value.is_a?(Hash)) && value.empty?

                    Oj.dump(value, mode: :compat)
                  end

        service_binding_files[path] = ::Diego::Bbs::Models::File.new(path:, content:)
        path.bytesize + content.bytesize
      end

      def valid_name?(name)
        name.match?(binding_naming_convention)
      end

      def transform_vcap_services_attribute(name)
        if %w[binding_guid binding_name instance_guid instance_name syslog_drain_url volume_mounts].include?(name)
          name.tr('_', '-')
        else
          name
        end
      end
    end
  end
end
