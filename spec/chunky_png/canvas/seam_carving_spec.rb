require "spec_helper"

describe ChunkyPNG::Canvas::SeamCarving do
  let(:white) { ChunkyPNG::Color::WHITE }
  let(:black) { ChunkyPNG::Color::BLACK }
  let(:red) { ChunkyPNG::Color.rgb(255, 0, 0) }

  def protected_logo(width, height, logo_x, logo_y, logo_width, logo_height, color)
    image = ChunkyPNG::Canvas.new(width, height, white)
    mask = ChunkyPNG::Canvas.new(width, height, ChunkyPNG::Color::TRANSPARENT)

    logo_height.times do |y|
      logo_width.times do |x|
        image[logo_x + x, logo_y + y] = color
        mask[logo_x + x, logo_y + y] = color
      end
    end

    [image, mask]
  end

  describe "#resample_seam_carving" do
    it "removes horizontal size from a flat example and keeps a tall protected logo" do
      image = reference_canvas("seam_carving_logo")
      mask = reference_canvas("seam_carving_logo_mask")

      carved = image.resample_seam_carving(8, 9, mask)

      expect(carved).to eql reference_canvas("seam_carving_logo_carved")
      expect(carved.dimension).to eql ChunkyPNG::Dimension("8x9")
      expect(carved.pixels.count(red)).to eq(27)
      expect(mask.dimension).to eql ChunkyPNG::Dimension("15x9")
    end

    it "removes vertical size from flat rows without crossing a horizontal logo" do
      image, mask = protected_logo(15, 9, 0, 6, 15, 3, red)

      carved = image.resample_seam_carving(15, 5, mask)

      expect(carved.dimension).to eql ChunkyPNG::Dimension("15x5")
      expect(carved.pixels.count(red)).to eq(45)
      expect((0...carved.height).select { |y| carved.row(y).all? { |pixel| pixel == red } }).to eq([2, 3, 4])
    end

    it "chooses the lower-energy vertical seam from horizontal color changes" do
      gray = ChunkyPNG::Color.grayscale(128)
      canvas = ChunkyPNG::Canvas.new(3, 1, [white, gray, black])

      carved = canvas.resample_seam_carving(2, 1)

      expect(carved.pixels).to eq([gray, black])
    end

    it "chooses the lower-energy horizontal seam from vertical color changes" do
      gray = ChunkyPNG::Color.grayscale(128)
      canvas = ChunkyPNG::Canvas.new(1, 3, [white, gray, black])

      carved = canvas.resample_seam_carving(1, 2)

      expect(carved.pixels).to eq([gray, black])
    end

    it "resolves equal endpoint costs toward the center of a flat canvas" do
      canvas = ChunkyPNG::Canvas.new(5, 1, Array.new(5, white))

      expect(canvas.resample_seam_carving(4, 1).dimension).to eql ChunkyPNG::Dimension("4x1")
      expect(canvas.resample_seam_carving(3, 1).dimension).to eql ChunkyPNG::Dimension("3x1")
      expect(canvas.resample_seam_carving(2, 1).dimension).to eql ChunkyPNG::Dimension("2x1")
    end

    it "resolves equal horizontal endpoint costs toward the center" do
      canvas = ChunkyPNG::Canvas.new(1, 5, Array.new(5, white))

      expect(canvas.resample_seam_carving(1, 2).dimension).to eql ChunkyPNG::Dimension("1x2")
    end

    it "prefers the direct parent before the smaller diagonal on equal path costs" do
      canvas = ChunkyPNG::Canvas.new(1, 1)

      expect(canvas.send(:vertical_parent_x, [4, 4, 9], 1)).to eq(1)
      expect(canvas.send(:vertical_parent_x, [3, 9, 3], 1)).to eq(0)
      expect(canvas.send(:horizontal_parent_y, [3, 9, 3], 1)).to eq(0)
    end

    it "includes the alpha channel in seam energy" do
      transparent_white = ChunkyPNG::Color.rgba(255, 255, 255, 0)
      canvas = ChunkyPNG::Canvas.new(1, 3, [white, transparent_white, white])

      carved = canvas.resample_seam_carving(1, 2)

      expect(carved.pixels).to eq([white, white])
    end

    it "does not modify the source image or mask" do
      image, mask = protected_logo(5, 3, 2, 0, 1, 3, red)

      image.resample_seam_carving(3, 3, mask)

      expect(image.dimension).to eql ChunkyPNG::Dimension("5x3")
      expect(mask.dimension).to eql ChunkyPNG::Dimension("5x3")
      expect(image.pixels.count(red)).to eq(3)
      expect(mask.pixels.count(red)).to eq(3)
    end

    it "is available through the seam_carve alias" do
      canvas = ChunkyPNG::Canvas.new(2, 2, [white, white, white, white])

      expect(canvas.seam_carve(1, 1).dimension).to eql ChunkyPNG::Dimension("1x1")
    end
  end

  describe "#resample_seam_carving!" do
    it "updates the image and protection mask after every removed seam" do
      image, mask = protected_logo(5, 3, 2, 0, 1, 3, red)

      image.resample_seam_carving!(3, 3, mask)

      expect(image.dimension).to eql ChunkyPNG::Dimension("3x3")
      expect(mask.dimension).to eql image.dimension
      expect(image.pixels.count(red)).to eq(3)
      expect(mask.pixels.count(red)).to eq(3)
      expect((0...image.height).all? { |y| image[1, y] == red && mask[1, y] == red }).to eq(true)
    end

    it "updates the mask when removing horizontal seams" do
      image, mask = protected_logo(3, 5, 0, 2, 3, 1, red)

      image.resample_seam_carving!(3, 3, mask)

      expect(image.dimension).to eql ChunkyPNG::Dimension("3x3")
      expect(mask.dimension).to eql image.dimension
      expect(image.pixels.count(red)).to eq(3)
      expect(mask.pixels.count(red)).to eq(3)
      expect(image.row(1)).to eq([red, red, red])
    end

    it "reports why the requested width cannot be reached" do
      canvas = ChunkyPNG::Canvas.new(2, 2, [white, white, white, white])
      mask = ChunkyPNG::Canvas.new(2, 2, [red, red, ChunkyPNG::Color::TRANSPARENT, ChunkyPNG::Color::TRANSPARENT])

      expect { canvas.resample_seam_carving!(1, 2, mask) }.to raise_error(
        ChunkyPNG::Canvas::ProtectedAreaCrossing,
        "No unprotected vertical seam exists after removing 0 of 1 width pixels; " \
        "every 8-connected top-to-bottom path crosses a protected pixel."
      )
    end

    it "reports why the requested height cannot be reached" do
      canvas = ChunkyPNG::Canvas.new(2, 2, [white, white, white, white])
      mask = ChunkyPNG::Canvas.new(2, 2, [red, ChunkyPNG::Color::TRANSPARENT, red, ChunkyPNG::Color::TRANSPARENT])

      expect { canvas.resample_seam_carving!(2, 1, mask) }.to raise_error(
        ChunkyPNG::Canvas::ProtectedAreaCrossing,
        "No unprotected horizontal seam exists after removing 0 of 1 height pixels; " \
        "every 8-connected left-to-right path crosses a protected pixel."
      )
    end

    it "does not cross a protected area after earlier seams were removed" do
      canvas = ChunkyPNG::Canvas.new(4, 2, Array.new(8, white))
      mask = ChunkyPNG::Canvas.new(4, 2, [
        ChunkyPNG::Color::TRANSPARENT, red, red, ChunkyPNG::Color::TRANSPARENT,
        ChunkyPNG::Color::TRANSPARENT, ChunkyPNG::Color::TRANSPARENT, red, red
      ])

      expect { canvas.resample_seam_carving!(2, 2, mask) }.to raise_error(
        ChunkyPNG::Canvas::ProtectedAreaCrossing,
        /after removing 1 of 2 width pixels/
      )
      expect(canvas.width).to eq(3)
    end

    it "rejects enlargement" do
      canvas = ChunkyPNG::Canvas.new(1, 1, [white])

      expect { canvas.resample_seam_carving!(2, 1) }.to raise_error(ChunkyPNG::NotSupported)
    end

    it "rejects a mismatched protection mask" do
      canvas = ChunkyPNG::Canvas.new(2, 2, [white, white, white, white])
      mask = ChunkyPNG::Canvas.new(1, 1, [red])

      expect { canvas.resample_seam_carving!(1, 1, mask) }.to raise_error(ChunkyPNG::ExpectationFailed)
    end
  end
end
