# frozen_string_literal: true

require "debug"

module Gdebug
  module DebugIntegration
    @ai_triggered = false

    class << self
      attr_accessor :ai_triggered, :auto_continue

      def pending_debug_commands
        @pending_debug_commands ||= []
      end

      def add_pending_debug_command(cmd)
        pending_debug_commands << cmd
      end

      def take_pending_debug_commands
        cmds = @pending_debug_commands || []
        @pending_debug_commands = []
        cmds
      end

      def auto_continue?
        @auto_continue
      end

      def setup
        return unless defined?(DEBUGGER__::SESSION)

        register_ai_command
        register_debug_tools
        setup_keybinding
        puts "[gdebug] AI assistant loaded. Use 'ai <question>' or Ctrl+Space."
      end

      private

      def register_ai_command
        # Extend the Session class to add our command
        DEBUGGER__::SESSION.class.prepend(GdebugCommands)
      end

      def register_debug_tools
        require_relative "tools/run_debug_command"
        Gdebug::Tools.register(Gdebug::Tools::RunDebugCommand)

        # girb-ruby_llm's dynamic tools look up via Girb::Tools.find_tool(),
        # so we need Girb::Tools to also find gdebug-only tools
        if defined?(Girb::Tools)
          original_find_tool = Girb::Tools.method(:find_tool)
          Girb::Tools.define_singleton_method(:find_tool) do |name|
            original_find_tool.call(name) || Gdebug::Tools.find_tool(name)
          end
        end
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
      MAX_AUTO_CONTINUE = 20

      def wait_command
        if Gdebug::DebugIntegration.auto_continue?
          @gdebug_auto_continue_count ||= 0
          @gdebug_auto_continue_count += 1

          if @gdebug_auto_continue_count > MAX_AUTO_CONTINUE
            @ui.puts "[gdebug] Auto-continue limit reached (#{MAX_AUTO_CONTINUE})"
            Gdebug::DebugIntegration.auto_continue = false
            @gdebug_auto_continue_count = 0
            return :retry
          end

          Gdebug::DebugIntegration.auto_continue = false
          handle_ai_continuation

          pending_cmds = Gdebug::DebugIntegration.take_pending_debug_commands
          if pending_cmds.any?
            pending_cmds.each do |cmd|
              result = process_command(cmd)
              return result unless result == :retry
            end
          end
          return :retry
        else
          @gdebug_auto_continue_count = 0
        end

        super
      end

      def process_command(line)
        if Gdebug::DebugIntegration.ai_triggered
          Gdebug::DebugIntegration.ai_triggered = false
          question = line.strip
          return :retry if question.empty?

          handle_ai_question(question)
          pending_cmds = Gdebug::DebugIntegration.take_pending_debug_commands
          if pending_cmds.any?
            pending_cmds.each do |cmd|
              result = super(cmd)
              return result unless result == :retry
            end
          end
          return :retry
        end

        if line.start_with?("ai ")
          question = line.sub(/^ai\s+/, "").strip
          return :retry if question.empty?

          handle_ai_question(question)
          pending_cmds = Gdebug::DebugIntegration.take_pending_debug_commands
          if pending_cmds.any?
            pending_cmds.each do |cmd|
              result = super(cmd)
              return result unless result == :retry
            end
          end
          return :retry
        end

        # Auto-detect natural language (non-ASCII input) and route to AI
        if line.match?(/[^\x00-\x7F]/)
          question = line.strip
          return :retry if question.empty?

          handle_ai_question(question)
          pending_cmds = Gdebug::DebugIntegration.take_pending_debug_commands
          if pending_cmds.any?
            pending_cmds.each do |cmd|
              result = super(cmd)
              return result unless result == :retry
            end
          end
          return :retry
        end

        super
      end

      private

      def handle_ai_continuation
        current_binding = @tc&.current_frame&.eval_binding
        unless current_binding
          @ui.puts "[gdebug] Error: No current frame available"
          return
        end

        context = Gdebug::ContextBuilder.new(current_binding).build
        client = Gdebug::AiClient.new
        continuation = "(auto-continue: The debug command has been executed. Analyze the new state and continue your task.)"
        client.ask(continuation, context, binding: current_binding)
      rescue StandardError => e
        @ui.puts "[gdebug] Auto-continue error: #{e.message}"
        Gdebug::DebugIntegration.auto_continue = false
      end

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
