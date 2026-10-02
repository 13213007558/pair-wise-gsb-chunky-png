# frozen-string-literal: true

require "chunky_png/color16"

module ChunkyPNG
  class Canvas16 < Canvas
    module PNGDecoding16
      def from_blob(str)
        from_datastream(ChunkyPNG::Datastream.from_blob(str))
      end

      alias from_string from_blob

      def from_file(filename)
        from_datastream(ChunkyPNG::Datastream.from_file(filename))
      end

      def from_io(io)
        from_datastream(ChunkyPNG::Datastream.from_io(io))
      end

      alias from_stream from_io

      def from_datastream(ds)
        width = ds.header_chunk.width
        height = ds.header_chunk.height
        color_mode = ds.header_chunk.color
        interlace = ds.header_chunk.interlace
        depth = ds.header_chunk.depth

        raise ExpectationFailed, "Invalid image size, width: #{width}, height: #{height}" if width == 0 || height == 0
        unless supported_color_mode?(color_mode) && supported_depth?(depth)
          raise NotSupported,
            "Canvas16 supports direct grayscale, grayscale alpha, RGB and RGBA images at 8 or 16 bits per sample!"
        end

        transparent_color = transparent_color_from_chunk(ds, color_mode, depth)
        decode_png_pixelstream(ds.imagedata, width, height, color_mode, depth, interlace, transparent_color)
      end

      def from_8bit_canvas(canvas)
        new(canvas.width, canvas.height, canvas.pixels.map { |color| Color16.from_color(color) })
      end

      alias from_canvas8 from_8bit_canvas

      protected

      def supported_color_mode?(color_mode)
        [COLOR_GRAYSCALE, COLOR_GRAYSCALE_ALPHA, COLOR_TRUECOLOR, COLOR_TRUECOLOR_ALPHA].include?(color_mode)
      end

      def supported_depth?(depth)
        depth == 8 || depth == 16
      end

      def transparent_color_from_chunk(ds, color_mode, depth)
        return nil unless ds.transparency_chunk
        expand = depth == 8

        case color_mode
          when COLOR_TRUECOLOR
            values = ds.transparency_chunk.content.unpack("nnn")
            values.map! { |value| expand ? Color16.from_8bit(value) : value }
            Color16.rgb(*values)
          when COLOR_GRAYSCALE
            value = ds.transparency_chunk.content.unpack("n").first
            Color16.grayscale(expand ? Color16.from_8bit(value) : value)
        end
      end

      def decode_png_pixelstream(stream, width, height, color_mode, depth, interlace, transparent_color)
        image = case interlace
          when INTERLACING_NONE then decode_png_without_interlacing(stream, width, height, color_mode, depth)
          when INTERLACING_ADAM7 then decode_png_with_adam7_interlacing(stream, width, height, color_mode, depth)
          else raise NotSupported, "Don't know how to handle interlacing method #{interlace}!"
        end

        image.pixels.map! { |color| color == transparent_color ? Color16::TRANSPARENT : color } if transparent_color
        image
      end

      def decode_png_without_interlacing(stream, width, height, color_mode, depth)
        decode_png_image_pass(stream, width, height, color_mode, depth, 0)
      end

      def decode_png_with_adam7_interlacing(stream, width, height, color_mode, depth)
        canvas = new(width, height)
        start_pos = 0

        0.upto(6) do |pass|
          pass_width, pass_height = adam7_pass_size(pass, width, height)
          next if pass_width.zero? || pass_height.zero?

          subcanvas = decode_png_image_pass(stream, pass_width, pass_height, color_mode, depth, start_pos)
          adam7_merge_pass(pass, canvas, subcanvas)
          start_pos += Color.pass_bytesize(color_mode, depth, pass_width, pass_height)
        end

        canvas
      end

      def decode_png_image_pass(stream, width, height, color_mode, depth, start_pos)
        pixels = []

        if width > 0 && height > 0
          pixel_decoder = decode_png_pixels_from_scanline_method(color_mode, depth)
          line_length = Color.scanline_bytesize(color_mode, depth, width)
          pixel_size = Color.pixel_bytesize(color_mode, depth)
          pass_size = Color.pass_bytesize(color_mode, depth, width, height)

          unless stream.bytesize - start_pos >= pass_size
            raise ExpectationFailed, "Invalid stream length!"
          end

          pos = start_pos
          previous_pos = nil
          height.times do
            decode_png_str_scanline(stream, pos, previous_pos, line_length, pixel_size)
            pixels.concat(send(pixel_decoder, stream, pos, width))
            previous_pos = pos
            pos += line_length + 1
          end
        end

        new(width, height, pixels)
      end

      def decode_png_pixels_from_scanline_method(color_mode, depth)
        case [color_mode, depth]
          when [COLOR_TRUECOLOR_ALPHA, 16] then :decode_rgba_16bit_scanline
          when [COLOR_TRUECOLOR, 16]       then :decode_rgb_16bit_scanline
          when [COLOR_GRAYSCALE_ALPHA, 16] then :decode_grayscale_alpha_16bit_scanline
          when [COLOR_GRAYSCALE, 16]       then :decode_grayscale_16bit_scanline
          when [COLOR_TRUECOLOR_ALPHA, 8]  then :decode_rgba_8bit_scanline
          when [COLOR_TRUECOLOR, 8]        then :decode_rgb_8bit_scanline
          when [COLOR_GRAYSCALE_ALPHA, 8] then :decode_grayscale_alpha_8bit_scanline
          when [COLOR_GRAYSCALE, 8]       then :decode_grayscale_8bit_scanline
        end
      end

      def decode_16bit_samples(stream, pos, count)
        stream.unpack("@#{pos + 1}n#{count}")
      end

      def decode_8bit_samples(stream, pos, count)
        stream.unpack("@#{pos + 1}C#{count}").map { |sample| Color16.from_8bit(sample) }
      end

      def decode_rgba_16bit_scanline(stream, pos, width)
        decode_16bit_samples(stream, pos, width * 4).each_slice(4).map { |r, g, b, a| Color16.rgba(r, g, b, a) }
      end

      def decode_rgb_16bit_scanline(stream, pos, width)
        decode_16bit_samples(stream, pos, width * 3).each_slice(3).map { |r, g, b| Color16.rgb(r, g, b) }
      end

      def decode_grayscale_alpha_16bit_scanline(stream, pos, width)
        decode_16bit_samples(stream, pos, width * 2).each_slice(2).map { |g, a| Color16.grayscale_alpha(g, a) }
      end

      def decode_grayscale_16bit_scanline(stream, pos, width)
        decode_16bit_samples(stream, pos, width).map { |g| Color16.grayscale(g) }
      end

      def decode_rgba_8bit_scanline(stream, pos, width)
        decode_8bit_samples(stream, pos, width * 4).each_slice(4).map { |r, g, b, a| Color16.rgba(r, g, b, a) }
      end

      def decode_rgb_8bit_scanline(stream, pos, width)
        decode_8bit_samples(stream, pos, width * 3).each_slice(3).map { |r, g, b| Color16.rgb(r, g, b) }
      end

      def decode_grayscale_alpha_8bit_scanline(stream, pos, width)
        decode_8bit_samples(stream, pos, width * 2).each_slice(2).map { |g, a| Color16.grayscale_alpha(g, a) }
      end

      def decode_grayscale_8bit_scanline(stream, pos, width)
        decode_8bit_samples(stream, pos, width).map { |g| Color16.grayscale(g) }
      end
    end

    module PNGEncoding16
      def to_datastream(constraints = {})
        encoding = determine_png_encoding(constraints)

        ds = Datastream.new
        ds.header_chunk = Chunk::Header.new(
          width: width,
          height: height,
          color: encoding[:color_mode],
          depth: encoding[:bit_depth],
          interlace: encoding[:interlace]
        )

        data = encode_png_pixelstream(
          encoding[:color_mode],
          encoding[:bit_depth],
          encoding[:interlace],
          encoding[:filtering]
        )
        ds.data_chunks = Chunk::ImageData.split_in_chunks(data, encoding[:compression])
        ds.end_chunk = Chunk::End.new
        ds
      end

      protected

      def determine_png_encoding(constraints)
        encoding = case constraints
          when :fast_rgb then {color_mode: COLOR_TRUECOLOR, compression: Zlib::BEST_SPEED}
          when :fast_rgba then {color_mode: COLOR_TRUECOLOR_ALPHA, compression: Zlib::BEST_SPEED}
          when :best_compression then {compression: Zlib::BEST_COMPRESSION, filtering: FILTER_PAETH}
          when :good_compression then {compression: Zlib::BEST_COMPRESSION, filtering: FILTER_NONE}
          when :no_compression then {compression: Zlib::NO_COMPRESSION}
          when Hash then constraints.dup
          else raise ChunkyPNG::Exception, "Unknown encoding preset: #{constraints.inspect}"
        end

        unless encoding[:color_mode]
          grayscale = pixels.all? do |pixel_color|
            Color16.r(pixel_color) == Color16.g(pixel_color) &&
              Color16.g(pixel_color) == Color16.b(pixel_color)
          end
          opaque = pixels.all? { |color| Color16.a(color) == Color16::MAX }
          encoding[:color_mode] = if grayscale
            opaque ? COLOR_GRAYSCALE : COLOR_GRAYSCALE_ALPHA
          else
            opaque ? COLOR_TRUECOLOR : COLOR_TRUECOLOR_ALPHA
          end
        end

        if encoding[:color_mode] == COLOR_INDEXED
          raise NotSupported, "Canvas16 cannot encode indexed PNG images!"
        end

        encoding[:bit_depth] ||= 16
        unless encoding[:bit_depth] == 8 || encoding[:bit_depth] == 16
          raise NotSupported, "Canvas16 can only encode PNG images at 8 or 16 bits per sample!"
        end

        encoding[:compression] ||= Zlib::DEFAULT_COMPRESSION
        encoding[:interlace] = case encoding[:interlace]
          when nil, false then INTERLACING_NONE
          when true then INTERLACING_ADAM7
          else encoding[:interlace]
        end

        encoding[:filtering] ||= case encoding[:compression]
          when Zlib::BEST_COMPRESSION then FILTER_PAETH
          when Zlib::NO_COMPRESSION..Zlib::BEST_SPEED then FILTER_NONE
          else FILTER_UP
        end
        encoding
      end

      def encode_png_pixelstream(color_mode, bit_depth, interlace, filtering)
        case interlace
          when INTERLACING_NONE then encode_png_image_without_interlacing(color_mode, bit_depth, filtering)
          when INTERLACING_ADAM7 then encode_png_image_with_interlacing(color_mode, bit_depth, filtering)
          else raise NotSupported, "Unknown interlacing method: #{interlace}!"
        end
      end

      def encode_png_image_without_interlacing(color_mode, bit_depth, filtering)
        stream = "".b
        encode_png_image_pass_to_stream(stream, color_mode, bit_depth, filtering)
        stream
      end

      def encode_png_image_with_interlacing(color_mode, bit_depth, filtering)
        stream = "".b
        0.upto(6) do |pass|
          subcanvas = self.class.adam7_extract_pass(pass, self)
          next if subcanvas.width.zero? || subcanvas.height.zero?
          subcanvas.encode_png_image_pass_to_stream(stream, color_mode, bit_depth, filtering)
        end
        stream
      end

      def encode_png_image_pass_to_stream(stream, color_mode, bit_depth, filtering)
        start_pos = stream.bytesize
        pixel_size = Color.pixel_bytesize(color_mode, bit_depth)
        line_width = Color.scanline_bytesize(color_mode, bit_depth, width)
        encode_method = encode_png_pixels_to_scanline_method(color_mode, bit_depth)

        filter_method = case filtering
          when FILTER_NONE then nil
          when FILTER_SUB then :encode_png_str_scanline_sub
          when FILTER_UP then :encode_png_str_scanline_up
          when FILTER_AVERAGE then :encode_png_str_scanline_average
          when FILTER_PAETH then :encode_png_str_scanline_paeth
          else raise ArgumentError, "Filtering method #{filtering} is not supported"
        end

        height.times { |y| stream << send(encode_method, row(y)) }

        if filter_method
          (height - 1).downto(0) do |y|
            pos = start_pos + y * (line_width + 1)
            previous_pos = y.zero? ? nil : pos - (line_width + 1)
            send(filter_method, stream, pos, previous_pos, line_width, pixel_size)
          end
        end
      end

      def encode_png_pixels_to_scanline_method(color_mode, depth)
        case [color_mode, depth]
          when [COLOR_TRUECOLOR_ALPHA, 16] then :encode_rgba_16bit_scanline
          when [COLOR_TRUECOLOR, 16]       then :encode_rgb_16bit_scanline
          when [COLOR_GRAYSCALE_ALPHA, 16] then :encode_grayscale_alpha_16bit_scanline
          when [COLOR_GRAYSCALE, 16]       then :encode_grayscale_16bit_scanline
          when [COLOR_TRUECOLOR_ALPHA, 8]  then :encode_rgba_8bit_scanline
          when [COLOR_TRUECOLOR, 8]        then :encode_rgb_8bit_scanline
          when [COLOR_GRAYSCALE_ALPHA, 8] then :encode_grayscale_alpha_8bit_scanline
          when [COLOR_GRAYSCALE, 8]       then :encode_grayscale_8bit_scanline
        end
      end

      def encode_16bit_scanline(pixels, sample_count)
        samples = Array.new(pixels.length * sample_count)
        index = 0
        pixels.each do |color|
          values = if sample_count == 4
            [Color16.r(color), Color16.g(color), Color16.b(color), Color16.a(color)]
          else
            [Color16.r(color), Color16.g(color), Color16.b(color)]
          end
          values.each_with_index { |sample, sample_index| samples[index + sample_index] = sample }
          index += sample_count
        end
        samples.pack("xn#{samples.length}")
      end

      def encode_8bit_scanline(pixels, sample_count)
        samples = Array.new(pixels.length * sample_count)
        index = 0
        pixels.each do |color|
          values = if sample_count == 4
            [Color16.r(color), Color16.g(color), Color16.b(color), Color16.a(color)]
          else
            [Color16.r(color), Color16.g(color), Color16.b(color)]
          end
          values.each_with_index { |sample, sample_index| samples[index + sample_index] = Color16.to_8bit(sample) }
          index += sample_count
        end
        samples.pack("xC#{samples.length}")
      end

      def encode_rgba_16bit_scanline(pixels)
        encode_16bit_scanline(pixels, 4)
      end

      def encode_rgb_16bit_scanline(pixels)
        encode_16bit_scanline(pixels, 3)
      end

      def encode_grayscale_alpha_16bit_scanline(pixels)
        samples = pixels.flat_map { |color| [Color16.r(color), Color16.a(color)] }
        samples.pack("xn#{samples.length}")
      end

      def encode_grayscale_16bit_scanline(pixels)
        samples = pixels.map { |color| Color16.r(color) }
        samples.pack("xn#{samples.length}")
      end

      def encode_rgba_8bit_scanline(pixels)
        encode_8bit_scanline(pixels, 4)
      end

      def encode_rgb_8bit_scanline(pixels)
        encode_8bit_scanline(pixels, 3)
      end

      def encode_grayscale_alpha_8bit_scanline(pixels)
        samples = pixels.flat_map do |color|
          [Color16.to_8bit(Color16.r(color)), Color16.to_8bit(Color16.a(color))]
        end
        samples.pack("xC#{samples.length}")
      end

      def encode_grayscale_8bit_scanline(pixels)
        samples = pixels.map { |color| Color16.to_8bit(Color16.r(color)) }
        samples.pack("xC#{samples.length}")
      end
    end

    include PNGEncoding16
    extend PNGDecoding16

    def initialize(width, height, initial = Color16::TRANSPARENT)
      if initial.is_a?(Array)
        super(width, height, initial)
      else
        super(width, height, Color16.parse(initial))
      end
    end

    def []=(x, y, color)
      assert_xy!(x, y)
      @pixels[y * width + x] = Color16.parse(color)
    end

    def self.adam7_extract_pass(pass, canvas)
      x_shift, x_offset, y_shift, y_offset = adam7_multiplier_offset(pass)
      pixels = []

      y_offset.step(canvas.height - 1, 1 << y_shift) do |y|
        x_offset.step(canvas.width - 1, 1 << x_shift) do |x|
          pixels << canvas[x, y]
        end
      end

      new(*adam7_pass_size(pass, canvas.width, canvas.height), pixels)
    end

    def self.from_canvas(canvas)
      return new(canvas.width, canvas.height, canvas.pixels.dup) if canvas.is_a?(Canvas16)
      from_8bit_canvas(canvas)
    end

    def to_8bit_canvas
      Canvas.new(width, height, pixels.map { |color| Color16.to_color(color) })
    end

    def to_16bit_canvas
      Canvas16.from_canvas(self)
    end

    alias to_canvas8 to_8bit_canvas
    alias to_canvas16 to_16bit_canvas
  end

  # Metadata-enabled counterpart of {ChunkyPNG::Image} for 16-bit canvases.
  class Image16 < Canvas16
    attr_accessor :metadata

    def initialize(width, height, background_color = Color16::TRANSPARENT, metadata = {})
      super(width, height, background_color)
      @metadata = metadata
    end

    def initialize_copy(other)
      super(other)
      @metadata = other.metadata.dup
    end

    def to_datastream(constraints = {})
      datastream = super(constraints)
      datastream.other_chunks += metadata_chunks
      datastream
    end

    def self.from_datastream(datastream)
      image = super(datastream)
      image.metadata = datastream.metadata
      image
    end

    private

    def metadata_chunks
      metadata.map do |key, value|
        if value.length >= Image::METADATA_COMPRESSION_TRESHOLD
          Chunk::CompressedText.new(key, value)
        else
          Chunk::Text.new(key, value)
        end
      end
    end
  end

  class Canvas
    # Creates a 16-bit canvas by bit-replicating every 8-bit sample.
    def to_16bit_canvas
      Canvas16.from_8bit_canvas(self)
    end

    alias to_canvas16 to_16bit_canvas
  end
end
