require "spec_helper"
require "tmpdir"

describe ChunkyPNG::Animation do
  def solid_canvas(width, height, color)
    ChunkyPNG::Canvas.new(width, height, color)
  end

  def crafted_apng(chunks)
    stream = StringIO.new
    stream.set_encoding("ASCII-8BIT")
    stream << ChunkyPNG::Datastream::SIGNATURE
    chunks.each { |chunk| chunk.write(stream) }
    stream.string
  end

  let(:red) { ChunkyPNG::Color.rgb(255, 0, 0) }
  let(:green) { ChunkyPNG::Color.rgb(0, 255, 0) }
  let(:blue) { ChunkyPNG::Color.rgb(0, 0, 255) }
  let(:semi_blue) { ChunkyPNG::Color.rgba(0, 0, 255, 128) }

  describe "round trip of a three frame animation with partial coverage" do
    let(:animation) do
      animation = ChunkyPNG::Animation.new(4, 4, loop_count: 3)
      animation.add_frame(solid_canvas(4, 4, red),
        delay_num: 1, delay_den: 10,
        dispose_op: ChunkyPNG::Animation::DISPOSE_OP_NONE,
        blend_op: ChunkyPNG::Animation::BLEND_OP_SOURCE)
      animation.add_frame(solid_canvas(2, 2, green),
        x_offset: 1, y_offset: 1,
        delay_num: 2, delay_den: 10,
        dispose_op: ChunkyPNG::Animation::DISPOSE_OP_BACKGROUND,
        blend_op: ChunkyPNG::Animation::BLEND_OP_SOURCE)
      animation.add_frame(solid_canvas(2, 2, semi_blue),
        x_offset: 0, y_offset: 2,
        delay_num: 3, delay_den: 10,
        dispose_op: ChunkyPNG::Animation::DISPOSE_OP_NONE,
        blend_op: ChunkyPNG::Animation::BLEND_OP_OVER)
      animation
    end

    let(:decoded) { ChunkyPNG::Animation.from_blob(animation.to_blob) }

    it "preserves the canvas dimensions and the loop count" do
      expect(decoded.width).to eql 4
      expect(decoded.height).to eql 4
      expect(decoded.loop_count).to eql 3
    end

    it "preserves the frame regions, delays and operations" do
      expect(decoded.frame_count).to eql 3

      expect(decoded.frames[0].x_offset).to eql 0
      expect(decoded.frames[0].y_offset).to eql 0
      expect(decoded.frames[0].width).to eql 4
      expect(decoded.frames[0].height).to eql 4
      expect(decoded.frames[0].delay).to eql Rational(1, 10)
      expect(decoded.frames[0].dispose_op).to eql ChunkyPNG::Animation::DISPOSE_OP_NONE
      expect(decoded.frames[0].blend_op).to eql ChunkyPNG::Animation::BLEND_OP_SOURCE

      expect(decoded.frames[1].x_offset).to eql 1
      expect(decoded.frames[1].y_offset).to eql 1
      expect(decoded.frames[1].width).to eql 2
      expect(decoded.frames[1].height).to eql 2
      expect(decoded.frames[1].delay).to eql Rational(2, 10)
      expect(decoded.frames[1].dispose_op).to eql ChunkyPNG::Animation::DISPOSE_OP_BACKGROUND

      expect(decoded.frames[2].x_offset).to eql 0
      expect(decoded.frames[2].y_offset).to eql 2
      expect(decoded.frames[2].delay).to eql Rational(3, 10)
      expect(decoded.frames[2].blend_op).to eql ChunkyPNG::Animation::BLEND_OP_OVER
    end

    it "renders the expected full canvas for every frame" do
      first = solid_canvas(4, 4, red)

      second = solid_canvas(4, 4, red)
      second.replace!(solid_canvas(2, 2, green), 1, 1)

      third = second.dup
      2.times do |y|
        2.times do |x|
          third.set_pixel(1 + x, 1 + y, ChunkyPNG::Color::TRANSPARENT)
        end
      end
      third.compose!(solid_canvas(2, 2, semi_blue), 0, 2)

      displayed = decoded.display_frames
      expect(displayed.length).to eql 3
      expect(displayed[0].pixels).to eql first.pixels
      expect(displayed[1].pixels).to eql second.pixels
      expect(displayed[2].pixels).to eql third.pixels
    end
  end

  describe "#display_frames" do
    it "restores the region to its content before the previous frame for the previous dispose operation" do
      animation = ChunkyPNG::Animation.new(4, 4)
      animation.add_frame(solid_canvas(4, 4, red), dispose_op: ChunkyPNG::Animation::DISPOSE_OP_NONE)
      animation.add_frame(solid_canvas(2, 2, green), x_offset: 1, y_offset: 1,
        dispose_op: ChunkyPNG::Animation::DISPOSE_OP_PREVIOUS)
      animation.add_frame(solid_canvas(1, 1, blue), x_offset: 0, y_offset: 0,
        dispose_op: ChunkyPNG::Animation::DISPOSE_OP_NONE)

      displayed = animation.display_frames
      expect(displayed[1].pixels).to eql solid_canvas(4, 4, red).replace!(solid_canvas(2, 2, green), 1, 1).pixels

      expected = solid_canvas(4, 4, red)
      expected.set_pixel(0, 0, blue)
      expect(displayed[2].pixels).to eql expected.pixels
    end

    it "clears the region for the background dispose operation" do
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.add_frame(solid_canvas(2, 2, red), dispose_op: ChunkyPNG::Animation::DISPOSE_OP_BACKGROUND)
      animation.add_frame(solid_canvas(1, 1, blue), x_offset: 1, y_offset: 1)

      displayed = animation.display_frames
      expected = solid_canvas(2, 2, ChunkyPNG::Color::TRANSPARENT)
      expected.set_pixel(1, 1, blue)
      expect(displayed[1].pixels).to eql expected.pixels
    end
  end

  describe "default image" do
    it "round trips a default image that is not part of the animation" do
      animation = ChunkyPNG::Animation.new(2, 2, loop_count: 1)
      animation.default_image = solid_canvas(2, 2, green)
      animation.add_frame(solid_canvas(2, 2, red), delay_num: 1, delay_den: 5)

      decoded = ChunkyPNG::Animation.from_blob(animation.to_blob)
      expect(decoded.frame_count).to eql 1
      expect(decoded.default_image.pixels).to eql solid_canvas(2, 2, green).pixels
      expect(decoded.frames[0].canvas.pixels).to eql solid_canvas(2, 2, red).pixels
    end

    it "shows the default image to decoders that do not support animation" do
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.default_image = solid_canvas(2, 2, green)
      animation.add_frame(solid_canvas(2, 2, red))

      static = ChunkyPNG::Canvas.from_blob(animation.to_blob)
      expect(static.pixels).to eql solid_canvas(2, 2, green).pixels
    end

    it "uses the first frame as default image when no default image is set" do
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.add_frame(solid_canvas(2, 2, red))
      animation.add_frame(solid_canvas(2, 2, blue))

      blob = animation.to_blob
      expect(ChunkyPNG::Canvas.from_blob(blob).pixels).to eql solid_canvas(2, 2, red).pixels

      decoded = ChunkyPNG::Animation.from_blob(blob)
      expect(decoded.default_image).to be_nil
      expect(decoded.frame_count).to eql 2
    end
  end

  describe "validation" do
    it "rejects a frame that does not fit on the animation canvas" do
      animation = ChunkyPNG::Animation.new(4, 4)
      expect { animation.add_frame(solid_canvas(3, 3, red), x_offset: 2, y_offset: 0) }
        .to raise_error(ChunkyPNG::OutOfBounds)
      expect { animation.add_frame(solid_canvas(4, 4, red), x_offset: 0, y_offset: 1) }
        .to raise_error(ChunkyPNG::OutOfBounds)
    end

    it "rejects a stream with an incorrect frame sequence number" do
      header = ChunkyPNG::Chunk::Header.new(width: 2, height: 2, color: ChunkyPNG::COLOR_TRUECOLOR_ALPHA, depth: 8)
      actl = ChunkyPNG::Chunk::AnimationControl.new(num_frames: 1, num_plays: 0)
      fctl = ChunkyPNG::Chunk::FrameControl.new(sequence_number: 7, width: 2, height: 2)
      idat = solid_canvas(2, 2, red).to_datastream(color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA).data_chunks.first

      blob = crafted_apng([header, actl, fctl, idat, ChunkyPNG::Chunk::End.new])
      expect { ChunkyPNG::Animation.from_blob(blob) }.to raise_error(ChunkyPNG::ExpectationFailed, /sequence number/)
    end

    it "rejects a stream with an incorrect frame data sequence number" do
      header = ChunkyPNG::Chunk::Header.new(width: 2, height: 2, color: ChunkyPNG::COLOR_TRUECOLOR_ALPHA, depth: 8)
      actl = ChunkyPNG::Chunk::AnimationControl.new(num_frames: 1, num_plays: 0)
      fctl = ChunkyPNG::Chunk::FrameControl.new(sequence_number: 0, width: 2, height: 2)
      idat_content = solid_canvas(2, 2, red).to_datastream(color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA).data_chunks.first.content
      fdat = ChunkyPNG::Chunk::FrameData.new(sequence_number: 3, data: idat_content)

      blob = crafted_apng([header, actl, fctl, fdat, ChunkyPNG::Chunk::End.new])
      expect { ChunkyPNG::Animation.from_blob(blob) }.to raise_error(ChunkyPNG::ExpectationFailed, /sequence number/)
    end

    it "rejects a stream whose frame region is out of bounds" do
      header = ChunkyPNG::Chunk::Header.new(width: 2, height: 2, color: ChunkyPNG::COLOR_TRUECOLOR_ALPHA, depth: 8)
      actl = ChunkyPNG::Chunk::AnimationControl.new(num_frames: 1, num_plays: 0)
      fctl = ChunkyPNG::Chunk::FrameControl.new(sequence_number: 0, width: 2, height: 2, x_offset: 1, y_offset: 0)
      idat = solid_canvas(2, 2, red).to_datastream(color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA).data_chunks.first

      blob = crafted_apng([header, actl, fctl, idat, ChunkyPNG::Chunk::End.new])
      expect { ChunkyPNG::Animation.from_blob(blob) }.to raise_error(ChunkyPNG::OutOfBounds)
    end

    it "rejects a stream that is not an animated PNG" do
      blob = solid_canvas(2, 2, red).to_blob
      expect { ChunkyPNG::Animation.from_blob(blob) }.to raise_error(ChunkyPNG::ExpectationFailed, /not an animated PNG/)
    end

    it "rejects a stream whose frame count does not match the animation control chunk" do
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.add_frame(solid_canvas(2, 2, red))

      header = ChunkyPNG::Chunk::Header.new(width: 2, height: 2, color: ChunkyPNG::COLOR_TRUECOLOR_ALPHA, depth: 8)
      actl = ChunkyPNG::Chunk::AnimationControl.new(num_frames: 2, num_plays: 0)
      fctl = ChunkyPNG::Chunk::FrameControl.new(sequence_number: 0, width: 2, height: 2)
      idat = solid_canvas(2, 2, red).to_datastream(color_mode: ChunkyPNG::COLOR_TRUECOLOR_ALPHA).data_chunks.first

      blob = crafted_apng([header, actl, fctl, idat, ChunkyPNG::Chunk::End.new])
      expect { ChunkyPNG::Animation.from_blob(blob) }.to raise_error(ChunkyPNG::ExpectationFailed, /frames/)
    end
  end

  describe "file and IO access" do
    it "round trips through a file" do
      animation = ChunkyPNG::Animation.new(2, 2, loop_count: 2)
      animation.add_frame(solid_canvas(2, 2, red), delay_num: 1, delay_den: 4)
      animation.add_frame(solid_canvas(2, 2, blue), delay_num: 1, delay_den: 2)

      file = File.join(Dir.mktmpdir, "animation.png")
      animation.save(file)

      decoded = ChunkyPNG::Animation.from_file(file)
      expect(decoded.loop_count).to eql 2
      expect(decoded.frames.map(&:delay)).to eql [Rational(1, 4), Rational(1, 2)]
      expect(decoded.display_frames[1].pixels).to eql solid_canvas(2, 2, blue).pixels
    end
  end
end

describe ChunkyPNG::Animation::Frame do
  it "interprets a zero delay denominator as 100" do
    frame = ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(1, 1), delay_num: 5, delay_den: 0)
    expect(frame.delay).to eql Rational(5, 100)
  end

  it "accepts a delay in seconds" do
    frame = ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(1, 1), delay: Rational(1, 4))
    expect(frame.delay_num).to eql 1
    expect(frame.delay_den).to eql 4
    expect(frame.delay).to eql Rational(1, 4)
  end
end
