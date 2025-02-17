# frozen_string_literal: true

require_relative "error"
require_relative "utils"
require_relative "../core/rate_limiter"

module Datadog
  module DI
    # Encapsulates probe information (as received via remote config)
    # and state (e.g. whether the probe was installed, or executed).
    #
    # It is possible that remote configuration will specify an unsupported
    # probe type or attribute, due to new DI functionality being added
    # over time. We want to have predictable behavior in such cases, and
    # since we can't guarantee that there will be enough information in
    # a remote config payload to construct a functional probe, ProbeBuilder
    # and remote config code must be prepared to deal with exceptions
    # raised by Probe constructor in particular. Therefore, Probe constructor
    # will raise an exception if it determines that there is not enough
    # information (or confilcting information) in the arguments to create a
    # functional probe, and upstream code is tasked with not spamming logs
    # with notifications of such errors (and potentially limiting the
    # attempts to construct probe from a given payload).
    #
    # Note that, while remote configuration provides line numbers as an
    # array, the only supported line number configuration is a single line
    # (this is the case for all languages currently). Therefore Probe
    # only supports one line number, and ProbeBuilder is responsible for
    # extracting that one line number out of the array received from RC.
    #
    # Note: only some of the parameter/attribute values are currently validated.
    #
    # @api private
    class Probe
      KNOWN_TYPES = %i[log].freeze

      def initialize(id:, type:,
        file: nil, line_no: nil, type_name: nil, method_name: nil,
        template: nil, capture_snapshot: false, max_capture_depth: nil, rate_limit: nil)
        # Perform some sanity checks here to detect unexpected attribute
        # combinations, in order to not do them in subsequent code.
        unless KNOWN_TYPES.include?(type)
          raise ArgumentError, "Unknown probe type: #{type}"
        end

        if line_no && method_name
          raise ArgumentError, "Probe contains both line number and method name: #{id}"
        end

        if type_name && !method_name || method_name && !type_name
          raise ArgumentError, "Partial method probe definition: #{id}"
        end

        @id = id
        @type = type
        @file = file
        @line_no = line_no
        @type_name = type_name
        @method_name = method_name
        @template = template
        @capture_snapshot = !!capture_snapshot
        @max_capture_depth = max_capture_depth

        # These checks use instance methods that have more complex logic
        # than checking a single argument value. To avoid duplicating
        # the logic here, use the methods and perform these checks after
        # instance variable assignment.
        unless method? || line?
          raise ArgumentError, "Unhandled probe type: neither method nor line probe: #{id}"
        end

        @rate_limit = rate_limit || (@capture_snapshot ? 1 : 5000)
        @rate_limiter = Datadog::Core::TokenBucket.new(@rate_limit)
      end

      attr_reader :id
      attr_reader :type
      attr_reader :file
      attr_reader :line_no
      attr_reader :type_name
      attr_reader :method_name
      attr_reader :template

      # Configured maximum capture depth. Can be nil in which case
      # the global default will be used.
      attr_reader :max_capture_depth

      # Rate limit in effect, in invocations per second. Always present.
      attr_reader :rate_limit

      # Rate limiter object. For internal DI use only.
      attr_reader :rate_limiter

      def capture_snapshot?
        @capture_snapshot
      end

      # Returns whether the probe is a line probe.
      #
      # Method probes may still specify a file name (to aid in locating the
      # method or for stack traversal purposes?), therefore we do not check
      # for file name/path presence here and just consider the line number.
      def line?
        !line_no.nil?
      end

      # Returns whether the probe is a method probe.
      def method?
        !!(type_name && method_name)
      end

      # Returns the line number associated with the probe, raising
      # Error::MissingLineNumber if the probe does not have a line number
      # associated with it.
      #
      # This method is used by instrumentation driver to ensure a line number
      # that is passed into the instrumentation logic is actually a line number
      # and not nil.
      def line_no!
        if line_no.nil?
          raise Error::MissingLineNumber, "Probe #{id} does not have a line number associated with it"
        end
        line_no
      end

      # Source code location of the probe, for diagnostic reporting.
      def location
        if method?
          "#{type_name}.#{method_name}"
        elsif line?
          "#{file}:#{line_no}"
        else
          # This case should not be possible because constructor verifies that
          # the probe is a method or a line probe.
          raise NotImplementedError
        end
      end

      # Returns whether the provided +path+ matches the user-designated
      # file (of a line probe).
      #
      # If file is an absolute path (i.e., it starts with a slash), the file
      # must be identical to path to match.
      #
      # If file is not an absolute path, the path matches if the file is its suffix,
      # at a path component boundary.
      def file_matches?(path)
        unless file
          raise ArgumentError, "Probe does not have a file to match against"
        end
        Utils.path_matches_suffix?(path, file)
      end

      # Instrumentation module for method probes.
      attr_accessor :instrumentation_module

      # Line trace point for line probes. Normally this would be a targeted
      # trace point.
      attr_accessor :instrumentation_trace_point
    end
  end
end
