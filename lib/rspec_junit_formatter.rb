# frozen_string_literal: true

require "socket"
require "time"

require "rspec/core"
require "rspec/core/formatters/base_formatter"

# Dumps rspec results as a JUnit XML file.
# Based on XML schema: http://windyroad.org/dl/Open%20Source/JUnit.xsd
class RSpecJUnitFormatter < RSpec::Core::Formatters::BaseFormatter
  # rspec 2 and 3 implements are in separate files.
  class << self
    attr_writer :include_line_number
    attr_writer :metadata_properties

    def include_line_number
      if instance_variable_defined?(:@include_line_number)
        @include_line_number
      elsif superclass.respond_to?(:include_line_number)
        superclass.include_line_number
      else
        false
      end
    end

    def metadata_properties
      if instance_variable_defined?(:@metadata_properties)
        @metadata_properties
      elsif superclass.respond_to?(:metadata_properties)
        superclass.metadata_properties
      else
        []
      end
    end
  end

  self.include_line_number = false
  self.metadata_properties = []

private

  def xml_dump
    output << %{<?xml version="1.0" encoding="UTF-8"?>\n}
    output << %{<testsuite}
    output << %{ name="rspec#{escape(ENV["TEST_ENV_NUMBER"].to_s)}"}
    output << %{ tests="#{example_count}"}
    output << %{ skipped="#{pending_count}"}
    output << %{ failures="#{failure_count}"}
    output << %{ errors="#{error_count}"}
    output << %{ time="#{escape("%.6f" % duration)}"}
    output << %{ timestamp="#{escape(started.iso8601)}"}
    output << %{ hostname="#{escape(Socket.gethostname)}"}
    output << %{>\n}
    xml_dump_properties
    xml_dump_examples
    output << %{</testsuite>\n}
  end

  def xml_dump_properties
    output << %{<properties>\n}
    suite_properties.each do |name, value|
      output << %{<property}
      output << %{ name="#{escape(name)}"}
      output << %{ value="#{escape(value)}"}
      output << %{/>\n}
    end
    output << %{</properties>\n}
  end

  def suite_properties
    [
      ["seed".freeze, RSpec.configuration.seed.to_s],
      ["rspec.version".freeze, RSpec::Core::Version::STRING],
    ]
  end

  def xml_dump_examples
    examples.each do |example|
      case result_of(example)
      when :pending
        xml_dump_pending(example)
      when :failed
        xml_dump_failed(example)
      else
        xml_dump_example(example)
      end
    end
  end

  def xml_dump_pending(example)
    xml_dump_example(example) do
      xml_dump_skipped(pending_message_for(example))
    end
  end

  def xml_dump_skipped(message)
    if message && !message.empty?
      output << %{<skipped message="#{escape(message)}">}
      output << escape(message)
      output << %{</skipped>}
    else
      output << %{<skipped/>}
    end
  end

  def xml_dump_failed(example)
    xml_dump_example(example) do
      output << %{<failure}
      output << %{ message="#{escape(failure_message_for(example))}"}
      output << %{ type="#{escape(failure_type_for(example))}"}
      output << %{>}
      output << escape(failure_for(example))
      output << %{</failure>}
    end
  end

  def xml_dump_example(example)
    output << %{<testcase}
    output << %{ classname="#{escape(classname_for(example))}"}
    output << %{ name="#{escape(description_for(example))}"}
    output << %{ file="#{escape(example_group_file_path_for(example))}"}
    if self.class.include_line_number && (line_number = line_number_for(example))
      output << %{ line="#{escape(line_number)}"}
    end
    if duration = duration_for(example)
      output << %{ time="#{escape("%.6f" % duration)}"}
    end
    output << %{>}
    yield if block_given?
    xml_dump_metadata_properties(example)
    xml_dump_output(example)
    output << %{</testcase>\n}
  end

  SCALAR_METADATA_CLASSES = [
    String,
    Symbol,
    Numeric,
    TrueClass,
    FalseClass,
    NilClass,
  ].freeze

  def xml_dump_metadata_properties(example)
    properties = metadata_properties_for(example)
    return if properties.empty?

    output << %{<properties>}
    properties.each do |name, value|
      output << %{<property}
      output << %{ name="#{escape(name)}"}
      output << %{ value="#{escape(value)}"}
      output << %{/>\n}
    end
    output << %{</properties>}
  end

  def metadata_properties_for(example)
    metadata = metadata_for(example)
    Array(self.class.metadata_properties).each_with_object([]) do |key, properties|
      metadata_key = metadata_key_for(metadata, key)
      next unless metadata_key

      value = metadata[metadata_key]
      next unless scalar_metadata_value?(value)

      properties << [key.to_s, value.to_s]
    end
  end

  def metadata_key_for(metadata, key)
    return key if metadata.key?(key)

    symbol_key = key.to_sym if key.respond_to?(:to_sym)
    symbol_key if symbol_key && metadata.key?(symbol_key)
  end

  def scalar_metadata_value?(value)
    SCALAR_METADATA_CLASSES.any? { |klass| value.is_a?(klass) }
  end

  def xml_dump_output(example)
    if (stdout = stdout_for(example)) && !stdout.empty?
      output << %{<system-out>}
      output << escape(stdout)
      output << %{</system-out>}
    end

    if (stderr = stderr_for(example)) && !stderr.empty?
      output << %{<system-err>}
      output << escape(stderr)
      output << %{</system-err>}
    end
  end

  # Inversion of character range from https://www.w3.org/TR/xml/#charsets
  ILLEGAL_REGEXP = Regexp.new(
    "[^".dup <<
    "\u{9}" << # => \t
    "\u{a}" << # => \n
    "\u{d}" << # => \r
    "\u{20}-\u{d7ff}" <<
    "\u{e000}-\u{fffd}" <<
    "\u{10000}-\u{10ffff}" <<
    "]"
  )

  # Replace illegals with a Ruby-like escape
  ILLEGAL_REPLACEMENT = Hash.new { |_, c|
    x = c.ord
    if x <= 0xff
      "\\x%02X".freeze % x
    elsif x <= 0xffff
      "\\u%04X".freeze % x
    else
      "\\u{%X}".freeze % x
    end.freeze
  }.update(
    "\0".freeze => "\\0".freeze,
    "\a".freeze => "\\a".freeze,
    "\b".freeze => "\\b".freeze,
    "\f".freeze => "\\f".freeze,
    "\v".freeze => "\\v".freeze,
    "\e".freeze => "\\e".freeze,
  ).freeze

  # Discouraged characters from https://www.w3.org/TR/xml/#charsets
  # Plus special characters with well-known entity replacements
  DISCOURAGED_REGEXP = Regexp.new(
    "[".dup <<
    "\u{22}" << # => "
    "\u{26}" << # => &
    "\u{27}" << # => '
    "\u{3c}" << # => <
    "\u{3e}" << # => >
    "\u{7f}-\u{84}" <<
    "\u{86}-\u{9f}" <<
    "\u{fdd0}-\u{fdef}" <<
    "\u{1fffe}-\u{1ffff}" <<
    "\u{2fffe}-\u{2ffff}" <<
    "\u{3fffe}-\u{3ffff}" <<
    "\u{4fffe}-\u{4ffff}" <<
    "\u{5fffe}-\u{5ffff}" <<
    "\u{6fffe}-\u{6ffff}" <<
    "\u{7fffe}-\u{7ffff}" <<
    "\u{8fffe}-\u{8ffff}" <<
    "\u{9fffe}-\u{9ffff}" <<
    "\u{afffe}-\u{affff}" <<
    "\u{bfffe}-\u{bffff}" <<
    "\u{cfffe}-\u{cffff}" <<
    "\u{dfffe}-\u{dffff}" <<
    "\u{efffe}-\u{effff}" <<
    "\u{ffffe}-\u{fffff}" <<
    "\u{10fffe}-\u{10ffff}" <<
    "]"
  )

  # Translate well-known entities, or use generic unicode hex entity
  DISCOURAGED_REPLACEMENTS = Hash.new { |_, c| "&#x#{c.ord.to_s(16)};".freeze }.update(
    ?".freeze => "&quot;".freeze,
    ?&.freeze => "&amp;".freeze,
    ?'.freeze => "&apos;".freeze,
    ?<.freeze => "&lt;".freeze,
    ?>.freeze => "&gt;".freeze,
  ).freeze

  INVALID_ENCODING_REPLACEMENT = "\\uFFFD".freeze

  def normalize_encoding(text)
    text.to_s.encode(
      Encoding::UTF_8,
      invalid: :replace,
      undef: :replace,
      replace: INVALID_ENCODING_REPLACEMENT
    )
  end

  def escape(text)
    # Make sure it's utf-8, replace illegal characters with ruby-like escapes, and replace special and discouraged characters with entities
    normalize_encoding(text).gsub(ILLEGAL_REGEXP, ILLEGAL_REPLACEMENT).gsub(DISCOURAGED_REGEXP, DISCOURAGED_REPLACEMENTS)
  end

  STRIP_DIFF_COLORS_BLOCK_REGEXP = /^ ( [ ]* ) Diff: (?: \e\[ 0 m )? (?: \n \1 \e\[ \d+ (?: ; \d+ )* m .* )* /x
  STRIP_DIFF_COLORS_CODES_REGEXP = /\e\[ \d+ (?: ; \d+ )* m/x

  def strip_diff_colors(string)
    # XXX: RSpec diffs are appended to the message lines fairly early and will
    # contain ANSI escape codes for colorizing terminal output if the global
    # rspec configuration is turned on, regardless of which notification lines
    # we ask for. We need to strip the codes from the diff part of the message
    # for XML output here.
    #
    # We also only want to target the diff hunks because the failure message
    # itself might legitimately contain ansi escape codes.
    #
    string.sub(STRIP_DIFF_COLORS_BLOCK_REGEXP) { |match| match.gsub(STRIP_DIFF_COLORS_CODES_REGEXP, "".freeze) }
  end
end

RspecJunitFormatter = RSpecJUnitFormatter

if Gem::Version.new(RSpec::Core::Version::STRING) >= Gem::Version.new("3")
  require "rspec_junit_formatter/rspec3"
else
  require "rspec_junit_formatter/rspec2"
end
