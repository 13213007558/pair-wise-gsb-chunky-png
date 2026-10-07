# frozen-string-literal: true

require "spec_helper"

describe ChunkyPNG::Animation do

  let(:red)   { ChunkyPNG::Color.rgb(255, 0, 0) }
  let(:green) { ChunkyPNG::Color.rgb(0, 255, 0) }
  let(:blue)  { ChunkyPNG::Color.rgb(0, 0, 255) }

  # Builds an animation of three partially overlapping frames on a 10x10
  # canvas:
  #
  # 1. a full-canvas red frame;
  # 2. a 4x4 green square at (2, 3), disposed to the background afterwards;
  # 3. a 3x3 blue square at (5, 5).
  def three_frame_animation
    animation = ChunkyPNG::Animation.new(10, 10, num_plays: 3)
    animation.frames << ChunkyPNG::Animation::Frame.new(
      ChunkyPNG::Canvas.new(10, 10, red),
      delay_num: 1, delay_den: 2
    )
    animation.frames << ChunkyPNG::Animation::Frame.new(
      ChunkyPNG::Canvas.new(4, 4, green),
      x_offset: 2, y_offset: 3, delay_num: 1, delay_den: 4,
      dispose_op: ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND
    )
    animation.frames << ChunkyPNG::Animation::Frame.new(
      ChunkyPNG::Canvas.new(3, 3, blue),
      x_offset: 5, y_offset: 5, delay_num: 250, delay_den: 1000
    )
    animation
  end

  describe "round trip" do
    let(:blob)     { three_frame_animation.to_blob }
    let(:animation) { ChunkyPNG::Animation.from_blob(blob) }

    it "preserves the canvas size and loop count" do
      expect(animation.width).to eql 10
      expect(animation.height).to eql 10
      expect(animation.num_plays).to eql 3
    end

    it "preserves the number of frames" do
      expect(animation.frame_count).to eql 3
    end

    it "preserves the frame rectangles" do
      rects = animation.frames.map { |f| [f.x_offset, f.y_offset, f.width, f.height] }
      expect(rects).to eql [[0, 0, 10, 10], [2, 3, 4, 4], [5, 5, 3, 3]]
    end

    it "preserves the frame delays" do
      expect(animation.frames.map(&:delay)).to eql [(1/2r), (1/4r), (1/4r)]
      expect(animation.frames.map(&:delay_num)).to eql [1, 1, 250]
      expect(animation.frames.map(&:delay_den)).to eql [2, 4, 1000]
    end

    it "preserves the dispose and blend operations" do
      expect(animation.frames.map(&:dispose_op)).to eql [
        ChunkyPNG::APNG_DISPOSE_OP_NONE,
        ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND,
        ChunkyPNG::APNG_DISPOSE_OP_NONE,
      ]
      expect(animation.frames.map(&:blend_op)).to eql [
        ChunkyPNG::APNG_BLEND_OP_SOURCE,
        ChunkyPNG::APNG_BLEND_OP_SOURCE,
        ChunkyPNG::APNG_BLEND_OP_SOURCE,
      ]
    end

    it "renders the first frame as the full red canvas" do
      canvas = animation.frame_canvas(0)
      expect(canvas.width).to eql 10
      expect(canvas.height).to eql 10
      expect(canvas.pixels.uniq).to eql [red]
    end

    it "renders the second frame with the green square on the red canvas" do
      canvas = animation.frame_canvas(1)
      expect(canvas[2, 3]).to eql green
      expect(canvas[5, 6]).to eql green
      expect(canvas[0, 0]).to eql red
      expect(canvas[6, 3]).to eql red
      expect(canvas[2, 7]).to eql red
    end

    it "renders the third frame with the disposed region cleared and the blue square" do
      canvas = animation.frame_canvas(2)
      expect(canvas[2, 3]).to eql ChunkyPNG::Color::TRANSPARENT
      expect(canvas[5, 5]).to eql blue
      expect(canvas[7, 7]).to eql blue
      expect(canvas[0, 0]).to eql red
      expect(canvas[9, 9]).to eql red
    end

    it "renders the same canvases through frame_canvases" do
      canvases = animation.frame_canvases
      expect(canvases.length).to eql 3
      canvases.each_with_index do |canvas, index|
        expect(canvas).to eql animation.frame_canvas(index)
      end
    end

    it "writes the chunks in the order dictated by the APNG specification" do
      types = ChunkyPNG::Datastream.from_blob(blob).chunks.map(&:type)
      expect(types).to eql %w[IHDR acTL fcTL IDAT fcTL fdAT fcTL fdAT IEND]
    end

    it "keeps the default image readable as a regular PNG" do
      canvas = ChunkyPNG::Canvas.from_blob(blob)
      expect(canvas.pixels.uniq).to eql [red]
    end
  end

  describe "dispose operations" do
    it "restores the region from before the frame for APNG_DISPOSE_OP_PREVIOUS" do
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.frames << ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(2, 2, ChunkyPNG::Color::WHITE))
      animation.frames << ChunkyPNG::Animation::Frame.new(
        ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color::BLACK),
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS
      )
      animation.frames << ChunkyPNG::Animation::Frame.new(
        ChunkyPNG::Canvas.new(1, 1, red), x_offset: 1, y_offset: 1
      )

      canvases = ChunkyPNG::Animation.from_blob(animation.to_blob).frame_canvases
      expect(canvases[1][0, 0]).to eql ChunkyPNG::Color::BLACK
      # The region of the second frame is reverted to its contents from
      # before that frame was rendered, i.e. white instead of black.
      expect(canvases[2][0, 0]).to eql ChunkyPNG::Color::WHITE
      expect(canvases[2][1, 1]).to eql red
    end

    it "clears the region for APNG_DISPOSE_OP_BACKGROUND" do
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.frames << ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(2, 2, red))
      animation.frames << ChunkyPNG::Animation::Frame.new(
        ChunkyPNG::Canvas.new(1, 1, green),
        dispose_op: ChunkyPNG::APNG_DISPOSE_OP_BACKGROUND
      )
      animation.frames << ChunkyPNG::Animation::Frame.new(
        ChunkyPNG::Canvas.new(1, 1, blue), x_offset: 1, y_offset: 1
      )

      canvases = ChunkyPNG::Animation.from_blob(animation.to_blob).frame_canvases
      expect(canvases[2][0, 0]).to eql ChunkyPNG::Color::TRANSPARENT
      expect(canvases[2][1, 1]).to eql blue
    end
  end

  describe "blend operations" do
    it "replaces the region for APNG_BLEND_OP_SOURCE" do
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.frames << ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(2, 2, red))
      animation.frames << ChunkyPNG::Animation::Frame.new(
        ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(0, 255, 0, 128))
      )

      canvas = ChunkyPNG::Animation.from_blob(animation.to_blob).frame_canvas(1)
      expect(canvas[0, 0]).to eql ChunkyPNG::Color.rgba(0, 255, 0, 128)
    end

    it "alpha-composites the region for APNG_BLEND_OP_OVER" do
      semi_green = ChunkyPNG::Color.rgba(0, 255, 0, 128)
      animation = ChunkyPNG::Animation.new(2, 2)
      animation.frames << ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(2, 2, red))
      animation.frames << ChunkyPNG::Animation::Frame.new(
        ChunkyPNG::Canvas.new(1, 1, semi_green),
        blend_op: ChunkyPNG::APNG_BLEND_OP_OVER
      )

      canvas = ChunkyPNG::Animation.from_blob(animation.to_blob).frame_canvas(1)
      expect(canvas[0, 0]).to eql ChunkyPNG::Color.compose(semi_green, red)
      expect(canvas[1, 1]).to eql red
    end
  end

  describe "default image" do
    let(:animation) do
      animation = ChunkyPNG::Animation.new(4, 4, num_plays: 1,
        default_image: ChunkyPNG::Canvas.new(4, 4, ChunkyPNG::Color.rgb(255, 255, 0)))
      animation.frames << ChunkyPNG::Animation::Frame.new(
        ChunkyPNG::Canvas.new(2, 2, red), x_offset: 1, y_offset: 1
      )
      animation
    end

    it "stores the default image in the IDAT chunks and the frames in fdAT chunks" do
      types = ChunkyPNG::Datastream.from_blob(animation.to_blob).chunks.map(&:type)
      expect(types).to eql %w[IHDR acTL IDAT fcTL fdAT IEND]
    end

    it "round-trips the default image separately from the animation frames" do
      loaded = ChunkyPNG::Animation.from_blob(animation.to_blob)
      expect(loaded.default_image).to_not be_nil
      expect(loaded.default_image.pixels.uniq).to eql [ChunkyPNG::Color.rgb(255, 255, 0)]
      expect(loaded.frame_count).to eql 1
    end

    it "does not use the default image when rendering the frames" do
      canvas = ChunkyPNG::Animation.from_blob(animation.to_blob).frame_canvas(0)
      expect(canvas[0, 0]).to eql ChunkyPNG::Color::TRANSPARENT
      expect(canvas[1, 1]).to eql red
    end

    it "shows the default image to decoders without animation support" do
      canvas = ChunkyPNG::Canvas.from_blob(animation.to_blob)
      expect(canvas.pixels.uniq).to eql [ChunkyPNG::Color.rgb(255, 255, 0)]
    end

    it "requires the default image to match the animation dimensions" do
      animation.default_image = ChunkyPNG::Canvas.new(2, 2)
      expect { animation.to_blob }.to raise_error(ChunkyPNG::ExpectationFailed)
    end
  end

  describe "frame access" do
    let(:animation) { ChunkyPNG::Animation.from_blob(three_frame_animation.to_blob) }

    it "raises an OutOfBounds error for a negative frame index" do
      expect { animation.frame_canvas(-1) }.to raise_error(ChunkyPNG::OutOfBounds)
    end

    it "raises an OutOfBounds error for a frame index beyond the last frame" do
      expect { animation.frame_canvas(3) }.to raise_error(ChunkyPNG::OutOfBounds)
      expect { animation.frame_canvas(100) }.to raise_error(ChunkyPNG::OutOfBounds)
    end
  end

  describe "invalid input" do
    it "refuses to load a regular PNG as an animation" do
      blob = ChunkyPNG::Canvas.new(1, 1).to_blob
      expect { ChunkyPNG::Animation.from_blob(blob) }.to raise_error(ChunkyPNG::ExpectationFailed)
    end

    it "refuses to encode an animation without frames" do
      expect { ChunkyPNG::Animation.new(4, 4).to_blob }.to raise_error(ChunkyPNG::ExpectationFailed)
    end

    it "refuses to encode a first frame that does not cover the canvas without a default image" do
      animation = ChunkyPNG::Animation.new(4, 4)
      animation.frames << ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(2, 2), x_offset: 1, y_offset: 1)
      expect { animation.to_blob }.to raise_error(ChunkyPNG::ExpectationFailed)
    end

    it "refuses to encode frames that do not fit on the canvas" do
      animation = ChunkyPNG::Animation.new(4, 4)
      animation.frames << ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(4, 4))
      animation.frames << ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(2, 2), x_offset: 3, y_offset: 3)
      expect { animation.to_blob }.to raise_error(ChunkyPNG::OutOfBounds)
    end
  end

  describe ChunkyPNG::Animation::Frame do
    it "calculates the delay in seconds" do
      frame = ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(1, 1), delay_num: 1, delay_den: 4)
      expect(frame.delay).to eql 1/4r
    end

    it "treats a delay denominator of 0 as 100" do
      frame = ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(1, 1), delay_num: 1, delay_den: 0)
      expect(frame.delay).to eql 1/100r
    end

    it "sets the delay in seconds" do
      frame = ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(1, 1))
      frame.delay = 0.25
      expect(frame.delay).to eql 1/4r
    end

    it "returns the dimensions of its canvas" do
      frame = ChunkyPNG::Animation::Frame.new(ChunkyPNG::Canvas.new(3, 5))
      expect(frame.width).to eql 3
      expect(frame.height).to eql 5
    end
  end
end
