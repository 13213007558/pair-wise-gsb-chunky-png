# frozen-string-literal: true

require "spec_helper"

describe ChunkyPNG::Watershed do
  W = ChunkyPNG::Watershed::WATERSHED
  U = ChunkyPNG::Watershed::UNLABELED

  def segment(heights, markers, **options)
    ChunkyPNG::Watershed.segment(heights, markers, **options).labels
  end

  describe ".segment" do
    it "floods a simple gradient from both markers" do
      heights = [[1, 2, 3, 2, 1]]
      markers = [[1, 0, 0, 0, 2]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[1, 1, W, 2, 2]]
    end

    it "floods from a single marker through increasing levels" do
      heights = [[3, 2, 1], [4, 5, 6]]
      markers = [[0, 0, 1], [0, 0, 0]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[1, 1, 1], [1, 1, 1]]
    end

    it "fills the whole basin when a marker sits above its minimum" do
      heights = [[5, 4, 3, 2, 1]]
      markers = [[1, 0, 0, 0, 0]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[1, 1, 1, 1, 1]]
    end

    it "splits a plateau exactly in the middle between two markers" do
      heights = [[0, 0, 0, 0, 0]]
      markers = [[1, 0, 0, 0, 2]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[1, 1, W, 2, 2]]
    end

    it "splits a two-dimensional plateau by geodesic distance" do
      heights = Array.new(5) { Array.new(5, 0) }
      markers = Array.new(5) { Array.new(5, 0) }
      markers[0][0] = 1
      markers[4][4] = 2
      expect(segment(heights, markers, connectivity: 4)).to eq [
        [1, 1, 1, 1, W],
        [1, 1, 1, W, 2],
        [1, 1, W, 2, 2],
        [1, W, 2, 2, 2],
        [W, 2, 2, 2, 2]
      ]
    end

    it "marks the equidistant diagonal of a plateau as watershed with 8-connectivity" do
      heights = Array.new(3) { Array.new(3, 0) }
      markers = [[1, 0, 0], [0, 0, 0], [0, 0, 2]]
      expect(segment(heights, markers, connectivity: 8)).to eq [
        [1, 1, W],
        [1, W, 2],
        [W, 2, 2]
      ]
    end

    it "meets between diagonal markers on a flat plateau" do
      heights = [[0, 0], [0, 0]]
      markers = [[1, 0], [0, 2]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[1, W], [W, 2]]
      expect(segment(heights, markers, connectivity: 8)).to eq [[1, W], [W, 2]]
    end

    it "does not flood through diagonal gaps with 4-connectivity" do
      heights = [[0, 0], [0, 0]]
      markers = [[1, 0], [0, 0]]
      mask = [[true, false], [false, true]]
      expect(segment(heights, markers, connectivity: 4, mask: mask)).to eq [[1, U], [U, U]]
    end

    it "floods through diagonal gaps with 8-connectivity" do
      heights = [[0, 0], [0, 0]]
      markers = [[1, 0], [0, 0]]
      mask = [[true, false], [false, true]]
      expect(segment(heights, markers, connectivity: 8, mask: mask)).to eq [[1, U], [U, 1]]
    end

    it "keeps touching markers on their own labels" do
      heights = [[5, 5]]
      markers = [[1, 2]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[1, 2]]
    end

    it "leaves everything unlabeled when there are no markers" do
      heights = [[1, 2], [3, 4]]
      markers = [[0, 0], [0, 0]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[U, U], [U, U]]
    end

    it "leaves connected regions without a marker unlabeled" do
      heights = [[0, 0, 0, 0, 0]]
      markers = [[1, 0, 0, 0, 0]]
      mask = [[true, true, false, true, true]]
      expect(segment(heights, markers, connectivity: 4, mask: mask)).to eq [[1, 1, U, U, U]]
    end

    it "labels pixels outside the mask as unlabeled and does not flood through them" do
      heights = [[1, 1, 1]]
      markers = [[1, 0, 2]]
      mask = [[true, false, true]]
      expect(segment(heights, markers, connectivity: 4, mask: mask)).to eq [[1, U, 2]]
    end

    it "ignores markers placed outside the mask" do
      heights = [[1, 1]]
      markers = [[1, 2]]
      mask = [[true, false]]
      expect(segment(heights, markers, connectivity: 4, mask: mask)).to eq [[1, U]]
    end

    it "raises an ArgumentError for unsupported connectivity" do
      expect {
        ChunkyPNG::Watershed.segment([[1]], [[1]], connectivity: 6)
      }.to raise_error(ArgumentError)
    end

    it "raises an ExpectationFailed when the matrix dimensions do not match" do
      expect {
        ChunkyPNG::Watershed.segment([[1, 2]], [[1]])
      }.to raise_error(ChunkyPNG::ExpectationFailed)
    end

    it "raises an ExpectationFailed for ragged matrices" do
      expect {
        ChunkyPNG::Watershed.segment([[1], [2, 3]], [[1], [0, 0]])
      }.to raise_error(ChunkyPNG::ExpectationFailed)
    end

    it "raises an ExpectationFailed for negative markers" do
      expect {
        ChunkyPNG::Watershed.segment([[1]], [[-1]])
      }.to raise_error(ChunkyPNG::ExpectationFailed)
    end
  end

  describe "scan-order independence" do
    # An asymmetric height map and marker set; any scan-order bias in the
    # flooding would show up as a difference under these transformations.
    let(:heights) do
      Array.new(6) { |y| Array.new(6) { |x| (x * x + 3 * y * y + x * y + 2 * x + 5) % 7 } }
    end

    let(:markers) do
      Array.new(6) { Array.new(6, 0) }.tap do |m|
        m[0][1] = 1
        m[2][5] = 2
        m[5][3] = 3
      end
    end

    def flip_horizontal(matrix)
      matrix.map(&:reverse)
    end

    def flip_vertical(matrix)
      matrix.reverse
    end

    def rotate_180(matrix)
      matrix.reverse.map(&:reverse)
    end

    def transpose(matrix)
      matrix.transpose
    end

    [4, 8].each do |connectivity|
      context "with #{connectivity}-connectivity" do
        let(:result) do
          ChunkyPNG::Watershed.segment(heights, markers, connectivity: connectivity).labels
        end

        it "is invariant under horizontal flipping" do
          flipped = ChunkyPNG::Watershed.segment(
            flip_horizontal(heights), flip_horizontal(markers), connectivity: connectivity
          ).labels
          expect(flipped).to eq flip_horizontal(result)
        end

        it "is invariant under vertical flipping" do
          flipped = ChunkyPNG::Watershed.segment(
            flip_vertical(heights), flip_vertical(markers), connectivity: connectivity
          ).labels
          expect(flipped).to eq flip_vertical(result)
        end

        it "is invariant under 180 degree rotation" do
          rotated = ChunkyPNG::Watershed.segment(
            rotate_180(heights), rotate_180(markers), connectivity: connectivity
          ).labels
          expect(rotated).to eq rotate_180(result)
        end

        it "is invariant under transposition" do
          transposed = ChunkyPNG::Watershed.segment(
            transpose(heights), transpose(markers), connectivity: connectivity
          ).labels
          expect(transposed).to eq transpose(result)
        end
      end
    end

    it "assigns the plateau pixel equidistant from two markers to the watershed, not to the first marker" do
      # If scan order mattered, the middle pixel would be claimed by label 1.
      heights = [[0, 0, 0]]
      markers = [[1, 0, 2]]
      expect(segment(heights, markers, connectivity: 4)).to eq [[1, W, 2]]
      mirrored = ChunkyPNG::Watershed.segment(
        [[0, 0, 0]], [[2, 0, 1]], connectivity: 4
      ).labels
      expect(mirrored).to eq [[2, W, 1]]
    end
  end

  describe ChunkyPNG::Watershed::Result do
    let(:result) do
      ChunkyPNG::Watershed.segment(
        [[1, 2, 3, 2, 1]],
        [[1, 0, 0, 0, 2]],
        connectivity: 4
      )
    end

    it "exposes the dimensions of the height map" do
      expect(result.width).to eq 5
      expect(result.height).to eq 1
    end

    it "exposes per-pixel labels via #[]" do
      expect(result[0, 0]).to eq 1
      expect(result[2, 0]).to eq ChunkyPNG::Watershed::WATERSHED
      expect(result[4, 0]).to eq 2
    end

    it "marks watershed pixels as boundaries" do
      expect(result.boundaries).to eq [[false, false, true, false, false]]
    end

    it "marks both sides of touching markers as boundaries" do
      touching = ChunkyPNG::Watershed.segment([[5, 5]], [[1, 2]], connectivity: 4)
      expect(touching.boundaries).to eq [[true, true]]
    end

    it "marks an even split without watershed pixels as boundary on both sides" do
      even = ChunkyPNG::Watershed.segment([[0, 0, 0, 0]], [[1, 0, 0, 2]], connectivity: 4)
      expect(even.labels).to eq [[1, 1, 2, 2]]
      expect(even.boundaries).to eq [[false, true, true, false]]
    end

    it "renders the segmentation as an image" do
      image = result.to_image
      expect(image).to be_a(ChunkyPNG::Canvas)
      expect(image.width).to eq 5
      expect(image.height).to eq 1
      expect(image[2, 0]).to eq ChunkyPNG::Color::BLACK
      expect(image[0, 0]).not_to eq image[4, 0]
    end

    it "renders unlabeled pixels as transparent" do
      unlabeled = ChunkyPNG::Watershed.segment([[1, 1]], [[1, 0]], mask: [[true, false]])
      expect(unlabeled.to_image[1, 0]).to eq ChunkyPNG::Color::TRANSPARENT
    end

    it "allows overriding the region colors" do
      red = ChunkyPNG::Color.rgb(255, 0, 0)
      image = result.to_image(1 => red)
      expect(image[0, 0]).to eq red
    end
  end
end
