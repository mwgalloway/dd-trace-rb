if ENV['DD_TRACE_SKIP_LIB_INJECTION'] == 'true'
else
  begin
    require 'rubygems'
    require 'open3'
    require 'bundler'
    require 'bundler/cli'
    require 'shellwords'
    require 'fileutils'
    require 'json'

    def dd_debug_log(msg)
      pid = Process.respond_to?(:pid) ? Process.pid : 0 # Not available on all platforms
      $stdout.puts "[datadog][#{pid}][#{$0}] #{msg}" if ENV['DD_TRACE_DEBUG'] == 'true'
    end

    def dd_error_log(msg)
      pid = Process.respond_to?(:pid) ? Process.pid : 0 # Not available on all platforms
      warn "[datadog][#{pid}][#{$0}] #{msg}"
    end

    def dd_skip_injection!
      ENV['DD_TRACE_SKIP_LIB_INJECTION'] = 'true'
    end

    def dd_send_telemetry(events)
      pid = Process.respond_to?(:pid) ? Process.pid : 0 # Not available on all platforms

      tracer_version = if File.exist?('/opt/datadog/apm/library/ruby/version.txt')
                         File.read('/opt/datadog/apm/library/ruby/version.txt').chomp
                       else
                         'unknown'
                       end

      payload = {
        metadata: {
          language_name: 'ruby',
          language_version: RUBY_VERSION,
          runtime_name: RUBY_ENGINE,
          runtime_version: RUBY_VERSION,
          tracer_version: tracer_version,
          pid: pid
        },
        points: events
      }.to_json

      fowarder = ENV['DD_TELEMETRY_FORWARDER_PATH']

      return if fowarder.nil? || fowarder.empty?

      Open3.capture2e([fowarder, 'library_entrypoint'], stdin_data: payload)
    end

    precheck = Module.new do
      module_function

      def in_bundle?
        Bundler::SharedHelpers.in_bundle?
      end

      def runtime_supported?
        major, minor, = RUBY_VERSION.split('.')
        ruby_api_version = "#{major}.#{minor}.0"

        supported_ruby_api_versions = ['2.7.0', '3.0.0', '3.1.0', '3.2.0'].freeze

        RUBY_ENGINE == 'ruby' && supported_ruby_api_versions.any? { |v| ruby_api_version == v }
      end

      def platform_supported?
        platform_support_matrix = {
          cpu: ['x86_64', 'aarch64'].freeze,
          os: ['linux'].freeze,
          version: ['gnu', nil].freeze # nil is equivalent to `gnu` for local platform
        }
        local_platform = Gem::Platform.local

        platform_support_matrix.fetch(:cpu).any? { |v| local_platform.cpu == v } &&
          platform_support_matrix.fetch(:os).any? { |v| local_platform.os == v } &&
          platform_support_matrix.fetch(:version).any? { |v| local_platform.version == v }
      end

      def already_installed?
        ['ddtrace', 'datadog'].any? do |gem|
          fork do
            $stdout = File.new('/dev/null', 'w')
            $stderr = File.new('/dev/null', 'w')
            Bundler::CLI::Common.select_spec(gem)
          end
          _, status = Process.wait2
          status.success?
        end
      end

      def frozen_bundle?
        Bundler.frozen_bundle?
      end

      def bundler_supported?
        Bundler::CLI.commands['add'] && Bundler::CLI.commands['add'].options.key?('require')
      end
    end

    case
    when !precheck.in_bundle?
      dd_debug_log 'Not in bundle... skipping injection'
    when !precheck.runtime_supported?
      dd_debug_log "Runtime not supported: #{RUBY_DESCRIPTION}"
      dd_send_telemetry(
        [
          { name: 'library_entrypoint.abort', tags: ['reason:incompatible_runtime'] },
          { name: 'library_entrypoint.abort.runtime' }
        ]
      )
    when !precheck.platform_supported?
      dd_debug_log "Platform not supported: #{local_platform}"
      dd_send_telemetry([{ name: 'library_entrypoint.abort', tags: ['reason:incompatible_platform'] }])
    when !Process.respond_to?(:fork)
      dd_debug_log 'Fork not supported... skipping injection'
    when precheck.already_installed?
      dd_debug_log 'Skip injection: already installed'
    when precheck.frozen_bundle?
      dd_error_log "Skip injection: bundler is configured with 'deployment' or 'frozen'"
      dd_send_telemetry([{ name: 'library_entrypoint.abort', tags: ['reason:bundler'] }])
    when !precheck.bundler_supported?
      dd_error_log "Skip injection: bundler version #{Bundler::VERSION} is not supported, please upgrade to >= 2.3."
      dd_send_telemetry([{ name: 'library_entrypoint.abort', tags: ['reason:bundler_version'] }])
    else
      # Injection
      major, minor, = RUBY_VERSION.split('.')
      ruby_api_version = "#{major}.#{minor}.0"
      dd_lib_injection_path = "/opt/datadog/apm/library/ruby/#{ruby_api_version}"
      dd_debug_log "Loading from #{dd_lib_injection_path}..."
      lock_file_parser = Bundler::LockfileParser.new(Bundler.read_file("#{dd_lib_injection_path}/Gemfile.lock"))
      gem_version_mapping = lock_file_parser.specs.each_with_object({}) do |spec, hash|
        hash[spec.name] = spec.version.to_s
        hash
      end

      gemfile = Bundler::SharedHelpers.default_gemfile
      lockfile = Bundler::SharedHelpers.default_lockfile

      datadog_gemfile = gemfile.dirname + '.datadog-Gemfile'
      datadog_lockfile = lockfile.dirname + '.datadog-Gemfile.lock'

      # Copies for trial
      ::FileUtils.cp gemfile, datadog_gemfile
      ::FileUtils.cp lockfile, datadog_lockfile

      injection_failure = false

      # This is order dependent
      [
        'msgpack',
        'ffi',
        'debase-ruby_core_source',
        'libdatadog',
        'libddwaf',
        'datadog'
      ].each do |gem|
        fork do
          $stdout = File.new('/dev/null', 'w')
          $stderr = File.new('/dev/null', 'w')
          Bundler::CLI::Common.select_spec(gem)
        end

        _, status = Process.wait2
        if status.success?
          dd_debug_log "#{gem} already installed... skipping..."
          next
        end

        bundle_add_cmd = "bundle add #{gem} --skip-install --version #{gem_version_mapping[gem]} "
        bundle_add_cmd << '--require datadog/auto_instrument' if gem == 'datadog'

        dd_debug_log "Injection with `#{bundle_add_cmd}`"

        env = { 'BUNDLE_GEMFILE' => datadog_gemfile.to_s,
                'DD_TRACE_SKIP_LIB_INJECTION' => 'true',
                'GEM_PATH' => dd_lib_injection_path }
        add_output, add_status = Open3.capture2e(env, bundle_add_cmd)

        if add_status.success?
          dd_debug_log "Successfully injected #{gem} into the application."
        else
          injection_failure = true
          dd_error_log "Injection failed: Unable to add datadog. Error output: #{add_output}"
        end
      end

      if injection_failure
        ::FileUtils.rm datadog_gemfile
        ::FileUtils.rm datadog_lockfile
        dd_send_telemetry([{ name: 'library_entrypoint.error', tags: ['error_type:injection_failure'] }])
      else
        # Look for pre-installed tracers
        Gem.paths = { 'GEM_PATH' => "#{dd_lib_injection_path}:#{ENV['GEM_PATH']}" }

        # Also apply to the environment variable, to guarantee any spawned processes will respected the modified `GEM_PATH`.
        ENV['GEM_PATH'] = Gem.path.join(':')
        ENV['BUNDLE_GEMFILE'] = datadog_gemfile.to_s

        dd_send_telemetry([{ name: 'library_entrypoint.complete', tags: ['injection_forced:false'] }])
      end
    end
    dd_skip_injection!
  rescue Exception => e
    if respond_to?(:dd_send_telemetry)
      dd_send_telemetry(
        [
          { name: 'library_entrypoint.error',
            tags: ["error_type:#{e.class.name}"] }
        ]
      )
    end
    pid = Process.respond_to?(:pid) ? Process.pid : 0 # Not available on all platforms
    warn "[datadog][#{pid}][#{$0}] Injection failed: #{e.class.name} #{e.message}\nBacktrace: #{e.backtrace.join("\n")}"

    # Skip injection if the environment variable is set
    ENV['DD_TRACE_SKIP_LIB_INJECTION'] = 'true'
  end
end
