# frozen_string_literal: true

module PromptBuilder
  module Serializers
    # Serializer for the Amazon Bedrock Converse API format.
    # Delegates request and response handling to dedicated nested classes.
    class Converse < Base
      autoload :Request, File.expand_path("converse/request", __dir__)
      autoload :Response, File.expand_path("converse/response", __dir__)

      class << self
        # Export a session to Converse request payload.
        #
        # @param session [Session] the session to export
        # @return [Hash] the serialized request payload
        def request_payload(session)
          Request.request_payload(session)
        end
      end
    end
  end
end
