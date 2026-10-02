require "spec_helper"

describe ChunkyPNG::Canvas::DistanceTransform do
  describe "#signed_distance_field" do
    it "should threshold the alpha channel and compute signed distances" do
      canvas = ChunkyPNG::Canvas.new(3, 1, ChunkyPNG::Color::TRANSPARENT)
      canvas[1, 0] = ChunkyPNG::Color::WHITE # fully opaque

      expect(canvas.signed_distance_field).to eql [-1.0, 1.0, -1.0]
    end

    it "should treat pixels with alpha equal to the threshold as foreground" do
      canvas = ChunkyPNG::Canvas.new(3, 1, ChunkyPNG::Color::TRANSPARENT)
      canvas[0, 0] = ChunkyPNG::Color.rgba(0, 0, 0, 127)
      canvas[1, 0] = ChunkyPNG::Color.rgba(0, 0, 0, 128)
      canvas[2, 0] = ChunkyPNG::Color.rgba(0, 0, 0, 129)

      expect(canvas.signed_distance_field(128)).to eql [-1.0, 1.0, 2.0]
      expect(canvas.signed_distance_field(129)).to eql [-2.0, -1.0, 1.0]
    end

    it "should use 128 as the default threshold" do
      canvas = ChunkyPNG::Canvas.new(2, 1, ChunkyPNG::Color::TRANSPARENT)
      canvas[1, 0] = ChunkyPNG::Color.rgba(0, 0, 0, 128)

      expect(canvas.signed_distance_field).to eql canvas.signed_distance_field(128)
    end

    it "should share its conventions with ChunkyPNG::DistanceTransform" do
      canvas = ChunkyPNG::Canvas.new(4, 3, ChunkyPNG::Color::TRANSPARENT)
      canvas[1, 1] = ChunkyPNG::Color::WHITE
      canvas[2, 1] = ChunkyPNG::Color::WHITE

      mask = canvas.pixels.map { |pixel| ChunkyPNG::Color.a(pixel) >= 128 }
      expect(canvas.signed_distance_field)
        .to eql ChunkyPNG::DistanceTransform.signed_distance_field(mask, 4, 3)
    end

    it "should return negative infinity for a fully transparent canvas" do
      canvas = ChunkyPNG::Canvas.new(2, 2, ChunkyPNG::Color::TRANSPARENT)
      expect(canvas.signed_distance_field).to eql [-Float::INFINITY] * 4
    end

    it "should return positive infinity for a fully opaque canvas" do
      canvas = ChunkyPNG::Canvas.new(2, 2, ChunkyPNG::Color::WHITE)
      expect(canvas.signed_distance_field).to eql [Float::INFINITY] * 4
    end
  end
end
