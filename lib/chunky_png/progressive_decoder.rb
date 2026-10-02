# frozen-string-literal: true

module ChunkyPNG
  # The ProgressiveDecoder incrementally decodes an Adam7 interlaced PNG
  # image while its data is still being received. This allows consumers,
  # such as preview services, to render a usable image before the complete
  # datastream has been read.
  #
  # The decoder is fed with chunks of (compressed) IDAT data. These chunks
  # can be split at any arbitrary byte position. Internally, the data is
  # inflated and decoded scanline by scanline. Every time an Adam7 pass has
  # been decoded completely, a PassComplete event is produced, containing
  # an independent snapshot of the image decoded so far, together with a
  # mask that indicates which pixels of the snapshot are valid. A pass is
  # only reported as complete after all of its scanlines have been decoded;
  # partially received scanlines are never included. Passes that are empty
  # (which occurs for small images) are completed immediately without
  # requiring any input data.
  #
  # Snapshots are copies: decoding further passes will not modify snapshots
  # that were produced earlier. The snapshot of the final pass is identical
  # to the result of decoding the image in one go.
  #
  # @example
  #   datastream = ChunkyPNG::Datastream.from_file("adam7.png")
  #   decoder = ChunkyPNG::ProgressiveDecoder.from_datastream(datastream)
  #   decoder.on_pass_complete do |event|
  #     render_preview(event.snapshot, event.mask)
  #   end
  #   datastream.data_chunks.each { |chunk| decoder << chunk.content }
  #   decoder.finish
  #
  # @see ChunkyPNG::Canvas::Adam7Interlacing
  class ProgressiveDecoder
    include ChunkyPNG::Canvas::Adam7Interlacing
    include ChunkyPNG::Canvas::PNGDecoding

    # The batch decoding methods mixed in from PNGDecoding are not part of
    # the public API of this decoder.
    private :from_blob, :from_string, :from_file, :from_io, :from_stream,
      :from_datastream, :decode_png_pixelstream

    # Event that gets emitted every time an Adam7 pass has been decoded
    # completely.
    #
    # * +pass+ - The 0-based index of the completed pass (0..6).
    # * +snapshot+ - A ChunkyPNG::Canvas with the dimensions of the
    #   original image, containing all pixels decoded so far. Pixels that
    #   have not been decoded yet are fully transparent. The snapshot is an
    #   independent copy that will not change when decoding continues.
    # * +mask+ - An array of rows (one array of booleans per row), in which
    #   mask[y][x] is +true+ if the pixel at that position has been
    #   decoded and contains a valid value in the snapshot.
    PassComplete = Struct.new(:pass, :snapshot, :mask)

    # @return [Integer] The width of the image being decoded.
    attr_reader :width

    # @return [Integer] The height of the image being decoded.
    attr_reader :height

    # @return [Integer] The color mode of the image being decoded.
    attr_reader :color_mode

    # @return [Integer] The bit depth of the image being decoded.
    attr_reader :depth

    # Builds a progressive decoder from a PNG datastream, using the image
    # header, palette and transparency information of the datastream.
    #
    # @param [ChunkyPNG::Datastream] ds The datastream to take the image
    #   information from.
    # @return [ChunkyPNG::ProgressiveDecoder] The decoder, ready to be fed
    #   with the contents of the datastream's IDAT chunks.
    # @raise [ChunkyPNG::NotSupported] If the image is not Adam7 interlaced.
    def self.from_datastream(ds)
      width      = ds.header_chunk.width
      height     = ds.header_chunk.height
      color_mode = ds.header_chunk.color
      depth      = ds.header_chunk.depth

      unless ds.header_chunk.interlace == ChunkyPNG::INTERLACING_ADAM7
        raise ChunkyPNG::NotSupported, "Progressive decoding is only supported for Adam7 interlaced images!"
      end

      decoding_palette, transparent_color = nil, nil
      case color_mode
        when ChunkyPNG::COLOR_INDEXED
          decoding_palette = ChunkyPNG::Palette.from_chunks(ds.palette_chunk, ds.transparency_chunk)
        when ChunkyPNG::COLOR_TRUECOLOR
          transparent_color = ds.transparency_chunk.truecolor_entry(depth) if ds.transparency_chunk
        when ChunkyPNG::COLOR_GRAYSCALE
          transparent_color = ds.transparency_chunk.grayscale_entry(depth) if ds.transparency_chunk
      end

      new(width, height, color_mode, depth, decoding_palette, transparent_color)
    end

    # Initializes a progressive decoder for an Adam7 interlaced image.
    #
    # @param [Integer] width The width of the image.
    # @param [Integer] height The height of the image.
    # @param [Integer] color_mode The color mode of the encoded pixelstream.
    # @param [Integer] depth The bit depth of the pixel samples.
    # @param [ChunkyPNG::Palette] decoding_palette The palette to use to decode colors.
    # @param [Integer] transparent_color The color that should be considered fully transparent.
    def initialize(width, height, color_mode, depth, decoding_palette = nil, transparent_color = nil)
      if width == 0 || height == 0
        raise ExpectationFailed, "Invalid image size, width: #{width}, height: #{height}"
      end

      raise ChunkyPNG::ExpectationFailed, "This palette is not suitable for decoding!" if decoding_palette && !decoding_palette.can_decode?

      @width             = width
      @height            = height
      @color_mode        = color_mode
      @depth             = depth
      @decoding_palette  = decoding_palette
      @transparent_color = transparent_color

      @inflate = Zlib::Inflate.new
      @stream  = "".b
      @pos     = 0

      @pass     = 0
      @scanline = 0
      @prev_pos = nil
      @finished = false

      @canvas = ChunkyPNG::Canvas.new(width, height)
      @mask   = Array.new(height) { Array.new(width, false) }

      @pixel_decoder = decode_png_pixels_from_scanline_method(color_mode, depth)
      @pixel_size    = ChunkyPNG::Color.pixel_bytesize(color_mode, depth)
    end

    # Registers a callback that gets called with a PassComplete event
    # every time an Adam7 pass has been decoded completely.
    #
    # @yield [event] The block to call when a pass completes.
    # @yieldparam [ChunkyPNG::ProgressiveDecoder::PassComplete] event The
    #   pass completion event.
    # @return [ChunkyPNG::ProgressiveDecoder] Returns itself for chaining.
    def on_pass_complete(&block)
      @on_pass_complete = block
      self
    end

    # Feeds a chunk of compressed IDAT data to the decoder. The data can be
    # chunked at any arbitrary byte position.
    #
    # @param [String] data A chunk of compressed image data.
    # @return [Array<ChunkyPNG::ProgressiveDecoder::PassComplete>] The pass
    #   completion events that were produced while decoding this chunk.
    def <<(data)
      raise ChunkyPNG::ExpectationFailed, "Cannot add data after the stream has finished!" if @finished

      @stream << @inflate.inflate(data)
      decode_available_scanlines
    end

    alias feed <<

    # Finishes the decoding process. This inflates the remainder of the
    # compressed stream and decodes the remaining passes.
    #
    # @return [Array<ChunkyPNG::ProgressiveDecoder::PassComplete>] The pass
    #   completion events that were produced while finishing the stream.
    # @raise [ChunkyPNG::ExpectationFailed] If the stream ended before all
    #   passes were decoded completely.
    def finish
      raise ChunkyPNG::ExpectationFailed, "The stream has already finished!" if @finished

      @stream << @inflate.finish
      @inflate.close
      events = decode_available_scanlines
      raise ChunkyPNG::ExpectationFailed, "Invalid stream length!" unless @pass >= 7

      @finished = true
      events
    end

    # Returns whether the stream has been finished and all passes have been
    # decoded.
    # @return [true, false]
    def finished?
      @finished
    end

    private

    # Decodes all scanlines that can be decoded with the data received so
    # far, completing passes when all of their scanlines have been decoded.
    #
    # @return [Array<ChunkyPNG::ProgressiveDecoder::PassComplete>] The pass
    #   completion events that were produced.
    def decode_available_scanlines
      events = []
      while @pass < 7
        pass_width, pass_height = adam7_pass_size(@pass, @width, @height)
        if pass_width == 0 || pass_height == 0
          # Empty passes do not contain data and complete immediately.
          complete_pass(events)
          next
        end

        line_length = ChunkyPNG::Color.scanline_bytesize(@color_mode, @depth, pass_width)
        break if @stream.bytesize - @pos < line_length + 1

        decode_scanline(pass_width, line_length)
        complete_pass(events) if @scanline == pass_height
      end
      events
    end

    # Decodes a single scanline of the current pass, merges its pixels into
    # the canvas being constructed and updates the mask of valid pixels.
    #
    # @param [Integer] pass_width The width in pixels of the current pass.
    # @param [Integer] line_length The number of bytes in the scanline,
    #   discounting the filter method byte.
    # @return [void]
    def decode_scanline(pass_width, line_length)
      appended_extra_byte = false
      if @color_mode == ChunkyPNG::COLOR_TRUECOLOR && @pos + line_length + 1 == @stream.bytesize
        # The truecolor scanline decoder reads one byte beyond the end of
        # the scanline, so temporarily append a scratch byte if this
        # scanline ends at the end of the data received so far.
        @stream << ChunkyPNG::EXTRA_BYTE
        appended_extra_byte = true
      end

      decode_png_str_scanline(@stream, @pos, @prev_pos, line_length, @pixel_size)
      pixels = send(@pixel_decoder, @stream, @pos, pass_width, @decoding_palette)
      @stream.chop! if appended_extra_byte

      x_shift, x_offset, y_shift, y_offset = adam7_multiplier_offset(@pass)
      y = (@scanline << y_shift) | y_offset
      mask_row = @mask[y]
      pixels.each_with_index do |color, i|
        color = ChunkyPNG::Color::TRANSPARENT if @transparent_color && color == @transparent_color
        x = (i << x_shift) | x_offset
        @canvas[x, y] = color
        mask_row[x] = true
      end

      @prev_pos = @pos
      @pos += line_length + 1
      @scanline += 1
    end

    # Completes the current pass, emitting an event with an independent
    # snapshot and valid pixel mask, and moves on to the next pass.
    #
    # @param [Array<ChunkyPNG::ProgressiveDecoder::PassComplete>] events The
    #   list of events to append the event for this pass to.
    # @return [void]
    def complete_pass(events)
      snapshot = ChunkyPNG::Canvas.new(@width, @height, @canvas.pixels.dup)
      event = PassComplete.new(@pass, snapshot, @mask.map(&:dup))
      events << event
      @on_pass_complete.call(event) if @on_pass_complete

      @pass += 1
      @scanline = 0
      @prev_pos = nil
    end
  end
end
