module TemplateStreaming
  class << self
    def configure(config)
      config.each do |key, value|
        send "#{key}=", value
      end
    end

    #
    # If true, always reference the flash before returning from the
    # action when rendering progressively.
    #
    # This is required for the flash to work with progressive
    # rendering, but unlike standard Rails behavior, will cause the
    # flash to be swept even if it's never referenced in the
    # views. This usually isn't an issue, as flash messages are
    # typically rendered in the layout, causing a reference anyway.
    #
    # Default: true.
    #
    attr_accessor :autosweep_flash

    #
    # If true, always set the authenticity token before returning from
    # the action when rendering progressively.
    #
    # This is required for the authenticity token to work with
    # progressive rendering, but unlike standard Rails behavior, will
    # cause the token to be set (and thus the session updated) even if
    # it's never referenced in views.
    #
    # Default: true.
    #
    attr_accessor :set_authenticity_token
  end

  self.autosweep_flash = true
  self.set_authenticity_token = true

  module Controller
    def self.included(base)
      base.class_eval do
        extend ClassMethods
        alias_method_chain :render, :template_streaming
        alias_method_chain :render_to_string, :template_streaming
        helper_method :flush, :push

        include ActiveSupport::Callbacks
        define_callbacks :when_streaming_template
      end
    end

    module ClassMethods
      def self.extended(base)
        class << base
          alias_method_chain :layout, :template_streaming
        end
      end

      def layout_with_template_streaming(template_name, options={}, *rest)
        options.key?(:progressive) and
          write_inheritable_attribute(:render_progressively, !!options.delete(:progressive))
        layout_without_template_streaming(template_name, options={}, *rest)
      end

      def render_progressively?
        read_inheritable_attribute(:render_progressively)
      end
    end

    def render_with_template_streaming(*args, &block)
      with_template_streaming_condition(*args) do |condition|
        if condition
          @performed_render = true
          @streaming_body = StreamingBody.new(progressive_rendering_threshold) do
            @performed_render = false
            last_piece = render_without_template_streaming(*args, &block)
            # The original render will clobber our response.body, so
            # we must push the buffer ourselves.
            push last_piece
          end
          response.body = @streaming_body
          response.prepare!
          flash if TemplateStreaming.autosweep_flash
          form_authenticity_token if TemplateStreaming.set_authenticity_token
          run_callbacks :when_streaming_template

          # Normally, @_flash is removed after #perform_action, which
          # means calling #flash in the view would cause a new
          # FlashHash to be constructed. On top of that, the flash is
          # swept on construction, which results in sweeping the flash
          # twice, obliterating its contents.
          #
          # So, we preserve the flash here under a different ivar, and
          # override the #flash helper to return it.
          if defined?(@_flash)
            @template_streaming_flash = @_flash
          end
        else
          render_without_template_streaming(*args, &block)
        end
      end
    end

    # Override to ensure calling render_to_string from a helper
    # doesn't trigger template streaming.
    def render_to_string_with_template_streaming(*args, &block) # :nodoc
      # Ensure renders within a render_to_string aren't considered
      # top-level.
      with_template_streaming_condition do
        render_to_string_without_template_streaming(*args, &block)
      end
    end

    #
    # Flush the current template's output buffer out to the client
    # immediately.
    #
    def flush
      if @streaming_body && !@template.output_buffer.nil?
        push @template.output_buffer.slice!(0..-1)
      end
    end

    #
    # Push the given data to the client immediately.
    #
    def push(data)
      if @streaming_body
        @streaming_body.push(data)
        flush_thin
      end
    end

    def template_streaming_flash # :nodoc:
      @template_streaming_flash
    end

    private # --------------------------------------------------------

    #
    # Yield true if we should intercept this render call, false
    # otherwise.
    #
    def with_template_streaming_condition(*args)
      @render_stack_height ||= 0
      @render_stack_height += 1
      begin
        # Only install our StreamingBody in the toplevel #render call.
        @render_stack_height == 1 or
          return yield(false)

        (options = args.last).is_a?(Hash) or
          options = {}

        self.class.render_progressively? or
          return yield(false)

        if options
          yield((UNSTREAMABLE_KEYS & options.keys).empty?)
        else
          yield args.first != :update
        end
      ensure
        @render_stack_height -= 1
      end
    end

    UNSTREAMABLE_KEYS = [:text, :xml, :json, :js, :update, :nothing]

    #
    # The number of bytes that must be received by the client before
    # anything will be rendered.
    #
    def progressive_rendering_threshold
      content_type = response.header['Content-type']
      content_type.nil? || content_type =~ %r'\Atext/html' or
        return 0

      case request.env['HTTP_USER_AGENT']
      when /MSIE/
        255
      when /Chrome/
        # Note: Chrome's UA string includes "Safari", so it must precede.
        2048
      when /Safari/
        1024
      else
        0
      end
    end

    #
    # Force EventMachine to flush its buffer when using Thin.
    #
    def flush_thin
      connection = request.env['template_streaming.thin_connection'] and
        EventMachineFlush.flush(connection)
    end
  end

  # Only prepare once.
  module Response
    def self.included(base)
      base.alias_method_chain :prepare!, :template_streaming
      base.alias_method_chain :set_content_length!, :template_streaming
    end

    def prepare_with_template_streaming!
      return if defined?(@prepared)
      prepare_without_template_streaming!
      @prepared = true
    end

    def set_content_length_with_template_streaming!
      if body.is_a?(StreamingBody)
        # pass
      else
        set_content_length_without_template_streaming!
      end
    end
  end

  module View
    def self.included(base)
      base.alias_method_chain :_render_with_layout, :template_streaming
      base.alias_method_chain :flash, :template_streaming
    end

    def _render_with_layout_with_template_streaming(options, local_assigns, &block)
      if block_given?
        _render_with_layout_without_template_streaming(options, local_assigns, &block)
      elsif options[:layout].is_a?(ActionView::Template) && controller.class.render_progressively?
        # Toplevel render call, from the controller.
        layout = options.delete(:layout)
        with_render_proc_for_layout(options) do
          render(options.merge(:file => layout.path_without_format_and_extension))
        end
      elsif options[:progressive]
        layout = options.delete(:layout)
        with_render_proc_for_layout(options) do
          if (options[:inline] || options[:file] || options[:text])
            render(:file => layout, :locals => local_assigns)
          else
            render(options.merge(:partial => layout))
          end
        end
      else
        # We may have set @_proc_for_layout in an outer render, but
        # render(:layout => , :partial =>) uses @content_for_layout, and
        # @_proc_for_layout overrides @content_for_layout. Thus, we need to
        # clear @_proc_for_layout for the duration of this render.
        original_proc_for_layout = @_proc_for_layout
        @_proc_for_layout = nil
        begin
          _render_with_layout_without_template_streaming(options, local_assigns, &block)
        ensure
          @_proc_for_layout = original_proc_for_layout
        end
      end
    end

    def with_render_proc_for_layout(options)
      original_proc_for_layout = @_proc_for_layout
      @_proc_for_layout = lambda do |*args|
        if args.empty?
          render(options)
        else
          instance_variable_get(:"@content_for_#{args.first}")
        end
      end
      begin
        # TODO: what is @cached_content_for_layout in base.rb ?
        yield
      ensure
        @_proc_for_layout = original_proc_for_layout
      end
    end

    def flash_with_template_streaming # :nodoc:
      # Override ActionView::Base#flash to prevent a double-sweep.
      controller.instance_eval { @template_streaming_flash || flash }
    end
  end

  class StreamingBody
    def initialize(threshold, &block)
      @process = block
      @bytes_to_threshold = threshold
    end

    def each(&block)
      @push = block
      @process.call
    end

    def push(data)
      if @bytes_to_threshold > 0
        @push.call(data + padding(@bytes_to_threshold - data.length))
        @bytes_to_threshold = 0
      else
        @push.call(data)
      end
    end

    private  # -------------------------------------------------------

    def padding(length)
      return '' if length <= 0
      content_length = [length - 7, 0].max
      "<!--#{'+'*content_length}-->"
    end
  end

  ActionView::Base.send :include, View
  ActionController::Base.send :include, Controller
  ActionController::Response.send :include, Response
  ActionController::Dispatcher.middleware.insert 0, Rack::Chunked
end

# Please let there be a better way to do this...
#
# We need to force Thin (EventMachine, really) to flush its output
# buffer before ending the current EventMachine tick. We can't use
# EventMachine.defer or .next_tick, as that would require returning
# from the call to the response body's #each. I'm not convinced Thin
# could even be rearchitected to support this without resorting to
# Threads, Continuations, or Fibers.
#
# Here, we hack Thin to add a handle to the connection object to the
# request environment, which we pass to EventMachineFlush, a horrid
# C++ hack. In ruby 1.8.7 we could use env[async.callback].receiver,
# but we want to support 1.8.6 for now too.
if defined?(Thin)
  begin
    require 'event_machine_flush'
  rescue LoadError
    raise "Template Streaming on Thin requires the event_machine_flush gem."
  end

  Rails.configuration.after_initialize do
    Thin::Connection.class_eval do
      def pre_process_with_template_streaming(*args, &block)
        @request.env['template_streaming.thin_connection'] = self
        pre_process_without_template_streaming(*args, &block)
      end
      alias_method_chain :pre_process, :template_streaming
    end
  end
end
