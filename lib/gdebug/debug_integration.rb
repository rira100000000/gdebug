# frozen_string_literal: true

require "debug"

module Gdebug
  module DebugIntegration
    @ai_triggered = false

    class << self
      attr_accessor :ai_triggered

      def setup
        return unless defined?(DEBUGGER__::SESSION)

        register_ai_command
        setup_keybinding
        puts "[gdebug] AI assistant loaded. Use 'ai <question>' or Ctrl+Space."
      end

      private

      def register_ai_command
        # Extend the Session class to add our command
        DEBUGGER__::SESSION.class.prepend(GdebugCommands)
      end

      def setup_keybinding
        return unless defined?(Reline::LineEditor)

        Reline::LineEditor.prepend(Module.new do
          private def gdebug_ai_prefix(key)
            Gdebug::DebugIntegration.ai_triggered = true
            finish
          end
        end)

        Reline.core.config.add_default_key_binding_by_keymap(:emacs, [0], :gdebug_ai_prefix)
      end
    end

    module GdebugCommands
      def process_command(line)
        if Gdebug::DebugIntegration.ai_triggered
          Gdebug::DebugIntegration.ai_triggered = false
          question = line.strip
          return :retry if question.empty?

          handle_ai_question(question)
          return :retry
        end

        if line.start_with?("ai ")
          question = line.sub(/^ai\s+/, "").strip
          return :retry if question.empty?

          handle_ai_question(question)
          return :retry
        end

        super
      end

      private

      def handle_ai_question(question)
        # Get the current frame's binding via ThreadClient (@tc)
        current_binding = @tc&.current_frame&.eval_binding

        unless current_binding
          puts "[gdebug] Error: No current frame available"
          return
        end

        context = Gdebug::ContextBuilder.new(current_binding).build
        client = Gdebug::AiClient.new
        client.ask(question, context, binding: current_binding)
      rescue Gdebug::ConfigurationError => e
        puts "[gdebug] #{e.message}"
      rescue StandardError => e
        puts "[gdebug] Error: #{e.message}"
        puts e.backtrace.first(3).join("\n") if Gdebug.configuration.debug
      end
    end
  end
end
