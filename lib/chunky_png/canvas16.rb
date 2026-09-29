# frozen_string_literal: true

module ChunkyPNG
  # A canvas that stores each pixel as a 64-bit RGBA value with 16 bits per
  # channel. Use {#to_canvas} to create a normal 8-bit {ChunkyPNG::Canvas}.
  class Canvas16 < Canvas
    def initialize(width, height, initial = Color16::TRANSPARENT)
      unless initial.is_a?(Array) || initial.is_a?(Integer)
        raise ArgumentError, "Don't know how to create a 16-bit color from #{initial.inspect}!"
      end
      super
    end

    def self.from_canvas(canvas)
      pixels = canvas.pixels.map { |pixel| Color16.from_color(pixel) }
      new(canvas.width, canvas.height, pixels)
    end

    def to_canvas(rounding: :truncate)
      pixels = @pixels.map { |pixel| Color16.to_color(pixel, rounding) }
      Canvas.new(width, height, pixels)
    end

    def to_image
      Image16.from_canvas(self)
    end

    def inspect
      inspected = +"<#{self.class.name} #{width}x#{height} ["
      0.upto(height - 1) do |y|
        inspected << "\n\t[" << row(y).map { |pixel| Color16.to_hex(pixel) }.join(" ") << "]"
      end
      inspected << "\n]>"
    end

    protected

    def adam7_new_pass_canvas(*args)
      self.class.new(*args)
    end

    def determine_png_encoding(constraints = {})
      normalized = case constraints
      when :fast_rgb
        {color_mode: ChunkyPNG::COLOR_TRUECOLOR, compression: Zlib::BEST_SPEED}
      when :fast_rgba
        {color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA, compression: Zlib::BEST_SPEED}
      when :best_compression
        {compression: Zlib::BEST_COMPRESSION, filtering: ChunkyPNG::FILTER_PAETH}
      when :good_compression
        {compression: Zlib::BEST_COMPRESSION, filtering: ChunkyPNG::FILTER_NONE}
      when :no_compression
        {compression: Zlib::NO_COMPRESSION}
      when :black_and_white
        raise ChunkyPNG::NotSupported, "16-bit canvases cannot encode indexed or sub-byte images!"
      else
        constraints
      end

      normalized = normalized.dup
      normalized[:color_mode] ||= default_color_mode
      if normalized[:bit_depth] && normalized[:bit_depth] != 16
        raise ChunkyPNG::NotSupported, "16-bit canvases can only be encoded with a 16-bit bit depth!"
      end
      normalized[:bit_depth] = 16

      encoding = super(normalized)
      if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
        raise ChunkyPNG::NotSupported, "16-bit canvases cannot encode indexed images!"
      end
      encoding[:bit_depth] = 16
      encoding
    end

    def default_color_mode
      grayscale = pixels.all? { |pixel| Color16.r(pixel) == Color16.g(pixel) && Color16.g(pixel) == Color16.b(pixel) }
      opaque = pixels.all? { |pixel| Color16.a(pixel) == Color16::MAX }

      if grayscale
        opaque ? ChunkyPNG::COLOR_GRAYSCALE : ChunkyPNG::COLOR_GRAYSCALE_ALPHA
      else
        opaque ? ChunkyPNG::COLOR_TRUECOLOR : ChunkyPNG::COLOR_TRUECOLOR_ALPHA
      end
    end

    def encode_png_pixels_to_scanline_method(color_mode, depth)
      raise ChunkyPNG::NotSupported, "Expected a 16-bit image!" unless depth == 16
      super
    end

    def encode_png_pixels_to_scanline_grayscale_16bit(pixels)
      pixels.map { |pixel| Color16.r(pixel) }.pack("xn#{width}")
    end

    def encode_png_pixels_to_scanline_grayscale_alpha_16bit(pixels)
      values = pixels.flat_map { |pixel| Color16.to_grayscale_alpha_bytes(pixel) }
      values.pack("xn#{width * 2}")
    end

    def encode_png_pixels_to_scanline_truecolor_16bit(pixels)
      values = pixels.flat_map { |pixel| Color16.to_truecolor_bytes(pixel) }
      values.pack("xn#{width * 3}")
    end

    def encode_png_pixels_to_scanline_truecolor_alpha_16bit(pixels)
      values = pixels.flat_map { |pixel| Color16.to_truecolor_alpha_bytes(pixel) }
      values.pack("xn#{width * 4}")
    end

    class << self
      def from_datastream(ds)
        depth = ds.header_chunk.depth
        color_mode = ds.header_chunk.color
        supported_color_modes = [
          ChunkyPNG::COLOR_GRAYSCALE,
          ChunkyPNG::COLOR_TRUECOLOR,
          ChunkyPNG::COLOR_GRAYSCALE_ALPHA,
          ChunkyPNG::COLOR_TRUECOLOR_ALPHA,
        ]
        unless depth == 16 && supported_color_modes.include?(color_mode)
          raise ChunkyPNG::NotSupported, "Canvas16 only reads direct 16-bit PNG images!"
        end
        super
      end

      protected

      def adam7_new_pass_canvas(*args)
        new(*args)
      end

      def transparent_pixel_color
        Color16::TRANSPARENT
      end

      def transparent_color_from_chunk(ds, color_mode, depth)
        return unless ds.transparency_chunk

        values = ds.transparency_chunk.content.unpack("n*")
        case color_mode
        when ChunkyPNG::COLOR_GRAYSCALE
          Color16.grayscale(values.first)
        when ChunkyPNG::COLOR_TRUECOLOR
          Color16.rgb(*values)
        end
      end

      def append_truecolor_decoding_byte(_stream, _color_mode)
      end

      def decode_png_pixels_from_scanline_method(color_mode, depth)
        raise ChunkyPNG::NotSupported, "Expected a 16-bit image!" unless depth == 16
        super
      end

      def decode_png_pixels_from_scanline_grayscale_16bit(stream, pos, width, _decoding_palette)
        stream.unpack("@#{pos + 1}n#{width}").map { |value| Color16.grayscale(value) }
      end

      def decode_png_pixels_from_scanline_grayscale_alpha_16bit(stream, pos, width, _decoding_palette)
        stream.unpack("@#{pos + 1}n#{width * 2}").each_slice(2).map do |value, alpha|
          Color16.grayscale_alpha(value, alpha)
        end
      end

      def decode_png_pixels_from_scanline_truecolor_16bit(stream, pos, width, _decoding_palette)
        stream.unpack("@#{pos + 1}n#{width * 3}").each_slice(3).map do |r, g, b|
          Color16.rgb(r, g, b)
        end
      end

      def decode_png_pixels_from_scanline_truecolor_alpha_16bit(stream, pos, width, _decoding_palette)
        stream.unpack("@#{pos + 1}n#{width * 4}").each_slice(4).map do |r, g, b, a|
          Color16.rgba(r, g, b, a)
        end
      end
    end
  end
end
