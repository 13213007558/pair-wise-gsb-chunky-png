# frozen-string-literal: true

module ChunkyPNG
  # A Frame describes one frame of an {ChunkyPNG::Animation} (APNG).
  #
  # It combines the frame's canvas - i.e. the raw, undecorated rectangular
  # pixel data as it was stored in the file - with its placement inside the
  # default image's viewport, its display duration and the blend and
  # dispose operations that describe how the frame is rendered.
  #
  # @see ChunkyPNG::Animation
  class Frame
    # @return [ChunkyPNG::Canvas] The frame's raw rectangular pixel data.
    attr_accessor :canvas

    # @return [Integer] The x-position of the frame within the viewport.
    attr_accessor :x_offset

    # @return [Integer] The y-position of the frame within the viewport.
    attr_accessor :y_offset

    # @return [Integer] The numerator of the frame duration, in seconds.
    attr_accessor :delay_num

    # @return [Integer] The denominator of the frame duration, in seconds.
    attr_accessor :delay_den

    # @return [Integer] The dispose operation (one of the
    #   ChunkyPNG::DISPOSE_OP_* constants).
    attr_accessor :dispose_op

    # @return [Integer] The blend operation (one of the
    #   ChunkyPNG::BLEND_OP_* constants).
    attr_accessor :blend_op

    # @param [ChunkyPNG::Canvas] canvas The frame's raw rectangular canvas.
    # @param [Hash] options The frame's metadata.
    # @option options [Integer] :x_offset (0)
    # @option options [Integer] :y_offset (0)
    # @option options [Integer, Rational] :delay (1/10) The duration of the
    #   frame in seconds. Integers are interpreted as a delay in
    #   hundredths of a second (as in animated GIF); Rationals preserve the
    #   exact numerator and denominator.
    # @option options [Integer] :delay_num (1)
    # @option options [Integer] :delay_den (100)
    # @option options [Integer] :dispose_op (ChunkyPNG::DISPOSE_OP_NONE)
    # @option options [Integer] :blend_op (ChunkyPNG::BLEND_OP_SOURCE)
    def initialize(canvas, options = {})
      @canvas     = canvas
      @x_offset   = options.fetch(:x_offset, 0)
      @y_offset   = options.fetch(:y_offset, 0)
      @dispose_op = options.fetch(:dispose_op, ChunkyPNG::DISPOSE_OP_NONE)
      @blend_op   = options.fetch(:blend_op, ChunkyPNG::BLEND_OP_SOURCE)

      if options.key?(:delay)
        delay = options[:delay]
        if delay.is_a?(Rational)
          @delay_num = delay.numerator
          @delay_den = delay.denominator
        else
          @delay_num = (delay * 100).round
          @delay_den = 100
        end
      else
        @delay_num = options.fetch(:delay_num, 1)
        @delay_den = options.fetch(:delay_den, 100)
      end
    end

    # @return [Integer] The width of the frame's raw rectangle.
    def width
      canvas.width
    end

    # @return [Integer] The height of the frame's raw rectangle.
    def height
      canvas.height
    end

    # Returns the frame duration as a Rational, in seconds.
    # A denominator of 0 is treated as 100, per the APNG specification.
    # @return [Rational]
    def delay
      denominator = delay_den.to_i.zero? ? 100 : delay_den
      Rational(delay_num, denominator)
    end

    # Builds a frame control chunk for this frame.
    # @param [Integer] sequence_number The sequence number to assign.
    # @return [ChunkyPNG::Chunk::FrameControl]
    def to_frame_control_chunk(sequence_number)
      ChunkyPNG::Chunk::FrameControl.new(
        sequence_number: sequence_number,
        width: width,
        height: height,
        x_offset: x_offset,
        y_offset: y_offset,
        delay_num: delay_num,
        delay_den: delay_den,
        dispose_op: dispose_op,
        blend_op: blend_op
      )
    end

    # Builds a Frame from a decoded canvas and an fcTL chunk.
    # @param [ChunkyPNG::Canvas] canvas The decoded raw rectangle.
    # @param [ChunkyPNG::Chunk::FrameControl] control_chunk The chunk.
    # @return [ChunkyPNG::Frame]
    def self.from_canvas_and_control_chunk(canvas, control_chunk)
      new(
        canvas,
        x_offset: control_chunk.x_offset,
        y_offset: control_chunk.y_offset,
        delay_num: control_chunk.delay_num,
        delay_den: control_chunk.delay_den,
        dispose_op: control_chunk.dispose_op,
        blend_op: control_chunk.blend_op
      )
    end
  end

  # An Animation represents an animated PNG (APNG).
  #
  # An animation has the dimensions of the default image's viewport and
  # contains an ordered list of {ChunkyPNG::Frame frames}. Every frame
  # exposes its raw rectangular canvas as stored in the file, and the
  # animation can render each frame to the full canvas following the
  # frames' blend and dispose operations.
  #
  # @see ChunkyPNG::Frame
  # @see https://wiki.mozilla.org/APNG_Specification
  class Animation
    # @return [Integer] The width of the animation's viewport.
    attr_accessor :width

    # @return [Integer] The height of the animation's viewport.
    attr_accessor :height

    # @return [Array<ChunkyPNG::Frame>] The animation's frames, in order.
    attr_accessor :frames

    # @return [Integer] The number of times the animation should loop. A
    #   value of 0 means it should repeat indefinitely.
    attr_accessor :plays

    # Initializes a new, empty animation.
    # @param [Integer] width The viewport width.
    # @param [Integer] height The viewport height.
    # @param [Hash] options
    # @option options [Integer] :plays (0) The number of loops.
    def initialize(width, height, options = {})
      @width  = width
      @height = height
      @plays  = options.fetch(:plays, 0)
      @frames = []
    end

    # Adds a frame to the animation.
    # @param (see Frame#initialize)
    # @return [ChunkyPNG::Frame] The frame that was added.
    def add_frame(canvas, options = {})
      frame = canvas.is_a?(Frame) ? canvas : Frame.new(canvas, options)
      frames << frame
      frame
    end

    alias << add_frame

    # @return [Integer] The number of frames in the animation.
    def frame_count
      frames.length
    end

    alias length frame_count
    alias size frame_count

    # @return [Boolean] Whether the animation contains no frames.
    def empty?
      frames.empty?
    end

    # Yields the raw rectangular canvas of every frame, in order.
    # @yield [canvas] Yields each frame's raw canvas.
    # @return [Enumerator, self]
    def each_frame
      return enum_for(:each_frame) unless block_given?
      frames.each { |frame| yield(frame.canvas) }
      self
    end

    # Returns the raw rectangular canvas of a frame, exactly as stored in
    # the file.
    # @param [Integer] index The 0-based frame index.
    # @return [ChunkyPNG::Canvas]
    def frame_canvas(index)
      frames.fetch(index).canvas
    end

    alias [] frame_canvas

    # Yields the full-size composited canvas for every frame, in order.
    # @yield [ChunkyPNG::Canvas, Integer] Yields each rendered frame and
    #   its index.
    # @return [Enumerator, self]
    def each_composited_frame
      return enum_for(:each_composited_frame) unless block_given?
      frames.length.times do |index|
        yield(composited_frame(index), index)
      end
      self
    end

    # Returns the full-size canvas showing the frame at the given index,
    # composited following the preceding frames' dispose operations and the
    # frame's blend operation.
    # @param [Integer] index The 0-based frame index.
    # @return [ChunkyPNG::Canvas]
    def composited_frame(index)
      unless index >= 0 && index < frames.length
        raise IndexError, "Frame index #{index} out of range for an animation with #{frames.length} frames!"
      end
      composited_frames[index] ||= render_up_to(index)
    end

    # @return [Array<ChunkyPNG::Canvas, nil>] Memoized composited canvases.
    def composited_frames
      @composited_frames ||= Array.new(frames.length)
    end

    # Loads an Animation from a PNG encoded string.
    # @param [String] str The APNG encoded string.
    # @return [ChunkyPNG::Animation]
    def self.from_blob(str)
      from_datastream(ChunkyPNG::Datastream.from_blob(str))
    end

    class << self
      alias from_string from_blob
    end

    # Loads an Animation from a PNG encoded file.
    # @param [String] filename The file to load from.
    # @return [ChunkyPNG::Animation]
    def self.from_file(filename)
      from_datastream(ChunkyPNG::Datastream.from_file(filename))
    end

    # Loads an Animation from a PNG encoded stream.
    # @param [IO] io The stream to read from.
    # @return [ChunkyPNG::Animation]
    def self.from_io(io)
      from_datastream(ChunkyPNG::Datastream.from_io(io))
    end

    class << self
      alias from_stream from_io
    end

    # Decodes an Animation from a datastream.
    # @param [ChunkyPNG::Datastream] ds The datastream to decode.
    # @return [ChunkyPNG::Animation]
    # @raise [ChunkyPNG::ExpectationFailed] if the datastream is not an
    #   APNG animation.
    def self.from_datastream(ds)
      raise ChunkyPNG::ExpectationFailed, "PNG datastream is not animated (no acTL chunk)!" unless ds.animated?

      animation = new(ds.header_chunk.width, ds.header_chunk.height, plays: ds.animation_control_chunk.num_plays)
      ds.frame_control_chunks.each_with_index do |control_chunk, index|
        full_canvas = decode_frame_datastream(ds, index)
        raw_canvas =
          if control_chunk.width == ds.header_chunk.width && control_chunk.height == ds.header_chunk.height &&
              control_chunk.x_offset.zero? && control_chunk.y_offset.zero?
            full_canvas
          else
            full_canvas.crop(control_chunk.x_offset, control_chunk.y_offset, control_chunk.width, control_chunk.height)
          end
        animation.add_frame(Frame.from_canvas_and_control_chunk(raw_canvas, control_chunk))
      end
      animation
    end

    # Decodes one frame's raw pixel data, at the full default-image size,
    # using the header settings of the datastream.
    # @param [ChunkyPNG::Datastream] ds The datastream to read from.
    # @param [Integer] index The 0-based frame index.
    # @return [ChunkyPNG::Canvas]
    def self.decode_frame_datastream(ds, index)
      header       = ds.header_chunk
      width        = header.width
      height       = header.height
      color_mode   = header.color
      interlace    = header.interlace
      depth        = header.depth

      decoding_palette, transparent_color = nil, nil
      case color_mode
        when ChunkyPNG::COLOR_INDEXED
          # PLTE applies to every frame, but tRNS only defines the
          # transparency of the default image (frame 0).
          decoding_palette = ChunkyPNG::Palette.from_chunks(
            ds.palette_chunk,
            index.zero? ? ds.transparency_chunk : nil
          )
        when ChunkyPNG::COLOR_TRUECOLOR
          # The tRNS chunk only applies to the default image (frame 0);
          # animation frames must not have it applied per the APNG spec.
          if index.zero? && ds.transparency_chunk
            transparent_color = ds.transparency_chunk.truecolor_entry(depth)
          end
        when ChunkyPNG::COLOR_GRAYSCALE
          if index.zero? && ds.transparency_chunk
            transparent_color = ds.transparency_chunk.grayscale_entry(depth)
          end
      end

      stream = ds.frame_imagedata(index)
      canvas = ChunkyPNG::Canvas.send(
        :decode_png_pixelstream,
        stream, width, height, color_mode, depth, interlace, decoding_palette, transparent_color
      )
      canvas.pixels.map! { |c| c == transparent_color ? ChunkyPNG::Color::TRANSPARENT : c } if transparent_color
      canvas
    end

    # Encodes the animation to a PNG formatted string.
    # @param constraints (see ChunkyPNG::Canvas::PNGEncoding#to_datastream)
    # @return [String] The APNG encoded string.
    def to_blob(constraints = {})
      to_datastream(constraints).to_blob
    end

    alias to_string to_blob
    alias to_s to_blob

    # Saves the animation as an APNG file.
    # @param [String] filename The filename to use.
    # @param constraints (see #to_datastream)
    # @return [void]
    def save(filename, constraints = {})
      File.open(filename, "wb") { |io| io.write(to_blob(constraints)) }
    end

    # Builds a datastream for this animation.
    #
    # The default image is the composited result of the first frame, so
    # the PNG remains a valid static image for viewers without APNG
    # support. All frames share the color settings of the encoding.
    #
    # @param constraints (see ChunkyPNG::Canvas::PNGEncoding#to_datastream)
    # @return [ChunkyPNG::Datastream]
    def to_datastream(constraints = {})
      raise ChunkyPNG::ExpectationFailed, "Cannot encode an empty animation!" if frames.empty?

      requested_bit_depth = constraints.is_a?(Hash) ? constraints[:bit_depth] : nil
      encoding = frames.first.canvas.send(:determine_png_encoding, constraints)

      ds = ChunkyPNG::Datastream.new

      combined_palette = nil
      indexed_requested = constraints.is_a?(Hash) && constraints[:color_mode] == ChunkyPNG::COLOR_INDEXED
      if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED && frames_require_alpha?
        if indexed_requested
          raise ChunkyPNG::ExpectationFailed,
            "An APNG cannot encode transparent pixels in animation frames using indexed colors; use a color mode with an alpha channel instead!"
        end
        encoding[:color_mode] = ChunkyPNG::COLOR_TRUECOLOR_ALPHA
        encoding[:bit_depth]  = 8
      elsif encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
        combined_palette = build_encoding_palette
        encoding[:bit_depth] = requested_bit_depth || combined_palette.determine_bit_depth
        if combined_palette.size > (1 << encoding[:bit_depth])
          raise ChunkyPNG::ExpectationFailed,
            "This animation has too many colors for #{encoding[:bit_depth]}-bit indexed PNG!"
        end
      end

      ds.header_chunk = ChunkyPNG::Chunk::Header.new(
        width: width,
        height: height,
        color: encoding[:color_mode],
        depth: encoding[:bit_depth],
        interlace: encoding[:interlace]
      )

      if combined_palette
        ds.palette_chunk      = combined_palette.to_plte_chunk
        ds.transparency_chunk = combined_palette.to_trns_chunk unless combined_palette.opaque?
      end

      ds.animation_control_chunk = ChunkyPNG::Chunk::AnimationControl.new(frames.length, plays)
      ds.end_chunk = ChunkyPNG::Chunk::End.new

      sequence_number = 0
      frames.each_with_index do |frame, index|
        control_chunk = frame.to_frame_control_chunk(sequence_number)
        sequence_number += 1

        full_canvas = frame_canvas_for_encoding(frame, encoding, index)
        stream = full_canvas.send(
          :encode_png_pixelstream,
          encoding[:color_mode], encoding[:bit_depth], encoding[:interlace], encoding[:filtering]
        )
        data = ChunkyPNG::Chunk::ImageData.split_in_chunks(stream, encoding[:compression])

        if index.zero?
          ds.frame_control_chunks << control_chunk
          ds.data_chunks = data
        else
          ds.frame_control_chunks << control_chunk
          frame_chunks = data.map do |chunk|
            frame_chunk = ChunkyPNG::Chunk::FrameData.new(sequence_number, chunk.image_content)
            sequence_number += 1
            frame_chunk
          end
          ds.frame_data_chunks << frame_chunks
        end
      end

      ds
    end

    protected

    # Renders frames from the start up to and including the given index,
    # returning the composited canvas for that frame.
    def render_up_to(index)
      buffer = ChunkyPNG::Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)
      result = nil
      (0..index).each do |frame_index|
        result = render_frame(buffer, frames[frame_index], frame_index)
      end
      result
    end

    # Renders a single frame onto the running output buffer.
    #
    # The region to restore for DISPOSE_OP_PREVIOUS is snapshotted before
    # the frame is blended in. After blending, a copy of the composited
    # buffer is returned for the requested frame; the buffer itself is
    # prepared for the next frame by applying the dispose operation.
    def render_frame(buffer, frame, frame_index)
      region = frame_region(frame)
      previous_region =
        if frame.dispose_op == ChunkyPNG::DISPOSE_OP_PREVIOUS
          extract_region(buffer, region)
        end

      blend_frame(buffer, frame, frame_index)
      composited = buffer.dup

      case frame.dispose_op
        when ChunkyPNG::DISPOSE_OP_BACKGROUND
          clear_region(buffer, region)
        when ChunkyPNG::DISPOSE_OP_PREVIOUS
          restore_region(buffer, region, previous_region)
      end
      composited
    end

    # Applies a frame's blend operation to its region within the buffer.
    def blend_frame(buffer, frame, frame_index)
      # Per the APNG specification, a blend_op of OVER on the first frame
      # is treated as SOURCE because the output buffer starts out fully
      # transparent anyway; explicitly replacing also handles the case
      # where the default image carries initial pixels.
      blend_op = frame_index.zero? ? ChunkyPNG::BLEND_OP_SOURCE : frame.blend_op
      case blend_op
        when ChunkyPNG::BLEND_OP_SOURCE
          buffer.replace!(frame.canvas, frame.x_offset, frame.y_offset)
        when ChunkyPNG::BLEND_OP_OVER
          buffer.compose!(frame.canvas, frame.x_offset, frame.y_offset)
      end
    end

    # @param [ChunkyPNG::Frame] frame
    # @return [Array<Integer>] The x, y, width and height of the frame.
    def frame_region(frame)
      [frame.x_offset, frame.y_offset, frame.width, frame.height]
    end

    # Copies a rectangular region out of a canvas.
    def extract_region(canvas, region)
      x, y, region_width, region_height = region
      pixels = Array.new(region_width * region_height) do |offset|
        offset_x = offset % region_width
        offset_y = offset / region_width
        canvas.pixels[(y + offset_y) * canvas.width + x + offset_x]
      end
      ChunkyPNG::Canvas.new(region_width, region_height, pixels)
    end

    # Restores a previously snapshotted region into a canvas.
    def restore_region(canvas, region, snapshot)
      canvas.replace!(snapshot, region[0], region[1])
    end

    # Clears a region to fully transparent pixels. On the first frame this
    # also clears any initial content within the region, as required by the
    # special first-frame dispose rule in the APNG specification.
    def clear_region(canvas, region)
      x, y, region_width, region_height = region
      region_height.times do |offset_y|
        region_width.times do |offset_x|
          canvas.pixels[(y + offset_y) * canvas.width + x + offset_x] = ChunkyPNG::Color::TRANSPARENT
        end
      end
      canvas
    end

    # Builds the full-size canvas that should be encoded for a frame.
    # For the first frame this is the composited result (which serves as
    # the static default image); later frames are placed on a transparent
    # canvas at their offsets.
    def frame_canvas_for_encoding(frame, encoding, frame_index)
      full_canvas = ChunkyPNG::Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)
      if frame_index.zero?
        if frame.blend_op == ChunkyPNG::BLEND_OP_OVER
          full_canvas.compose!(frame.canvas, frame.x_offset, frame.y_offset)
        else
          full_canvas.replace!(frame.canvas, frame.x_offset, frame.y_offset)
        end
      else
        full_canvas.replace!(frame.canvas, frame.x_offset, frame.y_offset)
      end
      full_canvas.encoding_palette = @encoding_palette if encoding[:color_mode] == ChunkyPNG::COLOR_INDEXED
      full_canvas
    end

    # Checks whether any frame contains non-opaque pixels.
    # @return [Boolean] True if at least one pixel has an alpha value below 255.
    def frames_require_alpha?
      frames.any? do |frame|
        frame.canvas.pixels.any? { |pixel| !ChunkyPNG::Color.opaque?(pixel) }
      end
    end

    # Builds a single palette containing the colors of every frame's pixels,
    # so all frames can share one PLTE chunk.
    def build_encoding_palette
      colors = []
      colors << ChunkyPNG::Color::TRANSPARENT
      frames.each do |frame|
        colors.concat(frame.canvas.pixels)
      end
      palette = ChunkyPNG::Palette.from_pixels(colors)
      @encoding_palette = palette
    end
  end
end
