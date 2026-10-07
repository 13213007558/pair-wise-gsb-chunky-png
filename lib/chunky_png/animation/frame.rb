# frozen-string-literal: true

module ChunkyPNG
  class Animation
    # A single frame of an animated PNG. A frame carries the pixels of its
    # own rectangular region, the position of that region on the animation's
    # output canvas, the time the frame should be displayed, and the dispose
    # and blend operations that determine how the frame is rendered.
    #
    # @see ChunkyPNG::Animation
    class Frame
      # @return [ChunkyPNG::Canvas] The pixels of this frame's region.
      attr_accessor :canvas

      # @return [Integer] The x-offset of this frame's region on the
      #   animation's output canvas.
      attr_accessor :x_offset

      # @return [Integer] The y-offset of this frame's region on the
      #   animation's output canvas.
      attr_accessor :y_offset

      # @return [Integer] The numerator of this frame's display delay
      #   fraction, in seconds.
      attr_accessor :delay_num

      # @return [Integer] The denominator of this frame's display delay
      #   fraction, in seconds. A value of 0 is interpreted as 100.
      attr_accessor :delay_den

      # @return [Integer] The dispose operation of this frame. One of
      #   ChunkyPNG::Animation::DISPOSE_OP_NONE,
      #   ChunkyPNG::Animation::DISPOSE_OP_BACKGROUND or
      #   ChunkyPNG::Animation::DISPOSE_OP_PREVIOUS.
      attr_accessor :dispose_op

      # @return [Integer] The blend operation of this frame. One of
      #   ChunkyPNG::Animation::BLEND_OP_SOURCE or
      #   ChunkyPNG::Animation::BLEND_OP_OVER.
      attr_accessor :blend_op

      # Initializes a new Frame instance.
      # @param [ChunkyPNG::Canvas] canvas The pixels of this frame's region.
      # @param [Integer] x_offset The x-offset of the frame's region.
      # @param [Integer] y_offset The y-offset of the frame's region.
      # @param [Integer] delay_num The numerator of the display delay
      #   fraction, in seconds.
      # @param [Integer] delay_den The denominator of the display delay
      #   fraction, in seconds.
      # @param [Numeric, nil] delay The display delay in seconds. When
      #   provided, this overrides delay_num and delay_den. Use a Rational
      #   value for an exact delay fraction.
      # @param [Integer] dispose_op The dispose operation for this frame.
      # @param [Integer] blend_op The blend operation for this frame.
      def initialize(canvas, x_offset: 0, y_offset: 0, delay_num: 1, delay_den: 100, delay: nil,
        dispose_op: ChunkyPNG::Animation::DISPOSE_OP_NONE, blend_op: ChunkyPNG::Animation::BLEND_OP_SOURCE)
        @canvas = canvas
        @x_offset = x_offset
        @y_offset = y_offset
        @dispose_op = dispose_op
        @blend_op = blend_op

        if delay
          delay = delay.to_r
          delay_num, delay_den = delay.numerator, delay.denominator
        end
        @delay_num = delay_num
        @delay_den = delay_den
      end

      # @return [Integer] The width of this frame's region.
      def width
        canvas.width
      end

      # @return [Integer] The height of this frame's region.
      def height
        canvas.height
      end

      # Returns the time this frame should be displayed, in seconds.
      # @return [Rational] The display delay of this frame in seconds.
      def delay
        denominator = delay_den.zero? ? 100 : delay_den
        Rational(delay_num, denominator)
      end
    end
  end
end
