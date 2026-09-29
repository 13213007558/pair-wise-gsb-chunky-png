# frozen-string-literal: true

module ChunkyPNG
  class Canvas16
    # Methods for encoding a Canvas16 instance into a PNG datastream with a
    # bit depth of 16, preserving the full 16-bit sample values.
    #
    # The byte-level filtering logic is shared with the 8-bit encoding code,
    # because PNG filters always operate on bytes, regardless of the bit
    # depth. Only the pixel-to-scanline encoding differs: samples are packed
    # as 16-bit big endian values instead of single bytes.
    #
    # @see ChunkyPNG::Canvas::PNGEncoding
    module PNGEncoding
      include ChunkyPNG::Canvas::PNGEncoding

      # Converts this Canvas16 to a datastream, so that it can be saved as a
      # PNG image. The image is always encoded with a bit depth of 16, using
      # the color mode of the canvas.
      #
      # @param [Hash, Symbol] constraints The constraints to use when encoding
      #    the canvas. This can either be a hash with different constraints,
      #    or a symbol which acts as a preset for some constraints.
      # @option constraints [true, false] :interlace Whether to use interlacing.
      # @option constraints [Fixnum] :compression The compression level for
      #    Zlib. This can be a value between 0 and 9, or a Zlib constant like
      #    Zlib::BEST_COMPRESSION.
      # @option constraints [Fixnum] :filtering The filtering method to apply
      #    to the scanlines before compression. Use one of the
      #    ChunkyPNG::FILTER_* constants.
      # @return [ChunkyPNG::Datastream] The PNG datastream containing the
      #   encoded canvas.
      def to_datastream(constraints = {})
        encoding = determine_png_encoding(constraints)

        ds = Datastream.new
        ds.header_chunk = Chunk::Header.new(
          width: width,
          height: height,
          color: color_mode,
          depth: 16,
          interlace: encoding[:interlace]
        )

        data           = encode_png_pixelstream(color_mode, 16, encoding[:interlace], encoding[:filtering])
        ds.data_chunks = Chunk::ImageData.split_in_chunks(data, encoding[:compression])
        ds.end_chunk   = Chunk::End.new
        ds
      end

      protected

      # Determines the PNG encoding variables for this 16-bit image. The
      # color mode is determined by the canvas, and the bit depth is always
      # 16, so only compression, interlacing and filtering can be influenced.
      #
      # @param [Hash, Symbol] constraints The constraints for the encoding.
      # @return [Hash] A hash with encoding options.
      def determine_png_encoding(constraints = {})
        encoding = case constraints
          when :best_compression then {compression: Zlib::BEST_COMPRESSION, filtering: ChunkyPNG::FILTER_PAETH}
          when :good_compression then {compression: Zlib::BEST_COMPRESSION, filtering: ChunkyPNG::FILTER_NONE}
          when :no_compression   then {compression: Zlib::NO_COMPRESSION}
          when Hash              then constraints
          else raise ChunkyPNG::Exception, "Unknown encoding preset: #{constraints.inspect}"
        end

        # Use Zlib's default for compression unless otherwise provided.
        encoding[:compression] ||= Zlib::DEFAULT_COMPRESSION

        encoding[:interlace] = case encoding[:interlace]
          when nil, false then ChunkyPNG::INTERLACING_NONE
          when true then ChunkyPNG::INTERLACING_ADAM7
          else encoding[:interlace]
        end

        encoding[:filtering] ||= case encoding[:compression]
          when Zlib::BEST_COMPRESSION then ChunkyPNG::FILTER_PAETH
          when Zlib::NO_COMPRESSION..Zlib::BEST_SPEED then ChunkyPNG::FILTER_NONE
          else ChunkyPNG::FILTER_UP
        end
        encoding
      end

      # Encodes the canvas to a stream, in the canvas' color mode, with a bit
      # depth of 16.
      # @param [String] stream The stream to write to.
      # @param [Integer] color_mode The color mode to use for encoding.
      # @param [Integer] bit_depth The bit depth of the image. Must be 16.
      # @param [Integer] filtering The filtering method to use.
      def encode_png_image_pass_to_stream(stream, color_mode, bit_depth, filtering)
        # Empty passes (possible with Adam7 interlacing) do not get encoded.
        return if width == 0 || height == 0

        start_pos  = stream.bytesize
        pixel_size = Color.pixel_bytesize(color_mode, bit_depth)
        line_width = Color.scanline_bytesize(color_mode, bit_depth, width)

        # Determine the filter method
        encode_method = encode_png_pixels_to_scanline_method(color_mode, bit_depth)
        filter_method = case filtering
          when ChunkyPNG::FILTER_NONE    then nil
          when ChunkyPNG::FILTER_SUB     then :encode_png_str_scanline_sub
          when ChunkyPNG::FILTER_UP      then :encode_png_str_scanline_up
          when ChunkyPNG::FILTER_AVERAGE then :encode_png_str_scanline_average
          when ChunkyPNG::FILTER_PAETH   then :encode_png_str_scanline_paeth
          else raise ArgumentError, "Filtering method #{filtering} is not supported"
        end

        0.upto(height - 1) do |y|
          stream << send(encode_method, row(y))
        end

        # Now, apply filtering if any
        if filter_method
          (height - 1).downto(0) do |y|
            pos = start_pos + y * (line_width + 1)
            prev_pos = y == 0 ? nil : pos - (line_width + 1)
            send(filter_method, stream, pos, prev_pos, line_width, pixel_size)
          end
        end
      end

      # Encodes a line of pixels using 16-bit grayscale mode.
      # @param [Array<Array<Integer>>] pixels A row of pixels of the original
      #   image, each an array of 16-bit sample values.
      # @return [String] The encoded scanline as binary string.
      def encode_png_pixels_to_scanline_grayscale_16bit(pixels)
        pixels.flatten.pack("xn#{width}")
      end

      # Encodes a line of pixels using 16-bit grayscale alpha mode.
      # @param [Array<Array<Integer>>] pixels A row of pixels of the original
      #   image, each an array of 16-bit sample values.
      # @return [String] The encoded scanline as binary string.
      def encode_png_pixels_to_scanline_grayscale_alpha_16bit(pixels)
        pixels.flatten.pack("xn#{width * 2}")
      end

      # Encodes a line of pixels using 16-bit truecolor mode.
      # @param [Array<Array<Integer>>] pixels A row of pixels of the original
      #   image, each an array of 16-bit sample values.
      # @return [String] The encoded scanline as binary string.
      def encode_png_pixels_to_scanline_truecolor_16bit(pixels)
        pixels.flatten.pack("xn#{width * 3}")
      end

      # Encodes a line of pixels using 16-bit truecolor alpha mode.
      # @param [Array<Array<Integer>>] pixels A row of pixels of the original
      #   image, each an array of 16-bit sample values.
      # @return [String] The encoded scanline as binary string.
      def encode_png_pixels_to_scanline_truecolor_alpha_16bit(pixels)
        pixels.flatten.pack("xn#{width * 4}")
      end
    end

    # Extracts an Adam7 pass from a complete 16-bit image.
    # @param [Integer] pass The pass number, should be in 0..6.
    # @param [ChunkyPNG::Canvas16] canvas The image that is being deconstructed.
    # @return [ChunkyPNG::Canvas16] The extracted pass image.
    def self.adam7_extract_pass(pass, canvas)
      x_shift, x_offset, y_shift, y_offset = adam7_multiplier_offset(pass)
      sm_pixels = []

      y_offset.step(canvas.height - 1, 1 << y_shift) do |y|
        x_offset.step(canvas.width - 1, 1 << x_shift) do |x|
          sm_pixels << canvas[x, y]
        end
      end

      new(*adam7_pass_size(pass, canvas.width, canvas.height), canvas.color_mode, sm_pixels)
    end
  end
end
