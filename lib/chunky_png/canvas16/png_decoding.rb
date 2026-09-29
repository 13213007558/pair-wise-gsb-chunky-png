# frozen-string-literal: true

module ChunkyPNG
  class Canvas16
    # Methods for decoding PNG datastreams with a bit depth of 16 into a
    # Canvas16, preserving the full 16-bit sample values.
    #
    # The byte-level unfiltering logic is shared with the 8-bit decoding
    # code, because PNG filters always operate on bytes, regardless of the
    # bit depth. Only the scanline-to-pixel decoding differs: samples are
    # kept as 16-bit integers instead of being resampled to 8 bits.
    #
    # @see ChunkyPNG::Canvas::PNGDecoding
    module PNGDecoding
      include ChunkyPNG::Canvas::PNGDecoding

      # Decodes a Canvas16 from a PNG datastream instance.
      #
      # Only non-indexed images with a bit depth of 16 are supported. Use
      # {ChunkyPNG::Canvas.from_datastream} to decode 8-bit images, and
      # {ChunkyPNG::Canvas16.from_canvas} to convert the result to 16 bits
      # explicitly.
      #
      # @param [ChunkyPNG::Datastream] ds The datastream to decode.
      # @return [ChunkyPNG::Canvas16] The canvas decoded from the PNG datastream.
      # @raise [ChunkyPNG::NotSupported] when the image is indexed or does not
      #   use a 16-bit depth.
      def from_datastream(ds)
        width      = ds.header_chunk.width
        height     = ds.header_chunk.height
        color_mode = ds.header_chunk.color
        interlace  = ds.header_chunk.interlace
        depth      = ds.header_chunk.depth

        if width == 0 || height == 0
          raise ExpectationFailed, "Invalid image size, width: #{width}, height: #{height}"
        end

        if color_mode == ChunkyPNG::COLOR_INDEXED
          raise ChunkyPNG::NotSupported, "Indexed images cannot be decoded to a 16-bit canvas!"
        end

        unless depth == 16
          raise ChunkyPNG::NotSupported, "Only 16-bit images can be decoded to a 16-bit canvas, this image has a bit depth of #{depth}!"
        end

        transparent_color = nil
        if ds.transparency_chunk
          case color_mode
            when ChunkyPNG::COLOR_TRUECOLOR then transparent_color = ds.transparency_chunk.content.unpack("nnn")
            when ChunkyPNG::COLOR_GRAYSCALE then transparent_color = ds.transparency_chunk.content.unpack("n")
          end
        end

        decode_png_pixelstream(ds.imagedata, width, height, color_mode, depth, interlace, transparent_color)
      end

      # Decodes a Canvas16 from a PNG encoded pixelstream, using a given
      # width, height, color mode and interlacing mode.
      # @param [String] stream The pixelstream to read from.
      # @param [Integer] width The width of the image.
      # @param [Integer] height The height of the image.
      # @param [Integer] color_mode The color mode of the encoded pixelstream.
      # @param [Integer] depth The bit depth of the pixel samples. Must be 16.
      # @param [Integer] interlace The interlace method of the encoded pixelstream.
      # @param [Array<Integer>, nil] transparent_color The 16-bit sample values
      #   of the color that should be considered fully transparent.
      # @return [ChunkyPNG::Canvas16] The decoded Canvas16 instance.
      def decode_png_pixelstream(stream, width, height, color_mode, depth, interlace, transparent_color = nil)
        image = case interlace
          when ChunkyPNG::INTERLACING_NONE  then decode_png_without_interlacing(stream, width, height, color_mode, depth)
          when ChunkyPNG::INTERLACING_ADAM7 then decode_png_with_adam7_interlacing(stream, width, height, color_mode, depth)
          else raise ChunkyPNG::NotSupported, "Don't know how the handle interlacing method #{interlace}!"
        end

        if transparent_color
          alpha_mode = color_mode == ChunkyPNG::COLOR_GRAYSCALE ? ChunkyPNG::COLOR_GRAYSCALE_ALPHA : ChunkyPNG::COLOR_TRUECOLOR_ALPHA
          pixels = image.pixels.map { |samples| samples == transparent_color ? samples + [0] : samples + [SAMPLE_MAX] }
          image = new(width, height, alpha_mode, pixels)
        end
        image
      end

      protected

      # Decodes a canvas from a non-interlaced PNG encoded pixelstream, using
      # a given width, height and color mode.
      # @return (see ChunkyPNG::Canvas16::PNGDecoding#decode_png_pixelstream)
      def decode_png_without_interlacing(stream, width, height, color_mode, depth)
        decode_png_image_pass(stream, width, height, color_mode, depth, 0)
      end

      # Decodes a canvas from an Adam7 interlaced PNG encoded pixelstream,
      # using a given width, height and color mode.
      # @return (see ChunkyPNG::Canvas16::PNGDecoding#decode_png_pixelstream)
      def decode_png_with_adam7_interlacing(stream, width, height, color_mode, depth)
        canvas = new(width, height, color_mode)
        start_pos = 0
        for pass in 0...7
          sm_width, sm_height = adam7_pass_size(pass, width, height)
          sm = decode_png_image_pass(stream, sm_width, sm_height, color_mode, depth, start_pos)
          adam7_merge_pass(pass, canvas, sm)
          start_pos += ChunkyPNG::Color.pass_bytesize(color_mode, depth, sm_width, sm_height)
        end
        canvas
      end

      # Decodes a single PNG image pass with a given width, height and color
      # mode, to a Canvas16, starting at the given position in the stream.
      # @return (see ChunkyPNG::Canvas16::PNGDecoding#decode_png_pixelstream)
      def decode_png_image_pass(stream, width, height, color_mode, depth, start_pos)
        pixels = []
        if width > 0 && height > 0
          pixel_decoder = decode_png_pixels_from_scanline_method(color_mode, depth)
          line_length   = ChunkyPNG::Color.scanline_bytesize(color_mode, depth, width)
          pixel_size    = ChunkyPNG::Color.pixel_bytesize(color_mode, depth)

          raise ChunkyPNG::ExpectationFailed, "Invalid stream length!" unless stream.bytesize - start_pos >= ChunkyPNG::Color.pass_bytesize(color_mode, depth, width, height)

          pos, prev_pos = start_pos, nil
          for _ in 0...height do
            decode_png_str_scanline(stream, pos, prev_pos, line_length, pixel_size)
            pixels.concat(send(pixel_decoder, stream, pos, width))

            prev_pos = pos
            pos += line_length + 1
          end
        end

        new(width, height, color_mode, pixels)
      end

      # Decodes a scanline of a 16-bit, grayscale image into a row of pixels,
      # preserving the full 16-bit sample values.
      # @param [String] stream The stream to decode from.
      # @param [Integer] pos The position in the stream on which the scanline
      #   starts (including the filter byte).
      # @param [Integer] width The width in pixels of the scanline.
      # @return [Array<Array<Integer>>] An array of decoded pixels, each an
      #   array of 16-bit sample values.
      def decode_png_pixels_from_scanline_grayscale_16bit(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width}").map { |value| [value] }
      end

      # Decodes a scanline of a 16-bit, grayscale image with transparency
      # into a row of pixels, preserving the full 16-bit sample values.
      # @params (see #decode_png_pixels_from_scanline_grayscale_16bit)
      # @return (see #decode_png_pixels_from_scanline_grayscale_16bit)
      def decode_png_pixels_from_scanline_grayscale_alpha_16bit(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width * 2}").each_slice(2).to_a
      end

      # Decodes a scanline of a 16-bit, true color image into a row of
      # pixels, preserving the full 16-bit sample values.
      # @params (see #decode_png_pixels_from_scanline_grayscale_16bit)
      # @return (see #decode_png_pixels_from_scanline_grayscale_16bit)
      def decode_png_pixels_from_scanline_truecolor_16bit(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width * 3}").each_slice(3).to_a
      end

      # Decodes a scanline of a 16-bit, true color image with transparency
      # into a row of pixels, preserving the full 16-bit sample values.
      # @params (see #decode_png_pixels_from_scanline_grayscale_16bit)
      # @return (see #decode_png_pixels_from_scanline_grayscale_16bit)
      def decode_png_pixels_from_scanline_truecolor_alpha_16bit(stream, pos, width)
        stream.unpack("@#{pos + 1}n#{width * 4}").each_slice(4).to_a
      end
    end
  end
end
