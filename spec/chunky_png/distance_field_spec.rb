# frozen_string_literal: true

require "spec_helper"

describe ChunkyPNG::DistanceField do
  describe ".signed_euclidean_distance" do
    it "computes a hand-derived field for one foreground pixel" do
      mask = [
        false, false, false,
        false, true,  false,
        false, false, false
      ]

      sqrt2 = Math.sqrt(2)
      expect(described_class.signed_euclidean_distance(mask, 3, 3)).to eql [
        -sqrt2, -1.0,   -sqrt2,
        -1.0,    1.0,   -1.0,
        -sqrt2, -1.0,   -sqrt2
      ]
    end

    it "computes a hand-derived field for a foreground rectangle" do
      mask = [
        false, false, false, false, false,
        false, true,  true,  true,  false,
        false, true,  true,  true,  false,
        false, true,  true,  true,  false,
        false, false, false, false, false
      ]

      sqrt2 = Math.sqrt(2)
      expect(described_class.signed_euclidean_distance(mask, 5, 5)).to eql [
        -sqrt2, -1.0,   -1.0,   -1.0,   -sqrt2,
        -1.0,    1.0,    1.0,    1.0,   -1.0,
        -1.0,    1.0,    2.0,    1.0,   -1.0,
        -1.0,    1.0,    1.0,    1.0,   -1.0,
        -sqrt2, -1.0,   -1.0,   -1.0,   -sqrt2
      ]
    end

    it "treats the image exterior as infinite background" do
      expect(described_class.signed_euclidean_distance([true], 1, 1)).to eql [1.0]
      expect(described_class.signed_euclidean_distance([true, true], 1, 2)).to eql [1.0, 1.0]
      expect(described_class.signed_euclidean_distance([true, true], 2, 1)).to eql [1.0, 1.0]
      expect(described_class.signed_euclidean_distance([true] * 6, 2, 3)).to eql [
        1.0, 1.0,
        1.0, 1.0,
        1.0, 1.0
      ]
    end

    it "returns negative infinity for an all-background mask" do
      expect(described_class.signed_euclidean_distance([false] * 4, 2, 2)).to eql [
        -Float::INFINITY, -Float::INFINITY,
        -Float::INFINITY, -Float::INFINITY
      ]
    end

    it "matches exhaustive nearest-pixel computation on random masks" do
      random = Random.new(0x4e756d62)

      100.times do
        width = random.rand(1..7)
        height = random.rand(1..7)
        mask = Array.new(width * height) { random.rand(2) == 1 }

        expect(described_class.signed_euclidean_distance(mask, width, height)).to(
          eql(brute_force_signed_distance(mask, width, height))
        )
      end
    end

    it "rejects a mask whose size does not match its dimensions" do
      expect { described_class.signed_euclidean_distance([false, true], 2, 2) }.to(
        raise_error(ArgumentError)
      )
    end
  end

  def brute_force_signed_distance(mask, width, height)
    foreground = mask.each_index.select { |index| mask[index] }
    exterior = exterior_pixel_centers(width, height)
    background = mask.each_index.reject { |index| mask[index] }
    foreground_targets = exterior + background

    Array.new(width * height) do |index|
      x = index % width
      y = index.div(width)

      if mask[index]
        Math.sqrt(distance_squared(x, y, foreground_targets, width))
      elsif foreground.empty?
        -Float::INFINITY
      else
        -Math.sqrt(distance_squared(x, y, foreground, width))
      end
    end
  end

  def exterior_pixel_centers(width, height)
    pixels = []
    (-1..height).each { |y| pixels << [-1, y] << [width, y] }
    (0...width).each { |x| pixels << [x, -1] << [x, height] }
    pixels.uniq
  end

  def distance_squared(x, y, target_indices, width)
    target_indices.map do |target|
      target_x, target_y = target.is_a?(Array) ? target : [target % width, target.div(width)]

      (x - target_x) ** 2 + (y - target_y) ** 2
    end.min
  end
end
