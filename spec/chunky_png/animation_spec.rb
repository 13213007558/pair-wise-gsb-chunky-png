require "spec_helper"

describe ChunkyPNG::Animation do

  let(:transparent) { ChunkyPNG::Color::TRANSPARENT }
  let(:red)   { ChunkyPNG::Color.rgba(255, 0, 0, 255) }
  let(:green) { ChunkyPNG::Color.rgba(0, 255, 0, 128) }
  let(:white) { ChunkyPNG::Color.rgba(255, 255, 255, 128) }

  # 2x2 frame: opaque red, half transparent green, transparent, opaque red
  let(:first_pixels) { [red, green, transparent, red] }

  # Half-transparent white 1x2 rectangle, placed at x offset 1
  let(:overlay_pixels) { [white, white] }

  let(:animation) do
    animation = ChunkyPNG::Animation.new(2, 2, 3)
    animation.add_frame(ChunkyPNG::Frame.new(2, 2, first_pixels,
      delay_num: 1, delay_den: 2,
      dispose_op: ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND,
      blend_op: ChunkyPNG::APNG_BLEND_OP_SOURCE))
    animation.add_frame(ChunkyPNG::Frame.new(1, 2, overlay_pixels,
      x_offset: 1, delay_num: 3, delay_den: 4,
      dispose_op: ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS,
      blend_op: ChunkyPNG::APNG_BLEND_OP_OVER))
    animation
  end

  describe "building" do
    it "should keep track of the frames and loop count" do
      expect(animation.frame_count).to eql 2
      expect(animation.plays).to eql 3
      expect(animation.duration).to be_within(1e-9).of(0.5 + 0.75)
    end

    it "should expose the raw frame rectangles and their offsets" do
      first, second = animation.frames
      expect(first.width).to eql 2
      expect(first.height).to eql 2
      expect(first.pixels).to eql first_pixels

      expect(second.width).to eql 1
      expect(second.height).to eql 2
      expect(second.x_offset).to eql 1
      expect(second.y_offset).to eql 0
      expect(second.pixels).to eql overlay_pixels
    end

    it "should accept symbol dispose and blend options" do
      frame = ChunkyPNG::Frame.new(1, 1, [red], dispose_op: :background, blend_op: :over)
      expect(frame.dispose_op).to eql ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND
      expect(frame.blend_op).to eql ChunkyPNG::APNG_BLEND_OP_OVER
    end
  end

  describe "compositing" do
    it "renders the first frame as a source replacement even if it is semi-transparent" do
      first = animation.composited_frame(0)
      expect(first.pixels).to eql first_pixels
    end

    it "alpha-composites a semi-transparent OVER frame onto the previous output" do
      second = animation.composited_frame(1)
      # The BACKGROUND dispose of the first frame cleared the full canvas
      # before the overlay was rendered, so the left column stays transparent.
      # Compositing a semi-transparent pixel over a fully transparent
      # background preserves the frame pixel and its alpha.
      expect(second.pixels).to eql [transparent, white, transparent, white]
    end

    it "alpha-composites a semi-transparent OVER frame onto the retained pixels of a NONE-dispose frame" do
      none_animation = ChunkyPNG::Animation.new(2, 1)
      none_animation.add_frame(ChunkyPNG::Frame.new(2, 1, [green, red],
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE,
        blend_op: ChunkyPNG::APNG_BLEND_OP_SOURCE))
      none_animation.add_frame(ChunkyPNG::Frame.new(1, 1, [white],
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE,
        blend_op: ChunkyPNG::APNG_BLEND_OP_OVER))
      second = none_animation.composited_frame(1)
      expect(second.pixels).to eql [ChunkyPNG::Color.compose(white, green), red]
    end

    it "restores the PREVIOUS region for the frame following a PREVIOUS dispose frame" do
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [red], x_offset: 0, y_offset: 0,
        delay_num: 1, delay_den: 1,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE,
        blend_op: ChunkyPNG::APNG_BLEND_OP_SOURCE))

      third = animation.composited_frame(2)
      # Frame 2 restored the right column (its region) to the cleared canvas
      # before frame 3 painted the top-left pixel red.
      expect(third.pixels).to eql [red, transparent, transparent, transparent]
    end

    it "clears only the frame region for BACKGROUND disposal" do
      animation = ChunkyPNG::Animation.new(2, 1)
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [red], x_offset: 0,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE))
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [red], x_offset: 1,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND))
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [red], x_offset: 1,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE))

      frames = animation.composited_frames
      expect(frames[0].pixels).to eql [red, transparent]
      expect(frames[1].pixels).to eql [red, red]
      # Only the right pixel of frame 2 is cleared; the left pixel remains.
      expect(frames[2].pixels).to eql [red, red]
    end

    it "treats PREVIOUS disposal of the first frame like BACKGROUND" do
      animation = ChunkyPNG::Animation.new(1, 2)
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [red],
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS,
        blend_op: ChunkyPNG::APNG_BLEND_OP_OVER))
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [red], y_offset: 1,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE,
        blend_op: ChunkyPNG::APNG_BLEND_OP_SOURCE))

      frames = animation.composited_frames
      expect(frames[0].pixels).to eql [red, transparent]
      # The first frame's (invalid for the first frame) PREVIOUS dispose is
      # handled as BACKGROUND, so the top pixel is transparent for frame 2.
      expect(frames[1].pixels).to eql [transparent, red]
    end

    it "always blends the first frame as SOURCE, ignoring its blend operation" do
      animation = ChunkyPNG::Animation.new(1, 1)
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [green], blend_op: ChunkyPNG::APNG_BLEND_OP_OVER))
      expect(animation.composited_frame(0).pixels).to eql [green]
    end
  end

  describe "encoding and reading back" do
    # The main test animation uses fractional alpha values, so force RGBA
    # encoding rather than the automatic indexed choice.
    let(:blob) { animation.to_blob(:fast_rgba) }

    it "writes the chunks in the APNG order with the default image as first frame" do
      types = chunk_types(blob)
      expect(types).to eql %w[IHDR acTL fcTL IDAT fcTL fdAT IEND]
    end

    it "writes a transparent placeholder default image when the first frame is partial" do
      partial = ChunkyPNG::Animation.new(2, 1)
      partial.add_frame(ChunkyPNG::Frame.new(1, 1, [red], x_offset: 0))
      partial.add_frame(ChunkyPNG::Frame.new(1, 1, [red], x_offset: 1))
      blob = partial.to_blob(:fast_rgba)

      expect(chunk_types(blob)).to eql %w[IHDR acTL IDAT fcTL fdAT fcTL fdAT IEND]
      default_image = ChunkyPNG::Image.from_blob(blob)
      expect(default_image.pixels).to eql [transparent, transparent]

      read_back = ChunkyPNG::Animation.from_blob(blob)
      expect(read_back.frame_count).to eql 2
      expect(read_back.frames.map(&:x_offset)).to eql [0, 1]
    end

    it "decodes raw fdAT frames and restores only the frame region for PREVIOUS disposal" do
      red = ChunkyPNG::Color.rgb(255, 0, 0)
      blue = ChunkyPNG::Color.rgb(0, 0, 255)
      animation = ChunkyPNG::Animation.new(3, 1)
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [red], x_offset: 0,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE))
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [blue], x_offset: 2,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS))
      animation.add_frame(ChunkyPNG::Frame.new(1, 1, [blue], x_offset: 1,
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_NONE))

      blob = animation.to_blob(:fast_rgba)
      ds = ChunkyPNG::Datastream.from_blob(blob)
      expect(ds.frame_chunks.all? { |_control, data| data.first.is_a?(ChunkyPNG::Chunk::FrameData) }).to be true

      composited = ChunkyPNG::Animation.from_blob(blob).composited_frames
      expect(composited.map(&:pixels)).to eql [
        [red, transparent, transparent],
        [red, transparent, blue],
        # Frame 2's region (right pixel) reverted to its pre-frame contents.
        [red, blue, transparent],
      ]
    end

    it "reads back every frame's raw rectangle, offset and timing fraction" do
      read_back = ChunkyPNG::Animation.from_blob(blob)
      expect(read_back.frame_count).to eql 2
      expect(read_back.plays).to eql 3

      first, second = read_back.frames
      expect(first.dimension.to_a).to eql [2, 2]
      expect(first.pixels).to eql first_pixels
      expect(first.delay_num).to eql 1
      expect(first.delay_den).to eql 2
      expect(first.dispose_op).to eql ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND
      expect(first.blend_op).to eql ChunkyPNG::APNG_BLEND_OP_SOURCE

      expect(second.dimension.to_a).to eql [1, 2]
      expect(second.x_offset).to eql 1
      expect(second.pixels).to eql overlay_pixels
      expect(second.delay_num).to eql 3
      expect(second.delay_den).to eql 4
      expect(second.dispose_op).to eql ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS
      expect(second.blend_op).to eql ChunkyPNG::APNG_BLEND_OP_OVER
    end

    it "composites the read-back animation identically to the original" do
      original = animation.composited_frames.map(&:pixels)
      read_back = ChunkyPNG::Animation.from_blob(blob).composited_frames.map(&:pixels)
      expect(read_back).to eql original
    end

    it "normalizes a delay denominator of 0 to 100" do
      custom = ChunkyPNG::Animation.new(1, 1)
      custom.add_frame(ChunkyPNG::Frame.new(1, 1, [red], delay_num: 2, delay_den: 0))
      read_back = ChunkyPNG::Animation.from_blob(custom.to_blob(:fast_rgba))
      expect(read_back.frames.first.delay_den).to eql 100
      expect(read_back.frames.first.duration).to be_within(1e-9).of(0.02)
    end

    it "can round-trip an animation using indexed colors with a shared palette" do
      indexed = ChunkyPNG::Animation.new(2, 1)
      indexed.add_frame(ChunkyPNG::Frame.new(1, 1, [red]))
      blue = ChunkyPNG::Color.rgb(0, 0, 255)
      indexed.add_frame(ChunkyPNG::Frame.new(1, 1, [blue], x_offset: 1))
      blob = indexed.to_blob

      ds = ChunkyPNG::Datastream.from_blob(blob)
      expect(ds.header_chunk.color).to eql ChunkyPNG::COLOR_INDEXED

      read_back = ChunkyPNG::Animation.from_blob(blob)
      expect(read_back.composited_frames.map(&:pixels)).to eql [
        [red, transparent],
        [red, blue],
      ]
    end

    it "preserves metadata chunks alongside animation chunks" do
      ds = animation.to_datastream(:fast_rgba)
      ds.other_chunks << ChunkyPNG::Chunk::Text.new("Comment", "hello animation")
      blob = ds.to_blob

      read_ds = ChunkyPNG::Datastream.from_blob(blob)
      expect(read_ds.metadata["Comment"]).to eql "hello animation"
      expect(ChunkyPNG::Animation.from_blob(blob).frame_count).to eql 2
    end
  end

  describe "loading errors" do
    it "raises when a plain PNG is loaded as an animation" do
      blob = ChunkyPNG::Canvas.new(1, 1, [red]).to_blob
      expect { ChunkyPNG::Animation.from_blob(blob) }.to raise_error(ChunkyPNG::ExpectationFailed, /acTL/)
    end

    it "reports the frame number of a corrupt fcTL chunk" do
      blob = animation.to_blob(:fast_rgba)
      corrupted = corrupt_fctl(blob, 1, dispose_op: 9)
      expect { ChunkyPNG::Animation.from_blob(corrupted) }.to raise_error(
        ChunkyPNG::ExpectationFailed, /frame 2/)
    end

    it "reports the frame number when the first fcTL chunk does not cover the canvas" do
      blob = animation.to_blob(:fast_rgba)
      corrupted = corrupt_fctl(blob, 0, height: 1)
      expect { ChunkyPNG::Animation.from_blob(corrupted) }.to raise_error(
        ChunkyPNG::ExpectationFailed, /frame 1/)
    end

    it "reports the frame number when a fcTL chunk is truncated" do
      blob = animation.to_blob(:fast_rgba)
      corrupted = truncate_fctl(blob, 0)
      expect { ChunkyPNG::Animation.from_blob(corrupted) }.to raise_error(
        ChunkyPNG::ExpectationFailed, /frame 1/)
    end
  end

  def chunk_types(blob)
    io = StringIO.new(blob, "rb")
    io.set_encoding(Encoding::BINARY)
    io.read(8)
    types = []
    until io.eof?
      length, type = io.read(8).unpack("Na4")
      types << type
      io.read(length + 4)
    end
    types
  end

  # Rewrites the nth fcTL chunk's content fields (and CRC) in a blob.
  def corrupt_fctl(blob, index, fields)
    rewrite_chunk(blob, "fcTL", index) do |content|
      values = content.unpack("NNNNNnnCC")
      mapping = {sequence_number: 0, width: 1, height: 2, x_offset: 3, y_offset: 4,
                 delay_num: 5, delay_den: 6, dispose_op: 7, blend_op: 8}
      fields.each { |key, value| values[mapping.fetch(key)] = value }
      values.pack("NNNNNnnCC")
    end
  end

  def truncate_fctl(blob, index)
    rewrite_chunk(blob, "fcTL", index) { |_content| "\x00".b * 10 }
  end

  def rewrite_chunk(blob, target_type, target_index)
    io = StringIO.new(blob, "rb")
    io.set_encoding(Encoding::BINARY)
    signature = io.read(8)
    out = StringIO.new
    out.set_encoding(Encoding::BINARY)
    out << signature

    seen = 0
    until io.eof?
      length, type = io.read(8).unpack("Na4")
      content = io.read(length)
      io.read(4) # old CRC

      if type == target_type
        content = yield(content) if seen == target_index
        seen += 1
      end
      out << [content.bytesize].pack("N") << type << content
      out << [Zlib.crc32(content, Zlib.crc32(type))].pack("N")
    end
    out.string
  end
end
