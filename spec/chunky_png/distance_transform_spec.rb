require "spec_helper"

describe ChunkyPNG::DistanceTransform do
  def mask_from_rows(rows)
    rows.flatten
  end

  # Reference implementation: for every pixel, scan all pixels of the
  # opposite class and take the distance to the closest one.
  def brute_force_signed_distance_field(mask, width, height)
    foreground = []
    background = []
    mask.each_with_index do |value, i|
      (value ? foreground : background) << [i % width, i / width]
    end

    mask.each_with_index.map do |is_foreground, i|
      x = i % width
      y = i / width
      targets = is_foreground ? background : foreground
      if targets.empty?
        is_foreground ? Float::INFINITY : -Float::INFINITY
      else
        squared = targets.map { |tx, ty| (tx - x)**2 + (ty - y)**2 }.min
        is_foreground ? Math.sqrt(squared) : -Math.sqrt(squared)
      end
    end
  end

  describe ".signed_distance_field" do
    it "should compute hand-calculated distances for a single foreground pixel" do
      mask = mask_from_rows([
        [false, false, false, false, false],
        [false, false, false, false, false],
        [false, false, true, false, false],
        [false, false, false, false, false],
        [false, false, false, false, false]
      ])

      r2 = Math.sqrt(2)
      r5 = Math.sqrt(5)
      r8 = Math.sqrt(8)
      expected = [
        -r8, -r5, -2.0, -r5, -r8,
        -r5, -r2, -1.0, -r2, -r5,
        -2.0, -1.0, 1.0, -1.0, -2.0,
        -r5, -r2, -1.0, -r2, -r5,
        -r8, -r5, -2.0, -r5, -r8
      ]

      expect(described_class.signed_distance_field(mask, 5, 5)).to eql expected
    end

    it "should compute hand-calculated distances for a filled rectangle" do
      mask = mask_from_rows([
        [false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false],
        [false, false, true, true, true, false, false],
        [false, false, true, true, true, false, false],
        [false, false, true, true, true, false, false],
        [false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false]
      ])

      r2 = Math.sqrt(2)
      r5 = Math.sqrt(5)
      r8 = Math.sqrt(8)
      expected = [
        -r8, -r5, -2.0, -2.0, -2.0, -r5, -r8,
        -r5, -r2, -1.0, -1.0, -1.0, -r2, -r5,
        -2.0, -1.0, 1.0, 1.0, 1.0, -1.0, -2.0,
        -2.0, -1.0, 1.0, 2.0, 1.0, -1.0, -2.0,
        -2.0, -1.0, 1.0, 1.0, 1.0, -1.0, -2.0,
        -r5, -r2, -1.0, -1.0, -1.0, -r2, -r5,
        -r8, -r5, -2.0, -2.0, -2.0, -r5, -r8
      ]

      expect(described_class.signed_distance_field(mask, 7, 7)).to eql expected
    end

    it "should measure distances between pixel centers" do
      mask = [true, false]
      expect(described_class.signed_distance_field(mask, 2, 1)).to eql [1.0, -1.0]
    end

    it "should return negative infinity for every pixel of an all-background mask" do
      mask = [false] * 6
      expect(described_class.signed_distance_field(mask, 3, 2)).to eql([-Float::INFINITY] * 6)
    end

    it "should return positive infinity for every pixel of an all-foreground mask" do
      mask = [true] * 6
      expect(described_class.signed_distance_field(mask, 3, 2)).to eql([Float::INFINITY] * 6)
    end

    it "should not treat the region outside the image as background" do
      mask = mask_from_rows([
        [true, true, false],
        [true, true, false]
      ])
      # The foreground pixels on the left edge only measure distances to
      # background pixels inside the image, never to the out-of-image area.
      expect(described_class.signed_distance_field(mask, 3, 2)).to eql [
        2.0, 1.0, -1.0,
        2.0, 1.0, -1.0
      ]
    end

    it "should handle a 1x1 foreground mask" do
      expect(described_class.signed_distance_field([true], 1, 1)).to eql [Float::INFINITY]
    end

    it "should handle a 1x1 background mask" do
      expect(described_class.signed_distance_field([false], 1, 1)).to eql [-Float::INFINITY]
    end

    it "should handle single-row and single-column masks" do
      expect(described_class.signed_distance_field([false, true, false], 3, 1)).to eql [-1.0, 1.0, -1.0]
      expect(described_class.signed_distance_field([false, true, false], 1, 3)).to eql [-1.0, 1.0, -1.0]
    end

    it "should raise an ArgumentError when the mask size does not match the dimensions" do
      expect { described_class.signed_distance_field([true, false], 2, 2) }
        .to raise_error(ArgumentError, /2 pixels.*2 x 2/)
    end

    it "should match a brute-force nearest-opposite-pixel search on random masks" do
      rng = Random.new(20160816)
      sizes = [[1, 1], [2, 3], [5, 5], [8, 4], [17, 11], [32, 24]]
      densities = [0.1, 0.5, 0.9]

      sizes.each do |width, height|
        densities.each do |density|
          mask = Array.new(width * height) { rng.rand < density }
          expected = brute_force_signed_distance_field(mask, width, height)
          expect(described_class.signed_distance_field(mask, width, height)).to eql(expected),
            "expected matching distances for a #{width}x#{height} mask with density #{density}"
        end
      end
    end
  end
end
