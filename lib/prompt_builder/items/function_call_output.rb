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

      # @return [String, Array<Content::Base>, nil] the output from the function; either a plain
      #   string, an array of content objects, or nil (serialized as +""+)
      attr_reader :output

      # @return [Hash, nil] provider-specific extra data
      attr_reader :extra

      # Create a new FunctionCallOutput item.
      #
      # @param id [String, nil] the function call output identifier
      # @param call_id [String] the call identifier
      # @param status [String, nil] the function call output status
      # @param output [String, Array<Content::Base, Hash>, nil] the function output;
      #   Hash elements in an array are normalized into +Content::Base+ objects
      # @param extra [Hash] provider-specific extra keyword arguments
      def initialize(call_id:, output:, id: nil, status: nil, **extra)
        @id = id&.to_s
        @call_id = call_id&.to_s
        @status = status&.to_s
        @output = normalize_output(output)
        @extra = extra.transform_keys(&:to_s)
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
            output: output,
            **hash.except("type", "id", "call_id", "status", "output").transform_keys(&:to_sym)
          )
        end
      end

      # Serialize to a Hash with string keys. A nil output is emitted as an
      # empty string so the on-the-wire shape matches the Open Responses API.
      #
      # @return [Hash]
      def to_h
        hash = {
          "type" => "function_call_output",
          "call_id" => @call_id,
          "output" => serialize_output
        }
        hash["id"] = @id if @id
        hash["status"] = @status if @status
        hash = PromptBuilder.jsonify(@extra).merge(hash) unless @extra.empty?
        hash
      end

      private

      def serialize_output
        case @output
        when nil then ""
        when Array then @output.map(&:to_h)
        else @output
        end
      end

      def normalize_output(output)
        case output
        when String, NilClass
          output
        when Array
          output.map do |c|
            case c
            when Hash
              hash = c.transform_keys(&:to_s)
              unless hash["type"]
                raise InvalidItemError,
                  "Output content hash is missing required \"type\" key: #{hash.inspect}"
              end
              Content::Base.from_h(hash)
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
