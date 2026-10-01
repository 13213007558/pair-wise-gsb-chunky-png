# frozen-string-literal: true

module ChunkyPNG
  # The Datastream class represents a PNG formatted datastream. It supports
  # both reading from and writing to strings, streams and files.
  #
  # A PNG datastream begins with the PNG signature, and then contains multiple
  # chunks, starting with a header (IHDR) chunk and finishing with an end
  # (IEND) chunk.
  #
  # @see ChunkyPNG::Chunk
  class Datastream
    # The signature that each PNG file or stream should begin with.
    SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10].pack("C8").force_encoding(::Encoding::BINARY).freeze

    # The header chunk of this datastream.
    # @return [ChunkyPNG::Chunk::Header]
    attr_accessor :header_chunk

    # All other chunks in this PNG file.
    # @return [Array<ChunkyPNG::Chunk::Generic>]
    attr_accessor :other_chunks

    # The chunk containing the image's palette.
    # @return [ChunkyPNG::Chunk::Palette]
    attr_accessor :palette_chunk

    # The chunk containing the transparency information of the palette.
    # @return [ChunkyPNG::Chunk::Transparency]
    attr_accessor :transparency_chunk

    # The chunk containing the physical dimensions of the PNG's pixels.
    # @return [ChunkyPNG::Chunk::Physical]
    attr_accessor :physical_chunk

    # The animation control chunk, if this datastream is an APNG.
    # @return [ChunkyPNG::Chunk::AnimationControl, nil]
    attr_accessor :animation_control_chunk

    # The frame control chunks of this datastream, one per animation frame.
    # The first chunk controls the default image (which uses the IDAT
    # chunks); subsequent frames use the data chunks in
    # {#frame_data_chunks}.
    # @return [Array<ChunkyPNG::Chunk::FrameControl>]
    attr_accessor :frame_control_chunks

    # The fdAT chunks of this datastream, grouped per animation frame, in
    # frame order. The first element holds the data chunks for the frame
    # following the default image, i.e. it corresponds with the second
    # element of {#frame_control_chunks}.
    # @return [Array<Array<ChunkyPNG::Chunk::FrameData>>]
    attr_accessor :frame_data_chunks

    # The chunks that together compose the images pixel data.
    # @return [Array<ChunkyPNG::Chunk::ImageData>]
    attr_accessor :data_chunks

    # The empty chunk that signals the end of this datastream
    # @return [ChunkyPNG::Chunk::Header]
    attr_accessor :end_chunk

    # Initializes a new Datastream instance.
    def initialize
      @other_chunks = []
      @data_chunks  = []
      @frame_control_chunks = []
      @frame_data_chunks   = []
    end

    ##############################################################################
    # LOADING DATASTREAMS
    ##############################################################################

    class << self
      # Reads a PNG datastream from a string.
      # @param [String] str The PNG encoded string to load from.
      # @return [ChunkyPNG::Datastream] The loaded datastream instance.
      def from_blob(str)
        from_io(StringIO.new(str, "rb"))
      end

      alias from_string from_blob

      # Reads a PNG datastream from a file.
      # @param [String] filename The path of the file to load from.
      # @return [ChunkyPNG::Datastream] The loaded datastream instance.
      def from_file(filename)
        ds = nil
        File.open(filename, "rb") { |f| ds = from_io(f) }
        ds
      end

      # Reads a PNG datastream from an input stream
      # @param [IO] io The stream to read from.
      # @return [ChunkyPNG::Datastream] The loaded datastream instance.
      def from_io(io)
        io.set_encoding(::Encoding::BINARY)
        verify_signature!(io)

        ds = new
        expected_sequence_number = nil
        pending_frame_index = nil
        while ds.end_chunk.nil?
          frame_index = ds.frame_control_chunks.length
          begin
            chunk = ChunkyPNG::Chunk.read(io)
            case chunk
              when ChunkyPNG::Chunk::Header
                ds.header_chunk = chunk

              when ChunkyPNG::Chunk::AnimationControl
                if ds.data_chunks.any?
                  raise ChunkyPNG::ExpectationFailed, "The acTL chunk should occur before the first IDAT chunk!"
                end
                ds.animation_control_chunk = chunk
                expected_sequence_number = 0

              when ChunkyPNG::Chunk::FrameControl
                unless ds.animation_control_chunk
                  ds.other_chunks << chunk
                else
                  unless chunk.sequence_number == expected_sequence_number
                    raise ChunkyPNG::ExpectationFailed,
                      "fcTL chunk for frame #{frame_index} has sequence number #{chunk.sequence_number}, expected #{expected_sequence_number}!"
                  end
                  expected_sequence_number += 1

                  ds.frame_control_chunks << chunk
                  ds.validate_frame_control_chunk!(chunk, frame_index)

                  pending_frame_index = frame_index
                  ds.frame_data_chunks << [] if frame_index > 0
                end

              when ChunkyPNG::Chunk::FrameData
                unless ds.animation_control_chunk && pending_frame_index && pending_frame_index > 0
                  ds.other_chunks << chunk
                else
                  frame_index = pending_frame_index
                  unless chunk.sequence_number == expected_sequence_number
                    raise ChunkyPNG::ExpectationFailed,
                      "fdAT chunk for frame #{frame_index} has sequence number #{chunk.sequence_number}, expected #{expected_sequence_number}!"
                  end
                  expected_sequence_number += 1
                  ds.frame_data_chunks.last << chunk
                end

              when ChunkyPNG::Chunk::Palette      then ds.palette_chunk = chunk
              when ChunkyPNG::Chunk::Transparency then ds.transparency_chunk = chunk

              when ChunkyPNG::Chunk::ImageData
                if ds.animation_control_chunk
                  if ds.frame_control_chunks.empty?
                    raise ChunkyPNG::ExpectationFailed, "IDAT data in an APNG datastream should be preceded by an fcTL chunk!"
                  end
                  if pending_frame_index && pending_frame_index > 0
                    raise ChunkyPNG::ExpectationFailed, "Unexpected IDAT chunk after animation frames have started!"
                  end
                end
                ds.data_chunks << chunk

              when ChunkyPNG::Chunk::Physical     then ds.physical_chunk = chunk
              when ChunkyPNG::Chunk::End          then ds.end_chunk = chunk
              else ds.other_chunks << chunk
            end
          rescue ChunkyPNG::Exception => e
            if e.message.start_with?("The fcTL chunk should contain exactly")
              raise ChunkyPNG::ExpectationFailed, "Invalid fcTL chunk for frame #{frame_index}: #{e.message}"
            end
            raise
          end
        end
        ds.validate_animation!
        ds
      end

      # Verifies that the current stream is a PNG datastream by checking its signature.
      #
      # This method reads the PNG signature from the stream, setting the current position
      # of the stream directly after the signature, where the IHDR chunk should begin.
      #
      # @param [IO] io The stream to read the PNG signature from.
      # @raise [RuntimeError] An exception is raised if the PNG signature is not found at
      #    the beginning of the stream.
      def verify_signature!(io)
        signature = io.read(ChunkyPNG::Datastream::SIGNATURE.length)
        unless signature == ChunkyPNG::Datastream::SIGNATURE
          raise ChunkyPNG::SignatureMismatch, "PNG signature not found, found #{signature.inspect} instead of #{ChunkyPNG::Datastream::SIGNATURE.inspect}!"
        end
      end
    end

    ##################################################################################
    # CHUNKS
    ##################################################################################

    # Enumerates the chunks in this datastream.
    #
    # This will iterate over the chunks using the order in which the chunks
    # should appear in the PNG file.
    #
    # @yield [chunk] Yields the chunks in this datastream, one by one in the correct order.
    # @yieldparam [ChunkyPNG::Chunk::Base] chunk A chunk in this datastream.
    # @see ChunkyPNG::Datastream#chunks
    def each_chunk
      yield(header_chunk)
      yield(animation_control_chunk) if animation_control_chunk

      if animation? && frame_control_chunks.any?
        other_chunks.each { |chunk| yield(chunk) }
        yield(palette_chunk)      if palette_chunk
        yield(transparency_chunk) if transparency_chunk
        yield(physical_chunk)     if physical_chunk

        yield(frame_control_chunks.first)
        data_chunks.each { |chunk| yield(chunk) }
        frame_control_chunks[1..-1].each_with_index do |frame_control_chunk, index|
          yield(frame_control_chunk)
          frame_data_chunks[index].each { |chunk| yield(chunk) }
        end
      else
        other_chunks.each { |chunk| yield(chunk) }
        yield(palette_chunk)      if palette_chunk
        yield(transparency_chunk) if transparency_chunk
        yield(physical_chunk)     if physical_chunk
        data_chunks.each { |chunk| yield(chunk) }
      end
      yield(end_chunk)
    end

    # Returns an enumerator instance for this datastream's chunks.
    # @return [Enumerable::Enumerator] An enumerator for the :each_chunk method.
    # @see ChunkyPNG::Datastream#each_chunk
    def chunks
      enum_for(:each_chunk)
    end

    # Returns all the textual metadata key/value pairs as hash.
    # @return [Hash] A hash containing metadata fields and their values.
    def metadata
      metadata = {}
      other_chunks.each do |chunk|
        metadata[chunk.keyword] = chunk.value if chunk.respond_to?(:keyword) && chunk.respond_to?(:value)
      end
      metadata
    end

    # Returns the uncompressed image data, combined from all the IDAT chunks
    # @return [String] The uncompressed image data for this datastream
    def imagedata
      ChunkyPNG::Chunk::ImageData.combine_chunks(data_chunks)
    end

    # Returns the uncompressed image data for an animation frame.
    #
    # Frame 0 uses the IDAT chunks (i.e. the default image); later frames
    # use their fdAT chunks.
    #
    # @param [Integer] index The 0-based frame index.
    # @return [String] The inflated pixel data for the requested frame.
    def frame_imagedata(index)
      chunks = index.zero? ? data_chunks : frame_data_chunks[index - 1]
      ChunkyPNG::Chunk::ImageData.combine_chunks(chunks)
    end

    # Returns whether this datastream describes an APNG animation.
    #
    # A PNG is considered animated if and only if it contains an acTL
    # chunk, as specified by the APNG specification.
    #
    # @return [Boolean]
    def animated?
      !animation_control_chunk.nil?
    end

    alias animation? animated?

    # Validates the fields of an fcTL chunk against the datastream header.
    # @param [ChunkyPNG::Chunk::FrameControl] chunk The chunk to validate.
    # @param [Integer] frame_index The 0-based index of the frame this
    #   chunk controls, used in error messages.
    # @return [void]
    # @raise [ChunkyPNG::ExpectationFailed] if any field is invalid.
    def validate_frame_control_chunk!(chunk, frame_index)
      if chunk.width.nil? || chunk.width.zero? || chunk.height.nil? || chunk.height.zero?
        raise ChunkyPNG::ExpectationFailed, "fcTL chunk for frame #{frame_index} should have a non-zero width and height!"
      end

      if chunk.x_offset < 0 || chunk.y_offset < 0 ||
          chunk.x_offset + chunk.width > header_chunk.width ||
          chunk.y_offset + chunk.height > header_chunk.height
        raise ChunkyPNG::ExpectationFailed,
          "fcTL chunk for frame #{frame_index} has a region (#{chunk.x_offset},#{chunk.y_offset}:#{chunk.width}x#{chunk.height}) that does not fit in the #{header_chunk.width}x#{header_chunk.height} image!"
      end

      valid_dispose_ops = [
        ChunkyPNG::DISPOSE_OP_NONE,
        ChunkyPNG::DISPOSE_OP_BACKGROUND,
        ChunkyPNG::DISPOSE_OP_PREVIOUS,
      ]
      unless valid_dispose_ops.include?(chunk.dispose_op)
        raise ChunkyPNG::ExpectationFailed, "fcTL chunk for frame #{frame_index} has an invalid dispose operation #{chunk.dispose_op}!"
      end

      unless [ChunkyPNG::BLEND_OP_SOURCE, ChunkyPNG::BLEND_OP_OVER].include?(chunk.blend_op)
        raise ChunkyPNG::ExpectationFailed, "fcTL chunk for frame #{frame_index} has an invalid blend operation #{chunk.blend_op}!"
      end
    end

    # Validates the overall structure of an animated datastream after all
    # chunks have been read.
    # @return [void]
    # @raise [ChunkyPNG::ExpectationFailed] if the animation is incomplete.
    def validate_animation!
      return unless animation?

      if animation_control_chunk.num_frames.zero?
        raise ChunkyPNG::ExpectationFailed, "The acTL chunk should declare at least one frame!"
      end

      if frame_control_chunks.empty?
        raise ChunkyPNG::ExpectationFailed, "An APNG datastream should contain at least one fcTL chunk!"
      end

      if data_chunks.empty?
        raise ChunkyPNG::ExpectationFailed, "An APNG datastream should contain IDAT chunks for its default image!"
      end

      frame_data_chunks.each_with_index do |chunks, index|
        if chunks.empty?
          raise ChunkyPNG::ExpectationFailed, "Frame #{index + 1} does not contain any fdAT chunks!"
        end
      end
    end

    ##################################################################################
    # WRITING DATASTREAMS
    ##################################################################################

    # Writes the datastream to the given output stream.
    # @param [IO] io The output stream to write to.
    def write(io)
      io << SIGNATURE
      each_chunk { |c| c.write(io) }
    end

    # Saves this datastream as a PNG file.
    # @param [String] filename The filename to use.
    def save(filename)
      File.open(filename, "wb") { |f| write(f) }
    end

    # Encodes this datastream into a string.
    # @return [String] The encoded PNG datastream.
    def to_blob
      str = StringIO.new
      str.set_encoding("ASCII-8BIT")
      write(str)
      str.string
    end

    alias to_string to_blob
    alias to_s to_blob
  end
end
