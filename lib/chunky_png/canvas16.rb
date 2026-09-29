# frozen-string-literal: true

require "chunky_png/canvas16/png_decoding"
require "chunky_png/canvas16/png_encoding"

module ChunkyPNG
  # The ChunkyPNG::Canvas16 class represents a raster image with 16 bits per
  # channel, as a matrix of pixels.
  #
  # Whereas {ChunkyPNG::Canvas} stores every pixel as a single 32-bit integer
  # (8 bits per channel), this class stores every pixel as an array of 16-bit
  # sample values (0-65535), one per channel. This makes it possible to read
  # and write 16-bit PNG images without losing the information stored in the
  # low bytes of the samples.
  #
  # The number of samples per pixel is determined by the color mode of the
  # canvas. Grayscale (1 sample), grayscale + alpha (2 samples), truecolor
  # (3 samples) and truecolor + alpha (4 samples) are supported. Indexed
  # images are not supported, because the PNG specification only allows
  # 8-bit samples for palette entries.
  #
  # Converting between this class and the 8-bit {ChunkyPNG::Canvas} is always
  # explicit: use {Canvas16.from_canvas} to upscale an 8-bit canvas, and
  # {#to_canvas} to downsample to 8 bits per channel using a rounding rule
  # of your choice.
  class Canvas16
    include PNGEncoding
    extend  PNGDecoding
    extend  ChunkyPNG::Canvas::Adam7Interlacing

    # @return [Integer] The maximum value of a single sample.
    SAMPLE_MAX = 0xffff

    # Maps the supported color modes to the number of samples per pixel.
    # @private
    CHANNELS = {
      ChunkyPNG::COLOR_GRAYSCALE       => 1,
      ChunkyPNG::COLOR_GRAYSCALE_ALPHA => 2,
      ChunkyPNG::COLOR_TRUECOLOR       => 3,
      ChunkyPNG::COLOR_TRUECOLOR_ALPHA => 4,
    }.freeze

    # @return [Integer] The number of columns in this canvas.
    attr_reader :width

    # @return [Integer] The number of rows in this canvas.
    attr_reader :height

    # @return [Integer] The color mode of this canvas. One of
    #   ChunkyPNG::COLOR_GRAYSCALE, ChunkyPNG::COLOR_GRAYSCALE_ALPHA,
    #   ChunkyPNG::COLOR_TRUECOLOR or ChunkyPNG::COLOR_TRUECOLOR_ALPHA.
    attr_reader :color_mode

    # @return [Array<Array<Integer>>] The list of pixels in this canvas. Every
    #   pixel is an array of 16-bit sample values, one per channel. This array
    #   always should have +width * height+ elements.
    attr_reader :pixels

    #################################################################
    # CONSTRUCTORS
    #################################################################

    # Initializes a new Canvas16 instance.
    #
    # @param [Integer] width The width in pixels of this canvas.
    # @param [Integer] height The height in pixels of this canvas.
    # @param [Integer] color_mode The color mode of this canvas. Determines
    #   the number of 16-bit samples per pixel.
    # @param [Array] initial Either an array of <tt>width * height</tt> pixels
    #   (each an array of samples), or a single pixel (an array of samples)
    #   used as the background for the whole canvas. Defaults to all zero
    #   samples.
    def initialize(width, height, color_mode = ChunkyPNG::COLOR_TRUECOLOR_ALPHA, initial = nil)
      unless CHANNELS.key?(color_mode)
        raise ChunkyPNG::NotSupported, "Color mode #{color_mode} is not supported for 16-bit canvases!"
      end

      @width, @height, @color_mode = width, height, color_mode

      if initial.nil?
        @pixels = Array.new(width * height) { Array.new(channels, 0) }
      elsif initial.empty? || initial.first.is_a?(Array)
        pixel_count = width * height
        unless initial.length == pixel_count
          raise ArgumentError, "The initial array should have #{width}x#{height} = #{pixel_count} elements!"
        end
        @pixels = initial
      else
        assert_sample_count!(initial)
        @pixels = Array.new(width * height) { initial.dup }
      end
    end

    # Initializes a new Canvas16 instance when being cloned.
    # @param [ChunkyPNG::Canvas16] other The canvas to duplicate.
    # @return [void]
    # @private
    def initialize_copy(other)
      @width, @height, @color_mode = other.width, other.height, other.color_mode
      @pixels = other.pixels.map(&:dup)
    end

    # Creates a new 16-bit canvas by explicitly upscaling an 8-bit
    # {ChunkyPNG::Canvas}. Every 8-bit sample +v+ is mapped to
    # <tt>v * 257</tt>, so 0x00 becomes 0x0000 and 0xff becomes 0xffff.
    #
    # @param [ChunkyPNG::Canvas] canvas The 8-bit canvas to convert.
    # @param [Integer] color_mode The color mode for the new canvas.
    # @return [ChunkyPNG::Canvas16] The converted canvas.
    def self.from_canvas(canvas, color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA)
      unless CHANNELS.key?(color_mode)
        raise ChunkyPNG::NotSupported, "Color mode #{color_mode} is not supported for 16-bit canvases!"
      end

      pixels = canvas.pixels.map do |color|
        case color_mode
          when ChunkyPNG::COLOR_GRAYSCALE       then [upscale_sample(ChunkyPNG::Color.grayscale_teint(color))]
          when ChunkyPNG::COLOR_GRAYSCALE_ALPHA then [upscale_sample(ChunkyPNG::Color.grayscale_teint(color)), upscale_sample(ChunkyPNG::Color.a(color))]
          when ChunkyPNG::COLOR_TRUECOLOR       then [upscale_sample(ChunkyPNG::Color.r(color)), upscale_sample(ChunkyPNG::Color.g(color)), upscale_sample(ChunkyPNG::Color.b(color))]
          when ChunkyPNG::COLOR_TRUECOLOR_ALPHA then [upscale_sample(ChunkyPNG::Color.r(color)), upscale_sample(ChunkyPNG::Color.g(color)), upscale_sample(ChunkyPNG::Color.b(color)), upscale_sample(ChunkyPNG::Color.a(color))]
        end
      end
      new(canvas.width, canvas.height, color_mode, pixels)
    end

    #################################################################
    # PROPERTIES
    #################################################################

    # Returns the number of 16-bit samples per pixel for this canvas.
    # @return [Integer] The number of channels of the canvas' color mode.
    def channels
      CHANNELS[color_mode]
    end

    # Returns the dimension (width x height) for this canvas.
    # @return [ChunkyPNG::Dimension] A dimension instance with the width and
    #   height set for this canvas.
    def dimension
      ChunkyPNG::Dimension.new(width, height)
    end

    # Returns the area of this canvas in number of pixels.
    # @return [Integer] The number of pixels in this canvas.
    def area
      pixels.length
    end

    # Replaces a single pixel in this canvas.
    # @param [Integer] x The x-coordinate of the pixel (column).
    # @param [Integer] y The y-coordinate of the pixel (row).
    # @param [Array<Integer>] samples The new sample values for this pixel.
    # @return [Array<Integer>] The new sample values for this pixel.
    # @raise [ChunkyPNG::OutOfBounds] when the coordinates are outside of the
    #   image's dimensions.
    def []=(x, y, samples)
      assert_xy!(x, y)
      assert_sample_count!(samples)
      @pixels[y * width + x] = samples
    end

    # Replaces a single pixel in this canvas, without bounds checking.
    # @param [Integer] x The x-coordinate of the pixel (column).
    # @param [Integer] y The y-coordinate of the pixel (row).
    # @param [Array<Integer>] samples The new sample values for this pixel.
    # @return [Array<Integer>] The new sample values for this pixel.
    def set_pixel(x, y, samples)
      @pixels[y * width + x] = samples
    end

    # Returns a single pixel's sample values from this canvas.
    # @param [Integer] x The x-coordinate of the pixel (column).
    # @param [Integer] y The y-coordinate of the pixel (row).
    # @return [Array<Integer>] The 16-bit sample values at the provided
    #   coordinates.
    # @raise [ChunkyPNG::OutOfBounds] when the coordinates are outside of the
    #   image's dimensions.
    def [](x, y)
      assert_xy!(x, y)
      @pixels[y * width + x]
    end

    # Returns a single pixel from this canvas, without checking bounds.
    # @param [Integer] x The x-coordinate of the pixel (column).
    # @param [Integer] y The y-coordinate of the pixel (row).
    # @return [Array<Integer>] The 16-bit sample values at the provided
    #   coordinates.
    def get_pixel(x, y)
      @pixels[y * width + x]
    end

    # Returns an extracted row as vector of pixels.
    # @param [Integer] y The 0-based row index.
    # @return [Array<Array<Integer>>] The vector of pixels in the requested row.
    def row(y)
      assert_y!(y)
      pixels.slice(y * width, width)
    end

    # Checks whether the given x- and y-coordinate are in the range of the
    # canvas.
    # @param [Integer] x The x-coordinate of the pixel (column).
    # @param [Integer] y The y-coordinate of the pixel (row).
    # @return [true, false] True if the x- and y-coordinate is in the range of
    #   this canvas.
    def include_xy?(x, y)
      y >= 0 && y < height && x >= 0 && x < width
    end

    # Equality check to compare this canvas with other canvases.
    # @param other The object to compare this canvas to.
    # @return [true, false] True if the size, color mode and sample values of
    #   the other canvas are exactly the same as this canvas'.
    def eql?(other)
      other.is_a?(self.class) &&
        other.pixels == pixels &&
        other.width == width &&
        other.height == height &&
        other.color_mode == color_mode
    end

    alias == eql?

    #################################################################
    # 8-BIT CONVERSION
    #################################################################

    # Explicitly converts this canvas to an 8-bit {ChunkyPNG::Canvas},
    # downsampling every 16-bit sample to 8 bits using the chosen rounding
    # rule. This is the only place where the low bytes of the samples get
    # discarded.
    #
    # @param [Symbol] rounding The rounding rule to apply to every sample:
    #   * +:down+ - use the high byte of the sample (<tt>value >> 8</tt>).
    #     This matches the historic behavior of ChunkyPNG when reading
    #     16-bit images into an 8-bit canvas.
    #   * +:up+ - round up to the next 8-bit value, i.e.
    #     <tt>ceil(value * 255 / 65535)</tt>.
    #   * +:nearest+ - round to the nearest 8-bit value, i.e.
    #     <tt>round(value * 255 / 65535)</tt>.
    # @return [ChunkyPNG::Canvas] The 8-bit version of this canvas.
    def to_canvas(rounding = :down)
      pixels8 = pixels.map do |samples|
        values = samples.map { |sample| Canvas16.resample_sample_to_8bit(sample, rounding) }
        case color_mode
          when ChunkyPNG::COLOR_GRAYSCALE       then ChunkyPNG::Color.grayscale(values[0])
          when ChunkyPNG::COLOR_GRAYSCALE_ALPHA then ChunkyPNG::Color.grayscale_alpha(values[0], values[1])
          when ChunkyPNG::COLOR_TRUECOLOR       then ChunkyPNG::Color.rgb(values[0], values[1], values[2])
          when ChunkyPNG::COLOR_TRUECOLOR_ALPHA then ChunkyPNG::Color.rgba(values[0], values[1], values[2], values[3])
        end
      end
      ChunkyPNG::Canvas.new(width, height, pixels8)
    end

    # Downsamples a single 16-bit sample to an 8-bit value using the given
    # rounding rule.
    # @param [Integer] value The 16-bit sample value (0-65535).
    # @param [Symbol] rounding The rounding rule: +:down+, +:up+ or +:nearest+.
    # @return [Integer] The 8-bit sample value (0-255).
    # @see #to_canvas
    def self.resample_sample_to_8bit(value, rounding)
      case rounding
        when :down    then value >> 8
        when :up      then (value * 0xff + 0xfffe) / 0xffff
        when :nearest then (value * 0xff + 0x7fff) / 0xffff
        else raise ArgumentError, "Unknown rounding rule: #{rounding.inspect}. Use :down, :up or :nearest."
      end
    end

    # Upscales a single 8-bit sample to a 16-bit value.
    # @param [Integer] value The 8-bit sample value (0-255).
    # @return [Integer] The 16-bit sample value (0-65535).
    # @see Canvas16.from_canvas
    def self.upscale_sample(value)
      (value << 8) | value
    end

    # Alternative implementation of the inspect method.
    # @return [String] A nicely formatted string representation of this canvas.
    # @private
    def inspect
      inspected = +"<#{self.class.name} #{width}x#{height} (color mode #{color_mode}) ["
      for y in 0...height
        inspected << "\n\t[" << row(y).map { |p| p.map { |s| format("0x%04x", s) }.join(" ") }.join("] [") << "]"
      end
      inspected << "\n]>"
    end

    protected

    # Throws an exception if the x-coordinate is out of bounds.
    def assert_x!(x)
      unless x >= 0 && x < width
        raise ChunkyPNG::OutOfBounds, "Column index #{x} out of bounds!"
      end
      true
    end

    # Throws an exception if the y-coordinate is out of bounds.
    def assert_y!(y)
      unless y >= 0 && y < height
        raise ChunkyPNG::OutOfBounds, "Row index #{y} out of bounds!"
      end
      true
    end

    # Throws an exception if the x- or y-coordinate is out of bounds.
    def assert_xy!(x, y)
      unless include_xy?(x, y)
        raise ChunkyPNG::OutOfBounds, "Coordinates (#{x},#{y}) out of bounds!"
      end
      true
    end

    # Throws an exception if the number of samples does not match the number
    # of channels of this canvas' color mode.
    def assert_sample_count!(samples)
      unless samples.length == channels
        raise ArgumentError, "Expected #{channels} samples per pixel for color mode #{color_mode}, got #{samples.length}!"
      end
      true
    end
  end
end
