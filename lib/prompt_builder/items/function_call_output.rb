# frozen_string_literal: true

module PromptBuilder
  module Items
    # Represents the output of a function call. This is added to the
    # conversation after a tool has been invoked.
    class FunctionCallOutput < Base
      # @return [String, nil] the function call output identifier
      attr_reader :id

      # @return [String] the call identifier this output corresponds to
      attr_reader :call_id

      # @return [String, nil] the function call output status
      attr_reader :status

      # @return [String, Array<Content::Base>] the output from the function; either a plain
      #   string or an array of content objects
      attr_reader :output

      # Create a new FunctionCallOutput item.
      #
      # @param id [String, nil] the function call output identifier
      # @param call_id [String] the call identifier
      # @param status [String, nil] the function call output status
      # @param output [String, Array<Content::Base>] the function output
      def initialize(call_id:, output:, id: nil, status: nil)
        @id = id&.to_s
        @call_id = call_id&.to_s
        @status = status&.to_s
        @output = normalize_output(output)
      end

      class << self
        # Deserialize a FunctionCallOutput from a Hash.
        #
        # @param hash [Hash] a Hash with string keys
        # @return [FunctionCallOutput]
        def from_h(hash)
          output = hash["output"]
          output = output.map { |c| Content::Base.from_h(c) } if output.is_a?(Array)
          new(
            id: hash["id"],
            call_id: hash["call_id"],
            status: hash["status"],
            output: output
          )
        end
      end

      # Serialize to a Hash with string keys.
      #
      # @return [Hash]
      def to_h
        hash = {
          "type" => "function_call_output",
          "call_id" => @call_id,
          "output" => @output.is_a?(Array) ? @output.map(&:to_h) : @output
        }
        hash["id"] = @id if @id
        hash["status"] = @status if @status
        hash
      end

      private

      def normalize_output(output)
        case output
        when String, NilClass
          output
        when Array
          output.map do |c|
            case c
            when Hash
              Content::Base.from_h(c)
            when Content::Base
              c
            else
              raise InvalidItemError, "Unsupported output element: #{c.class}"
            end
          end
        else
          raise InvalidItemError, "Unsupported output type: #{output.class}"
        end
      end
    end
  end
end
