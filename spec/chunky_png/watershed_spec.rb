require "spec_helper"

describe ChunkyPNG::Watershed do
  def grid(height, width, value = 0)
    Array.new(height) { Array.new(width, value) }
  end

  def markers_from(points, height, width)
    markers = grid(height, width, 0)
    points.each do |(x, y), label|
      markers[y][x] = label
    end
    markers
  end

  describe ".segment" do
    it "raises for an unsupported connectivity" do
      expect { described_class.segment([[0]], [[1]], connectivity: 6) }
        .to raise_error(ArgumentError, /connectivity/)
    end

    it "raises for empty or ragged height maps" do
      expect { described_class.segment([], [], connectivity: 8) }
        .to raise_error(ArgumentError, /at least one row/)
      expect { described_class.segment([[0], [0, 0]], [[1], [0, 0]], connectivity: 8) }
        .to raise_error(ArgumentError, /same length/)
    end

    it "raises when markers or mask have different dimensions" do
      expect { described_class.segment([[0, 0]], [[0]], connectivity: 8) }
        .to raise_error(ArgumentError, /same dimensions/)
      expect do
        described_class.segment([[0, 0]], [[0, 0]], connectivity: 8, mask: [[true]])
      end.to raise_error(ArgumentError, /same dimensions/)
    end

    it "raises for marker labels that are not positive integers" do
      expect { described_class.segment([[0]], [[-1]], connectivity: 8) }
        .to raise_error(ArgumentError, /positive integers/)
      expect { described_class.segment([[0]], [[1.5]], connectivity: 8) }
        .to raise_error(ArgumentError, /positive integers/)
    end

    it "floods a valley from both markers and dams the unmarked pit" do
      heights = [[4, 3, 2, 3, 4]]
      markers = [[1, 0, 0, 0, 2]]
      result = described_class.segment(heights, markers, connectivity: 4)
      expect(result.labels).to eq [[1, 1, 0, 2, 2]]
    end

    it "splits a plateau instead of letting the first marker grab it" do
      heights = [[5, 5, 5, 5, 5]]
      markers = [[1, 0, 0, 0, 2]]
      result = described_class.segment(heights, markers, connectivity: 4)
      expect(result.labels).to eq [[1, 1, described_class::BOUNDARY, 2, 2]]
    end

    it "splits an even plateau on the middle edge without boundary pixels" do
      heights = [[5, 5, 5, 5]]
      markers = [[1, 0, 0, 2]]
      result = described_class.segment(heights, markers, connectivity: 4)
      expect(result.labels).to eq [[1, 1, 2, 2]]
      expect(result.boundaries).to eq [[false, true, true, false]]
    end

    it "segments a flat image with diagonal markers, 8-connectivity" do
      markers = markers_from({[0, 0] => 1, [4, 4] => 2}, 5, 5)
      result = described_class.segment(grid(5, 5), markers, connectivity: 8)
      expect(result.labels).to eq [
        [1, 1, 1, 1, 0],
        [1, 1, 1, 0, 2],
        [1, 1, 0, 2, 2],
        [1, 0, 2, 2, 2],
        [0, 2, 2, 2, 2]
      ]
    end

    it "segments a flat image with diagonal markers, 4-connectivity" do
      markers = markers_from({[0, 0] => 1, [4, 4] => 2}, 5, 5)
      result = described_class.segment(grid(5, 5), markers, connectivity: 4)
      expect(result.labels).to eq [
        [1, 1, 1, 1, 0],
        [1, 1, 1, 0, 2],
        [1, 1, 0, 2, 2],
        [1, 0, 2, 2, 2],
        [0, 2, 2, 2, 2]
      ]
    end

    it "lets the connectivity decide whether a diagonal corridor is flooded" do
      markers = markers_from({[0, 0] => 1, [2, 2] => 2}, 3, 3)
      mask = [
        [true, false, true],
        [false, true, false],
        [true, false, true]
      ]
      result8 = described_class.segment(grid(3, 3), markers, connectivity: 8, mask: mask)
      expect(result8.labels).to eq [
        [1, nil, 0],
        [nil, 0, nil],
        [0, nil, 2]
      ]
      result4 = described_class.segment(grid(3, 3), markers, connectivity: 4, mask: mask)
      expect(result4.labels).to eq [
        [1, nil, -1],
        [nil, -1, nil],
        [-1, nil, 2]
      ]
    end

    it "keeps touching markers and marks their shared edge as boundary" do
      result = described_class.segment([[0, 0]], [[1, 2]], connectivity: 4)
      expect(result.labels).to eq [[1, 2]]
      expect(result.boundaries).to eq [[true, true]]
    end

    it "leaves connected components without a marker unlabeled" do
      mask = [[true, false, true, true]]
      result = described_class.segment([[0, 0, 0, 0]], [[1, 0, 0, 0]],
        connectivity: 4, mask: mask)
      expect(result.labels).to eq [[1, nil, described_class::UNLABELED, described_class::UNLABELED]]
      expect(result.boundaries).to eq [[false, nil, false, false]]
    end

    it "assigns nil to masked-out pixels and ignores markers on them" do
      mask = [[true, false]]
      result = described_class.segment([[0, 0]], [[0, 1]], connectivity: 4, mask: mask)
      expect(result.labels).to eq [[described_class::UNLABELED, nil]]
    end

    it "does not let a high marker claim lower terrain before the water rises" do
      heights = [[9, 0, 0]]
      markers = [[2, 0, 1]]
      result = described_class.segment(heights, markers, connectivity: 4)
      expect(result.labels).to eq [[2, 1, 1]]
    end

    it "supports negative height values" do
      heights = [[0, -3, 0]]
      markers = [[1, 0, 2]]
      result = described_class.segment(heights, markers, connectivity: 4)
      expect(result.labels).to eq [[1, 0, 2]]
    end
  end

  describe "scan order independence" do
    def rot90(matrix)
      size = matrix.size
      Array.new(size) { |y| Array.new(size) { |x| matrix[size - 1 - x][y] } }
    end

    def flip(matrix)
      matrix.map(&:reverse)
    end

    # Chebyshev cone, symmetric under rotations and flips, with one marker
    # per side. Every plateau pixel is contested by exactly the markers that
    # are equidistant from it, so any scan order bias would show up here.
    let(:cone_heights) do
      Array.new(7) { |y| Array.new(7) { |x| [(x - 3).abs, (y - 3).abs].max } }
    end

    let(:cone_markers) do
      markers_from({[3, 0] => 1, [6, 3] => 2, [3, 6] => 3, [0, 3] => 4}, 7, 7)
    end

    let(:cone_labels) do
      [
        [0, 1, 1, 1, 1, 1, 0],
        [4, 0, 1, 1, 1, 0, 2],
        [4, 4, 0, 1, 0, 2, 2],
        [4, 4, 4, 0, 2, 2, 2],
        [4, 4, 0, 3, 0, 2, 2],
        [4, 0, 3, 3, 3, 0, 2],
        [0, 3, 3, 3, 3, 3, 0]
      ]
    end

    it "partitions a rotation symmetric cone into the exact expected matrix" do
      result = described_class.segment(cone_heights, cone_markers, connectivity: 8)
      expect(result.labels).to eq cone_labels
    end

    it "produces the rotated label matrix for rotated markers" do
      markers = cone_markers
      labels = cone_labels
      4.times do
        markers = rot90(markers)
        labels = rot90(labels)
        result = described_class.segment(cone_heights, markers, connectivity: 8)
        expect(result.labels).to eq labels
      end
    end

    it "produces the flipped label matrix for flipped markers" do
      result = described_class.segment(cone_heights, flip(cone_markers), connectivity: 8)
      expect(result.labels).to eq flip(cone_labels)
    end

    it "is equivariant under rotation and flipping for asymmetric inputs" do
      heights = Array.new(6) { |y| Array.new(7) { |x| (x * 3 + y * 7 + x * y) % 5 - 2 } }
      markers = markers_from({[1, 1] => 1, [5, 4] => 2, [2, 5] => 3}, 6, 7)
      mask = Array.new(6) { |y| Array.new(7) { |x| (x + y) % 7 != 3 } }

      [4, 8].each do |connectivity|
        segment = lambda do |h, m, mk|
          described_class.segment(h, m, connectivity: connectivity, mask: mk).labels
        end
        base = segment.call(heights, markers, mask)

        rotate = lambda do |matrix|
          rows = matrix.size
          Array.new(matrix.first.size) do |y|
            Array.new(rows) { |x| matrix[rows - 1 - x][y] }
          end
        end
        expect(segment.call(rotate.call(heights), rotate.call(markers), rotate.call(mask)))
          .to eq rotate.call(base)

        expect(segment.call(heights.reverse, markers.reverse, mask.reverse))
          .to eq base.reverse

        expect(segment.call(heights.transpose, markers.transpose, mask.transpose))
          .to eq base.transpose
      end
    end
  end

  describe ChunkyPNG::Watershed::Result do
    let(:result) do
      markers = markers_from({[0, 0] => 1, [4, 0] => 2}, 1, 5)
      ChunkyPNG::Watershed.segment([[5, 5, 5, 5, 5]], markers, connectivity: 4)
    end

    it "exposes dimensions and single pixel access" do
      expect(result.width).to eq 5
      expect(result.height).to eq 1
      expect(result[2, 0]).to eq ChunkyPNG::Watershed::BOUNDARY
    end

    it "renders regions, boundaries, unlabeled and masked pixels to an image" do
      markers = markers_from({[0, 0] => 1, [2, 0] => 2}, 2, 3)
      mask = [[true, true, true], [false, false, false]]
      segmentation = ChunkyPNG::Watershed.segment(grid(2, 3), markers,
        connectivity: 4, mask: mask)
      image = segmentation.to_image
      expect(image.width).to eq 3
      expect(image.height).to eq 2
      palette = ChunkyPNG::Watershed::DEFAULT_PALETTE
      expect(image[0, 0]).to eq palette[0]
      expect(image[2, 0]).to eq palette[1]
      expect(image[1, 0]).to eq ChunkyPNG::Color::BLACK
      expect(image[0, 1]).to eq ChunkyPNG::Color::TRANSPARENT
    end

    it "cycles the palette for high label numbers" do
      result = ChunkyPNG::Watershed.segment([[0]], [[21]], connectivity: 4)
      image = result.to_image([ChunkyPNG::Color.rgb(1, 2, 3)])
      expect(image[0, 0]).to eq ChunkyPNG::Color.rgb(1, 2, 3)
    end

    it "renders unlabeled pixels in gray" do
      mask = [[true, false, true]]
      segmentation = ChunkyPNG::Watershed.segment([[0, 0, 0]], [[1, 0, 0]],
        connectivity: 4, mask: mask)
      image = segmentation.to_image
      expect(image[2, 0]).to eq ChunkyPNG::Color.rgb(0x99, 0x99, 0x99)
    end

    it "raises for an empty palette" do
      expect { result.to_image([]) }.to raise_error(ArgumentError, /palette/)
    end
  end
end
