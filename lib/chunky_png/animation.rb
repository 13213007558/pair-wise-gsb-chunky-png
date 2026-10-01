# frozen-string-literal: true

module ChunkyPNG
  # A ChunkyPNG::Animation represents an animated PNG (APNG) image.
  #
  # It holds the canvas dimensions of the default image and a list of
  # {ChunkyPNG::Frame frames}. Each frame carries its original pixel
  # rectangle plus the metadata from its fcTL chunk: its offset on the
  # canvas, its duration as a numerator/denominator pair and its blend and
  # dispose operations.
  #
  # Use {#frames} to access the raw frame rectangles, or
  # {#composited_frames} to get the full canvas for every frame after
  # applying the APNG blend and dispose rules.
  #
  # @see ChunkyPNG::Frame
  # @see https://wiki.mozilla.org/APNG_Specification
  class Animation
    # @return [Integer] The width of the default image canvas.
    attr_accessor :width

    # @return [Integer] The height of the default image canvas.
    attr_accessor :height

    # @return [Array<ChunkyPNG::Frame>] The frames of this animation.
    attr_accessor :frames

    # @return [Integer] The number of times the animation loops after the
    #   first playthrough; 0 means infinite looping.
    attr_accessor :plays

    # @param [Integer] width The width of the animation canvas.
    # @param [Integer] height The height of the animation canvas.
    # @param [Integer] plays The loop count; 0 means infinite looping.
    def initialize(width = 0, height = 0, plays = 0)
      @width, @height, @plays = width, height, plays
      @frames = []
    end

    # Adds a frame to the animation.
    #
    # @overload add_frame(canvas, options = {})
    #   @param [ChunkyPNG::Canvas] canvas The frame's pixel rectangle.
    #   @param [Hash] options The frame metadata (see
    #     {ChunkyPNG::Frame#initialize}).
    # @overload add_frame(frame)
    #   @param [ChunkyPNG::Frame] frame An existing frame to add.
    # @return [ChunkyPNG::Frame] The frame that was added.
    def add_frame(canvas, options = {})
      frame = canvas.is_a?(Frame) ? canvas : Frame.from_canvas(canvas, options)
      frames << frame
      frame
    end

    alias << add_frame

    # @return [Integer] The number of frames in the animation.
    def frame_count
      frames.length
    end

    # @return [Float] The total duration of one playthrough in seconds.
    def duration
      frames.inject(0.0) { |total, frame| total + frame.duration }
    end

    # Enumerates the raw frame rectangles.
    # @yield [ChunkyPNG::Frame] Yields every frame.
    def each_frame(&block)
      frames.each(&block)
    end

    ###########################################################################
    # LOADING
    ###########################################################################

    class << self
      # Loads an animation from a PNG encoded string.
      # @param str [String] The APNG encoded string.
      # @return [ChunkyPNG::Animation] The decoded animation.
      # @raise [ChunkyPNG::ExpectationFailed] If the string is not an APNG.
      def from_blob(str)
        from_datastream(ChunkyPNG::Datastream.from_blob(str))
      end

      alias from_string from_blob

      # Loads an animation from a PNG encoded file.
      # @param filename [String] The file to load.
      # @return [ChunkyPNG::Animation] The decoded animation.
      def from_file(filename)
        from_datastream(ChunkyPNG::Datastream.from_file(filename))
      end

      # Loads an animation from an IO stream.
      # @param io [IO, #read] The stream to read from.
      # @return [ChunkyPNG::Animation] The decoded animation.
      def from_io(io)
        from_datastream(ChunkyPNG::Datastream.from_io(io))
      end

      alias from_stream from_io

      # Decodes an animation from a {ChunkyPNG::Datastream}.
      # @param ds [ChunkyPNG::Datastream] The datastream to decode.
      # @return [ChunkyPNG::Animation] The decoded animation.
      # @raise [ChunkyPNG::ExpectationFailed] If the datastream has no acTL
      #   chunk and therefore is not an APNG.
      def from_datastream(ds)
        unless ds.animated?
          raise ChunkyPNG::ExpectationFailed, "This PNG datastream does not contain an acTL chunk and is not an animation!"
        end

        animation = new(ds.header_chunk.width, ds.header_chunk.height, ds.animation_chunk.num_plays)
        ds.frame_chunks.each_with_index do |(control, _data_chunks), index|
          animation.frames << decode_frame(ds, control, index)
        end
        animation
      end

      private

      # Decodes a single frame into a ChunkyPNG::Frame.
      # @param ds [ChunkyPNG::Datastream] The datastream being decoded.
      # @param control [ChunkyPNG::Chunk::FrameControl] The frame's fcTL chunk.
      # @param index [Integer] The zero-based frame index.
      # @return [ChunkyPNG::Frame] The decoded frame.
      def decode_frame(ds, control, index)
        color_mode = ds.header_chunk.color
        depth      = ds.header_chunk.depth
        interlace  = ds.header_chunk.interlace

        decoding_palette, transparent_color = nil, nil
        case color_mode
        when ChunkyPNG::COLOR_INDEXED
          decoding_palette = ChunkyPNG::Palette.from_chunks(ds.palette_chunk, ds.transparency_chunk)
        when ChunkyPNG::COLOR_TRUECOLOR
          transparent_color = ds.transparency_chunk.truecolor_entry(depth) if ds.transparency_chunk
        when ChunkyPNG::COLOR_GRAYSCALE
          transparent_color = ds.transparency_chunk.grayscale_entry(depth) if ds.transparency_chunk
        end

        canvas = Canvas.send(
          :decode_png_pixelstream,
          ds.frame_imagedata(index),
          control.width, control.height, color_mode, depth, interlace,
          decoding_palette, transparent_color
        )

        Frame.from_canvas(canvas,
          x_offset: control.x_offset,
          y_offset: control.y_offset,
          delay_num: control.delay_num,
          delay_den: control.delay_den == 0 ? 100 : control.delay_den,
          dispose_op: control.dispose_op,
          blend_op: control.blend_op,
        )
      end
    end

    ###########################################################################
    # COMPOSITING
    ###########################################################################

    # Composites every frame onto a fresh canvas following the APNG blend and
    # dispose rules.
    #
    # The first frame is always rendered with the SOURCE blend operation; a
    # PREVIOUS dispose operation on the first frame is treated as BACKGROUND,
    # per the APNG specification.
    #
    # @return [Array<ChunkyPNG::Canvas>] A full-size canvas for every frame,
    #   showing the frame's visible output.
    def composited_frames
      output = Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)
      saved_region = nil
      result = []

      frames.each_with_index do |frame, index|
        if saved_region
          restore_region(output, saved_region)
          saved_region = nil
        end

        # For the first frame, a PREVIOUS dispose operation is treated as
        # BACKGROUND by the specification, so no region needs to be saved.
        first_frame = index == 0
        dispose = frame.dispose_op
        dispose = ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND if first_frame && dispose == ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS

        # A PREVIOUS frame's region must be reverted to the contents it had
        # right before the frame was rendered, so snapshot it first.
        saved_region = snapshot_region(output, frame) if dispose == ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS

        render_frame(output, frame, first_frame)
        result << Canvas.from_canvas(output)

        case dispose
        when ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND
          clear_region(output, frame)
        end
      end

      result
    end

    # @param index [Integer] The zero-based frame index.
    # @return [ChunkyPNG::Canvas] The full-size canvas showing the frame.
    # @see #composited_frames
    def composited_frame(index)
      composited_frames.fetch(index)
    end

    private

    # Renders a single frame onto the output buffer using its blend
    # operation. The first frame always uses SOURCE blending.
    def render_frame(output, frame, first_frame)
      use_source = first_frame || frame.blend_op == ChunkyPNG::APNG_BLEND_OP_SOURCE
      frame.height.times do |y|
        frame.width.times do |x|
          pixel = frame.get_pixel(x, y)
          target_x = frame.x_offset + x
          target_y = frame.y_offset + y
          pixel = ChunkyPNG::Color.compose(pixel, output.get_pixel(target_x, target_y)) unless use_source
          output.set_pixel(target_x, target_y, pixel)
        end
      end
    end

    # Fills a frame's region with fully transparent black.
    def clear_region(output, frame)
      clear_color = ChunkyPNG::Color::TRANSPARENT
      frame.height.times do |y|
        frame.width.times do |x|
          output.set_pixel(frame.x_offset + x, frame.y_offset + y, clear_color)
        end
      end
    end

    # Captures the pixels of a frame's region as a flat array of pixels.
    # @return [Hash] A description of the captured region.
    def snapshot_region(output, frame)
      pixels = []
      frame.height.times do |y|
        frame.width.times do |x|
          pixels << output.get_pixel(frame.x_offset + x, frame.y_offset + y)
        end
      end
      {x: frame.x_offset, y: frame.y_offset, width: frame.width, height: frame.height, pixels: pixels}
    end

    # Restores a region captured with {#snapshot_region}.
    def restore_region(output, region)
      index = 0
      region[:height].times do |y|
        region[:width].times do |x|
          output.set_pixel(region[:x] + x, region[:y] + y, region[:pixels][index])
          index += 1
        end
      end
    end

    ###########################################################################
    # ENCODING
    ###########################################################################

    public

    # Encodes this animation into an APNG datastream.
    #
    # All frames are encoded using the same color mode and bit depth, which is
    # determined from the first frame unless constraints are given.
    #
    # @param constraints [Hash, Symbol] Encoding constraints as accepted by
    #   {ChunkyPNG::Canvas::PNGEncoding#to_datastream}.
    # @return [ChunkyPNG::Datastream] The encoded datastream.
    def to_datastream(constraints = {})
      raise ChunkyPNG::ExpectationFailed, "Cannot encode an animation without frames!" if frames.empty?

      encoding = determine_animation_encoding(constraints)

      ds = Datastream.new
      ds.header_chunk = Chunk::Header.new(
        width: width,
        height: height,
        color: encoding[:color_mode],
        depth: encoding[:bit_depth],
        interlace: encoding[:interlace]
      )
      ds.animation_chunk = Chunk::AnimationControl.new(frames.length, plays)
      ds.end_chunk = Chunk::End.new

      if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
        ds.palette_chunk      = encoding_palette.to_plte_chunk
        ds.transparency_chunk = encoding_palette.to_trns_chunk unless encoding_palette.opaque?
        assign_shared_palette!
      end

      first_frame = frames.first
      first_frame_is_default = first_frame.x_offset == 0 && first_frame.y_offset == 0 &&
                               first_frame.width == width && first_frame.height == height

      sequence_number = 0

      if first_frame_is_default
        ds.frame_chunks << build_frame_chunks(first_frame, sequence_number, encoding, true)
        # The default image's IDAT chunks do not consume sequence numbers.
        sequence_number += 1
        other_frames = frames[1..-1]
      else
        # The default image is not part of the animation, so it is a fully
        # transparent canvas with the default image's dimensions, as
        # suggested by the APNG specification.
        placeholder = Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)
        placeholder.encoding_palette = encoding_palette if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
        ds.data_chunks = Chunk::ImageData.split_in_chunks(
          placeholder.send(:encode_png_pixelstream,
            encoding[:color_mode], encoding[:bit_depth],
            encoding[:interlace], encoding[:filtering]),
          encoding[:compression]
        )
        other_frames = frames
      end

      other_frames.each do |frame|
        ds.frame_chunks << build_frame_chunks(frame, sequence_number, encoding, false)
        # fcTL and fdAT each consume one sequence number.
        sequence_number += 2
      end

      ds
    end

    # Writes the animation to an IO stream, encoded as APNG.
    # @param io [IO] The stream to write to.
    # @param constraints [Hash, Symbol] Encoding constraints.
    def write(io, constraints = {})
      to_datastream(constraints).write(io)
    end

    # Saves the animation to a file.
    # @param filename [String] The file to save to.
    # @param constraints [Hash, Symbol] Encoding constraints.
    def save(filename, constraints = {})
      File.open(filename, "wb") { |io| write(io, constraints) }
    end

    # Encodes the animation to an APNG formatted string.
    # @param constraints [Hash, Symbol] Encoding constraints.
    # @return [String] The APNG binary string.
    def to_blob(constraints = {})
      to_datastream(constraints).to_blob
    end

    alias to_string to_blob
    alias to_s to_blob

    private

    # Determines the encoding settings shared by every frame, using the first
    # frame's colors as the basis and creating a shared palette that covers all
    # frames when indexed encoding is selected.
    def determine_animation_encoding(constraints)
      first_frame = frames.first
      encoding = first_frame.send(:determine_png_encoding, constraints)

      if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
        # Include fully transparent black for the transparent default image
        # placeholder when the default image is not part of the animation.
        colors = (frames.flat_map(&:pixels) + [ChunkyPNG::Color::TRANSPARENT]).uniq
        @encoding_palette = Palette.from_pixels(colors)
        raise ChunkyPNG::ExpectationFailed, "This animation has too many colors for indexed encoding!" unless encoding_palette.indexable?
        # The first frame may have determined a smaller bit depth based on its
        # own colors; the palette shared by all frames may need a larger one.
        encoding[:bit_depth] = encoding_palette.determine_bit_depth
      end
      encoding
    end

    # Assigns the shared encoding palette to every frame before encoding,
    # so all frames use identical PLTE and tRNS chunks.
    def assign_shared_palette!
      frames.each { |frame| frame.encoding_palette = encoding_palette }
    end

    attr_reader :encoding_palette

    # Encodes one frame and returns its [fcTL, data chunks] pair. For fdAT
    # frames, each data chunk consumes a sequence number following the
    # fcTL chunk's sequence number; the default image's IDAT chunks do not
    # consume sequence numbers.
    def build_frame_chunks(frame, sequence_number, encoding, uses_idat)
      frame.encoding_palette = encoding_palette if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
      stream = frame.send(:encode_png_pixelstream,
        encoding[:color_mode], encoding[:bit_depth],
        encoding[:interlace], encoding[:filtering])
      compressed_parts = Chunk::ImageData.split_in_chunks(stream, encoding[:compression]).map(&:content)

      control = Chunk::FrameControl.new(
        sequence_number: sequence_number,
        width: frame.width,
        height: frame.height,
        x_offset: frame.x_offset,
        y_offset: frame.y_offset,
        delay_num: frame.delay_num,
        delay_den: frame.delay_den,
        dispose_op: frame.dispose_op,
        blend_op: frame.blend_op,
      )

      data_chunks = compressed_parts.each_with_index.map do |compressed, index|
        if uses_idat
          Chunk::ImageData.new("IDAT", compressed)
        else
          Chunk::FrameData.new(sequence_number + 1 + index, compressed)
        end
      end

      [control, data_chunks]
    end
  end
end
