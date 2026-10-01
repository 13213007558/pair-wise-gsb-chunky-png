# frozen_string_literal: true

require "spec_helper"

module AnimationSpecHelpers
  # Builds a small 2x2 animation that exercises all frame operations:
  # frame 0 places an opaque red pixel in the top-left corner,
  # frame 1 alpha-composites a semi-transparent green pixel over the top-right,
  # frame 2 paints a semi-transparent red pixel in the bottom-left and is
  #   restored (DISPOSE_OP_PREVIOUS),
  # frame 3 alpha-composites a semi-transparent blue pixel in the bottom-right
  #   and clears it afterwards (DISPOSE_OP_BACKGROUND).
  def build_test_animation
    animation = ChunkyPNG::Animation.new(2, 2, plays: 7)
    animation.add_frame(
      ChunkyPNG::Canvas.new(1, 1, [ChunkyPNG::Color.rgba(255, 0, 0, 255)]),
      dispose_op: ChunkyPNG::DISPOSE_OP_NONE,
      blend_op: ChunkyPNG::BLEND_OP_SOURCE,
      delay: Rational(3, 2),
    )
    animation.add_frame(
      ChunkyPNG::Canvas.new(1, 1, [ChunkyPNG::Color.rgba(0, 255, 0, 128)]),
      x_offset: 1, y_offset: 0,
      dispose_op: ChunkyPNG::DISPOSE_OP_NONE,
      blend_op: ChunkyPNG::BLEND_OP_OVER,
      delay: Rational(1, 10),
    )
    animation.add_frame(
      ChunkyPNG::Canvas.new(1, 1, [ChunkyPNG::Color.rgba(255, 0, 0, 128)]),
      x_offset: 0, y_offset: 1,
      dispose_op: ChunkyPNG::DISPOSE_OP_PREVIOUS,
      blend_op: ChunkyPNG::BLEND_OP_OVER,
      delay: Rational(7, 100),
    )
    animation.add_frame(
      ChunkyPNG::Canvas.new(1, 1, [ChunkyPNG::Color.rgba(0, 0, 255, 200)]),
      x_offset: 1, y_offset: 1,
      dispose_op: ChunkyPNG::DISPOSE_OP_BACKGROUND,
      blend_op: ChunkyPNG::BLEND_OP_OVER,
      delay_num: 5, delay_den: 0,
    )
    animation
  end

  # Expected composited pixels for build_test_animation, ordered as the
  # canvas pixel array (x + y * width). Values are derived from
  # Porter-Duff source-over compositing.
  def expected_composited_pixels
    transparent = ChunkyPNG::Color::TRANSPARENT
    red         = ChunkyPNG::Color.rgba(255, 0, 0, 255)
    green_over  = ChunkyPNG::Color.compose(ChunkyPNG::Color.rgba(0, 255, 0, 128), transparent)
    red_bottom  = ChunkyPNG::Color.compose(ChunkyPNG::Color.rgba(255, 0, 0, 128), transparent)
    blue_bottom = ChunkyPNG::Color.compose(ChunkyPNG::Color.rgba(0, 0, 255, 200), transparent)
    [
      [red, transparent, transparent, transparent],
      [red, green_over, transparent, transparent],
      [red, green_over, red_bottom, transparent],
      [red, green_over, transparent, blue_bottom],
    ]
  end
end

RSpec.describe ChunkyPNG::Animation do
  include AnimationSpecHelpers

  describe "in memory" do
    it "exposes raw frame rectangles, timing and the loop count" do
      animation = build_test_animation
      expect(animation.frame_count).to eql(4)
      expect(animation.plays).to eql(7)

      expect(animation.frame_canvas(0).pixels).to eql([ChunkyPNG::Color.rgba(255, 0, 0, 255)])
      expect(animation.frames[1].x_offset).to eql(1)
      expect(animation.frames[2].y_offset).to eql(1)
      expect(animation.frames.map(&:delay)).to eql([Rational(3, 2), Rational(1, 10), Rational(7, 100), Rational(1, 20)])
    end

    it "composites frames following blend and dispose rules" do
      animation = build_test_animation
      expected_composited_pixels.each_with_index do |expected_pixels, index|
        expect(animation.composited_frame(index).pixels).to eql(expected_pixels)
      end
    end

    it "handles DISPOSE_OP_PREVIOUS restoration scoped to the frame rectangle" do
      animation = build_test_animation
      # Frame 3 is rendered after frame 2 was disposed with PREVIOUS, so
      # the bottom-left pixel must be transparent again, while the red
      # and green pixels of earlier frames are untouched.
      pixels = animation.composited_frame(3).pixels
      expect(pixels[2]).to eql(ChunkyPNG::Color::TRANSPARENT)
      expect(pixels[0]).to eql(ChunkyPNG::Color.rgba(255, 0, 0, 255))
    end

    it "treats the first frame as starting on a transparent output buffer" do
      animation = ChunkyPNG::Animation.new(1, 1)
      animation.add_frame(
        ChunkyPNG::Canvas.new(1, 1, [ChunkyPNG::Color.rgba(0, 255, 0, 128)]),
        dispose_op: ChunkyPNG::DISPOSE_OP_BACKGROUND,
        blend_op: ChunkyPNG::BLEND_OP_OVER,
      )
      composited = animation.composited_frame(0)
      expect(composited.pixels).to eql([ChunkyPNG::Color.compose(ChunkyPNG::Color.rgba(0, 255, 0, 128), ChunkyPNG::Color::TRANSPARENT)])
    end
  end

  describe "encoding and decoding" do
    let(:animation) { build_test_animation }
    let(:blob) { animation.to_blob(:fast_rgba) }
    let(:datastream) { ChunkyPNG::Datastream.from_blob(blob) }
    let(:decoded) { ChunkyPNG::Animation.from_blob(blob) }

    it "writes the acTL and fcTL chunks in the correct order" do
      types = datastream.chunks.map(&:type)
      expect(types.index("acTL")).to be < types.index("IDAT")
      expect(types.count("fcTL")).to eql(4)
      expect(types.count("fdAT")) .to eql(3)
      expect(types.first).to eql("IHDR")
      expect(types.last).to eql("IEND")
      expect(datastream.animation_control_chunk.num_frames).to eql(4)
      expect(datastream.animation_control_chunk.num_plays).to eql(7)
    end

    it "assigns consecutive sequence numbers to fcTL and fdAT chunks" do
      fctl = datastream.frame_control_chunks
      expect(fctl.map(&:sequence_number)).to eql([0, 1, 3, 5])
      expect(datastream.frame_data_chunks[0].map(&:sequence_number)).to eql([2])
      expect(datastream.frame_data_chunks[1].map(&:sequence_number)).to eql([4])
      expect(datastream.frame_data_chunks[2].map(&:sequence_number)).to eql([6])
    end

    it "is detected as an animation and preserves frame metadata" do
      expect(datastream).to be_animated
      expect(decoded.frame_count).to eql(4)
      expect(decoded.plays).to eql(7)

      controls = datastream.frame_control_chunks
      expect(controls.map { |c| [c.x_offset, c.y_offset, c.width, c.height] }).to eql([
        [0, 0, 1, 1], [1, 0, 1, 1], [0, 1, 1, 1], [1, 1, 1, 1],
      ])
      expect(controls.map { |c| [c.delay_num, c.delay_den] }).to eql([
        [3, 2], [1, 10], [7, 100], [5, 0],
      ])
      # A zero denominator is preserved in the chunk but reported as 1/20 s.
      expect(controls.last.delay).to eql(Rational(1, 20))
      expect(controls.map(&:dispose_op)).to eql([0, 0, 2, 1])
      expect(controls.map(&:blend_op)).to eql([0, 1, 1, 1])
    end

    it "reads back every raw frame rectangle unchanged" do
      original = animation
      decoded.frames.each_with_index do |frame, index|
        source = original.frames[index]
        expect(frame.width).to eql(source.width)
        expect(frame.height).to eql(source.height)
        expect(frame.x_offset).to eql(source.x_offset)
        expect(frame.y_offset).to eql(source.y_offset)
        expect(frame.canvas.pixels).to eql(source.canvas.pixels)
      end
    end

    it "reads back every composited frame unchanged" do
      expected_composited_pixels.each_with_index do |expected_pixels, index|
        expect(decoded.composited_frame(index).pixels).to eql(expected_pixels)
      end
    end

    it "survives a second round trip" do
      twice = ChunkyPNG::Animation.from_blob(decoded.to_blob(:fast_rgba))
      expect(twice.frames.map { |f| [f.x_offset, f.y_offset, f.width, f.height, f.delay_num, f.delay_den, f.dispose_op, f.blend_op] }).to eql(
        decoded.frames.map { |f| [f.x_offset, f.y_offset, f.width, f.height, f.delay_num, f.delay_den, f.dispose_op, f.blend_op] }
      )
      twice.frames.each_with_index do |frame, index|
        expect(frame.canvas.pixels).to eql(decoded.frames[index].canvas.pixels)
      end
    end

    it "can encode frames covering the full canvas as well as sub-rectangles" do
      animation = ChunkyPNG::Animation.new(2, 1, plays: 0)
      animation.add_frame(ChunkyPNG::Canvas.new(2, 1, [1, 2]), blend_op: ChunkyPNG::BLEND_OP_SOURCE)
      blob = animation.to_blob(:fast_rgba)
      decoded = ChunkyPNG::Animation.from_blob(blob)
      expect(decoded.plays).to eql(0)
      expect(decoded.frame_canvas(0).pixels).to eql([1, 2])
      expect(decoded.composited_frame(0).pixels).to eql([1, 2])
    end
  end

  describe "plain PNG compatibility" do
    it "keeps datastreams without an acTL chunk non-animated" do
      canvas = reference_canvas("pixelstream_reference")
      datastream = canvas.to_datastream
      expect(datastream).not_to be_animated
      expect(datastream.frame_control_chunks).to be_empty
      expect(ChunkyPNG::Canvas.from_blob(canvas.to_blob).pixels).to eql(canvas.pixels)
    end

    it "decodes the default image of an APNG as a regular canvas" do
      animation = build_test_animation
      canvas = ChunkyPNG::Canvas.from_blob(animation.to_blob(:fast_rgba))
      expect(canvas.width).to eql(2)
      expect(canvas.height).to eql(2)
      expect(canvas.pixels).to eql(animation.composited_frame(0).pixels)
    end
  end

  describe "malformed control chunks" do
    it "reports which frame has an fcTL chunk of the wrong length" do
      animation = build_test_animation
      datastream = animation.to_datastream(:fast_rgba)
      bad_chunk = ChunkyPNG::Chunk::Generic.new("fcTL", "x" * 27)
      bad_io = StringIO.new
      bad_chunk.write(bad_io)

      chunks = datastream.chunks.to_a
      second_fctl_index = chunks.each_index.select { |index| chunks[index].type == "fcTL" }[1]
      chunks[second_fctl_index] = bad_chunk
      corrupted_io = StringIO.new
      corrupted_io << ChunkyPNG::Datastream::SIGNATURE
      chunks.each { |chunk| chunk.write(corrupted_io) }
      corrupted = corrupted_io.string
      expect {
        ChunkyPNG::Datastream.from_blob(corrupted)
      }.to raise_error(ChunkyPNG::ExpectationFailed, /frame 1.*26 bytes/m)
    end

    it "reports which frame has a region outside the viewport" do
      animation = build_test_animation
      datastream = animation.to_datastream(:fast_rgba)
      datastream.frame_control_chunks[2].width = 5
      expect {
        ChunkyPNG::Datastream.from_blob(datastream.to_blob)
      }.to raise_error(ChunkyPNG::ExpectationFailed, /frame 2/)
    end

    it "reports which frame has an invalid dispose operation" do
      animation = build_test_animation
      datastream = animation.to_datastream(:fast_rgba)
      datastream.frame_control_chunks[3].dispose_op = 9
      expect {
        ChunkyPNG::Datastream.from_blob(datastream.to_blob)
      }.to raise_error(ChunkyPNG::ExpectationFailed, /frame 3.*dispose/m)
    end

    it "reports which frame breaks the sequence numbering" do
      animation = build_test_animation
      datastream = animation.to_datastream(:fast_rgba)
      datastream.frame_control_chunks[1].sequence_number = 9
      expect {
        ChunkyPNG::Datastream.from_blob(datastream.to_blob)
      }.to raise_error(ChunkyPNG::ExpectationFailed, /frame 1.*sequence/m)
    end
  end
end
