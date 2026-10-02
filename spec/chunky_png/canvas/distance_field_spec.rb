# frozen_string_literal: true

require "spec_helper"

describe ChunkyPNG::Canvas::DistanceField do
  describe "#signed_euclidean_distance_field" do
    it "thresholds alpha values inclusively" do
      canvas = ChunkyPNG::Canvas.new(3, 1, [
        ChunkyPNG::Color.rgba(0, 0, 0, 0),
        ChunkyPNG::Color.rgba(0, 0, 0, 127),
        ChunkyPNG::Color.rgba(0, 0, 0, 128)
      ])

      expect(canvas.signed_euclidean_distance_field).to eql [
        -2.0, -1.0, 1.0
      ]
    end

    it "accepts a custom inclusive alpha threshold" do
      canvas = ChunkyPNG::Canvas.new(2, 1, [
        ChunkyPNG::Color.rgba(0, 0, 0, 39),
        ChunkyPNG::Color.rgba(0, 0, 0, 40)
      ])

      expect(canvas.signed_euclidean_distance_field(40)).to eql [-1.0, 1.0]
    end

    it "provides the signed distance on the canvas directly" do
      canvas = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(0, 0, 0, 255))
      expect(canvas.signed_euclidean_distance).to eql [1.0]
    end

    it "rejects thresholds outside the alpha channel range" do
      canvas = ChunkyPNG::Canvas.new(1, 1)
      expect { canvas.signed_euclidean_distance_field(-1) }.to raise_error(ArgumentError)
      expect { canvas.signed_euclidean_distance_field(256) }.to raise_error(ArgumentError)
    end
  end
end
