# frozen-string-literal: true

module ChunkyPNG
  # A ChunkyPNG::Frame is a {ChunkyPNG::Canvas} that also knows its position
  # on the animation's default image canvas, its display duration (kept as a
  # numerator/denominator pair) and the dispose/blend operations to use while
  # rendering the frame.
  #
  # The canvas itself holds the frame's original pixels, i.e. the raw
  # rectangle described by its fcTL chunk. The fully composited output for a
  # frame is available through {ChunkyPNG::Animation#composited_frames}.
  #
  # @see ChunkyPNG::Animation
  class Frame < Canvas
    # @return [Integer] The x-offset of this frame on the animation canvas.
    attr_accessor :x_offset

    # @return [Integer] The y-offset of this frame on the animation canvas.
    attr_accessor :y_offset

    # @return [Integer] The numerator of the frame duration fraction.
    attr_accessor :delay_num

    # @return [Integer] The denominator of the frame duration fraction; 0 is
    #   interpreted as 100 by {#duration}.
    attr_accessor :delay_den

    # @return [Integer] The dispose operation (ChunkyPNG::APNG_DISPOSE_OP_*).
    attr_accessor :dispose_op

    # @return [Integer] The blend operation (ChunkyPNG::APNG_BLEND_OP_*).
    attr_accessor :blend_op

    # @overload initialize(width, height, initial = ChunkyPNG::Color::TRANSPARENT, options = {})
    #   @param [Integer] width The width of the frame.
    #   @param [Integer] height The height of the frame.
    #   @param [Integer, Array<Integer>] initial The background color or
    #     initial pixel values for the frame.
    #   @param [Hash] options The frame metadata.
    #   @option options [Integer] :x_offset (0) The x-offset on the canvas.
    #   @option options [Integer] :y_offset (0) The y-offset on the canvas.
    #   @option options [Integer] :delay_num (1) The delay numerator.
    #   @option options [Integer] :delay_den (100) The delay denominator.
    #   @option options [Integer, Symbol] :dispose_op (ChunkyPNG::APNG_DISPOSE_OP_NONE)
    #     The dispose operation, as an APNG constant or +:none+, +:background+
    #     or +:previous+.
    #   @option options [Integer, Symbol] :blend_op (ChunkyPNG::APNG_BLEND_OP_SOURCE)
    #     The blend operation, as an APNG constant or +:source+ or +:over+.
    def initialize(width, height, initial = ChunkyPNG::Color::TRANSPARENT, options = {})
      options = Frame.default_options.merge(options)
      super(width, height, initial)
      @x_offset   = options[:x_offset]
      @y_offset   = options[:y_offset]
      @delay_num  = options[:delay_num]
      @delay_den  = options[:delay_den]
      @dispose_op = Frame.dispose_op_value(options[:dispose_op])
      @blend_op   = Frame.blend_op_value(options[:blend_op])
    end

    # Creates a Frame that shares the pixels of an existing canvas.
    # @param [ChunkyPNG::Canvas] canvas The canvas containing the frame pixels.
    # @param [Hash] options The frame metadata (see {#initialize}).
    # @return [ChunkyPNG::Frame] The new frame instance.
    def self.from_canvas(canvas, options = {})
      frame = new(canvas.width, canvas.height, canvas.pixels.dup, options)
      frame.encoding_palette = canvas.encoding_palette if canvas.respond_to?(:encoding_palette)
      frame
    end

    # Initializes a copy of another frame, duplicating its pixels and metadata.
    def initialize_copy(other)
      super(other)
      @x_offset   = other.x_offset
      @y_offset   = other.y_offset
      @delay_num  = other.delay_num
      @delay_den  = other.delay_den
      @dispose_op = other.dispose_op
      @blend_op   = other.blend_op
    end

    # @return [Float] The duration of the frame in seconds. A delay
    #   denominator of zero is treated as 100, per the APNG specification.
    def duration
      delay_num.to_f / (delay_den.nil? || delay_den == 0 ? 100 : delay_den)
    end

    # Converts a dispose operation option to its APNG constant value.
    # @param value [Integer, Symbol] The constant value or +:none+,
    #   +:background+ or +:previous+.
    # @return [Integer] The APNG dispose operation constant.
    def self.dispose_op_value(value)
      case value
      when :none, nil then ChunkyPNG::APNG_DISPOSE_OP_NONE
      when :background then ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND
      when :previous then ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS
      else Integer(value)
      end
    end

    # Converts a blend operation option to its APNG constant value.
    # @param value [Integer, Symbol] The constant value or +:source+ or
    #   +:over+.
    # @return [Integer] The APNG blend operation constant.
    def self.blend_op_value(value)
      case value
      when :source, nil then ChunkyPNG::APNG_BLEND_OP_SOURCE
      when :over then ChunkyPNG::APNG_BLEND_OP_OVER
      else Integer(value)
      end
    end

    # @return [Hash] The default frame metadata.
    def self.default_options
      {
        x_offset: 0,
        y_offset: 0,
        delay_num: 1,
        delay_den: 100,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE,
        blend_op: ChunkyPNG::APNG_BLEND_OP_SOURCE,
      }
    end
  end
end
