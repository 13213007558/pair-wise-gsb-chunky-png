require "spec_helper"

describe ChunkyPNG::Canvas::SeamCarving do
  let(:white) { ChunkyPNG::Color.rgb(255, 255, 255) }
  let(:black) { ChunkyPNG::Color.rgb(0, 0, 0) }

  # Builds a canvas with vertical stripes of the given colors.
  def striped_canvas(colors, height = 3)
    canvas = ChunkyPNG::Canvas.new(colors.length, height, white)
    colors.each_with_index do |color, x|
      for y in 0...height
        canvas[x, y] = color
      end
    end
    canvas
  end

  describe "#seam_carve" do
    it "should reduce the width by removing vertical seams" do
      canvas = ChunkyPNG::Canvas.new(10, 6, white)
      carved, = canvas.seam_carve(7, 6)
      expect(carved.dimension).to eql ChunkyPNG::Dimension.new(7, 6)
    end

    it "should reduce the height by removing horizontal seams" do
      canvas = ChunkyPNG::Canvas.new(6, 10, white)
      carved, = canvas.seam_carve(6, 4)
      expect(carved.dimension).to eql ChunkyPNG::Dimension.new(6, 4)
    end

    it "should reduce both dimensions at once" do
      canvas = ChunkyPNG::Canvas.new(10, 8, white)
      carved, = canvas.seam_carve(6, 5)
      expect(carved.dimension).to eql ChunkyPNG::Dimension.new(6, 5)
    end

    it "should return nil as the mask when no mask was given" do
      canvas = ChunkyPNG::Canvas.new(4, 4, white)
      _, carved_mask = canvas.seam_carve(3, 3)
      expect(carved_mask).to be_nil
    end

    it "should not change the original image" do
      canvas = striped_canvas([white, black, white, white])
      expect { canvas.seam_carve(3, 3) }.to_not change { canvas.dimension }
      expect(canvas.column(1)).to eql [black, black, black]
    end

    it "should not change a given protection mask" do
      canvas = ChunkyPNG::Canvas.new(4, 3, white)
      mask = ChunkyPNG::Canvas.new(4, 3, ChunkyPNG::Color::TRANSPARENT)
      mask[2, 1] = white
      canvas.seam_carve(3, 3, mask: mask)
      expect(mask.dimension).to eql ChunkyPNG::Dimension.new(4, 3)
      expect(mask[2, 1]).to eql white
    end

    it "should raise an ArgumentError when enlarging the image" do
      canvas = ChunkyPNG::Canvas.new(4, 4, white)
      expect { canvas.seam_carve(5, 4) }.to raise_error(ArgumentError, /shrinking/)
      expect { canvas.seam_carve(4, 5) }.to raise_error(ArgumentError, /shrinking/)
    end

    it "should raise an ArgumentError when carving to zero" do
      canvas = ChunkyPNG::Canvas.new(4, 4, white)
      expect { canvas.seam_carve(0, 4) }.to raise_error(ArgumentError, /at least 1/)
    end

    it "should raise an ArgumentError when the mask dimensions do not match" do
      canvas = ChunkyPNG::Canvas.new(4, 4, white)
      mask = ChunkyPNG::Canvas.new(3, 4, ChunkyPNG::Color::TRANSPARENT)
      expect { canvas.seam_carve(3, 4, mask: mask) }.to raise_error(ArgumentError, /do not match/)
    end
  end

  describe "#seam_carve!" do
    it "should carve the canvas in place and return itself" do
      canvas = ChunkyPNG::Canvas.new(10, 6, white)
      expect(canvas.seam_carve!(7, 4)).to equal canvas
      expect(canvas.dimension).to eql ChunkyPNG::Dimension.new(7, 4)
    end

    it "should carve a given protection mask in place as well" do
      canvas = ChunkyPNG::Canvas.new(6, 4, white)
      mask = ChunkyPNG::Canvas.new(6, 4, ChunkyPNG::Color::TRANSPARENT)
      mask[5, 2] = white
      canvas.seam_carve!(4, 4, mask: mask)
      expect(mask.dimension).to eql ChunkyPNG::Dimension.new(4, 4)
    end
  end

  describe "seam selection" do
    it "should remove flat regions and keep high-contrast content intact" do
      # A black stripe surrounded by flat white background.
      canvas = striped_canvas([white, white, white, black, white, white, white])
      carved, = canvas.seam_carve(5, 3)
      expect(carved.column(0)).to eql [white, white, white]
      expect(carved.column(1)).to eql [black, black, black]
      expect(carved.column(2)).to eql [white, white, white]
    end

    it "should break ties between equal-cost seams by choosing the leftmost one" do
      # Uniform image: every vertical seam costs 0. The mask uses distinct
      # (fully transparent, thus unprotected) colors per column, so the
      # carved mask reveals which columns were removed.
      canvas = ChunkyPNG::Canvas.new(5, 2, white)
      mask = ChunkyPNG::Canvas.new(5, 2, ChunkyPNG::Color::TRANSPARENT)
      for x in 0...5
        for y in 0...2
          mask[x, y] = ChunkyPNG::Color.rgba(x + 1, 0, 0, 0)
        end
      end
      carved, carved_mask = canvas.seam_carve(3, 2, mask: mask)
      expect(carved.dimension).to eql ChunkyPNG::Dimension.new(3, 2)
      # The leftmost two columns (red values 1 and 2) were removed.
      for x in 0...3
        expect(ChunkyPNG::Color.r(carved_mask[x, 0])).to eql x + 3
      end
    end

    it "should break ties between equal-cost horizontal seams by choosing the topmost one" do
      canvas = ChunkyPNG::Canvas.new(2, 5, white)
      mask = ChunkyPNG::Canvas.new(2, 5, ChunkyPNG::Color::TRANSPARENT)
      for x in 0...2
        for y in 0...5
          mask[x, y] = ChunkyPNG::Color.rgba(y + 1, 0, 0, 0)
        end
      end
      _, carved_mask = canvas.seam_carve(2, 3, mask: mask)
      for y in 0...3
        expect(ChunkyPNG::Color.r(carved_mask[0, y])).to eql y + 3
      end
    end
  end

  describe "protection masks" do
    it "should route seams around protected pixels" do
      # Protect the black stripe; the seams must be taken from the flat
      # background even though unprotected carving might behave the same.
      canvas = striped_canvas([white, white, black, white, white, white])
      mask = ChunkyPNG::Canvas.new(6, 3, ChunkyPNG::Color::TRANSPARENT)
      for y in 0...3
        mask[2, y] = white
      end
      carved, carved_mask = canvas.seam_carve(3, 3, mask: mask)
      expect(carved.column(1)).to eql [black, black, black]
      expect(carved_mask.column(1)).to eql [white, white, white]
    end

    it "should keep the mask in sync with the image for every removed seam" do
      canvas = ChunkyPNG::Canvas.new(8, 5, white)
      mask = ChunkyPNG::Canvas.new(8, 5, ChunkyPNG::Color::TRANSPARENT)
      mask[7, 2] = white
      carved, carved_mask = canvas.seam_carve(5, 3, mask: mask)
      expect(carved_mask.dimension).to eql carved.dimension
      # The protected pixel survived and is still marked in the mask.
      protected_pixels = (0...carved_mask.area).count { |i| ChunkyPNG::Color.a(carved_mask.pixels[i]) > 0 }
      expect(protected_pixels).to eql 1
    end

    it "should raise a ProtectionConflict when every vertical seam crosses protected pixels" do
      canvas = ChunkyPNG::Canvas.new(5, 4, white)
      mask = ChunkyPNG::Canvas.new(5, 4, ChunkyPNG::Color::TRANSPARENT)
      for x in 0...5
        mask[x, 1] = white # A fully protected row blocks every vertical seam.
      end
      expect { canvas.seam_carve(4, 4, mask: mask) }
        .to raise_error(ChunkyPNG::Canvas::SeamCarving::ProtectionConflict, /vertical seam/)
    end

    it "should raise a ProtectionConflict when every horizontal seam crosses protected pixels" do
      canvas = ChunkyPNG::Canvas.new(4, 5, white)
      mask = ChunkyPNG::Canvas.new(4, 5, ChunkyPNG::Color::TRANSPARENT)
      for y in 0...5
        mask[2, y] = white # A fully protected column blocks every horizontal seam.
      end
      expect { canvas.seam_carve(4, 4, mask: mask) }
        .to raise_error(ChunkyPNG::Canvas::SeamCarving::ProtectionConflict, /horizontal seam/)
    end

    it "should report how many seams were removed before getting stuck" do
      canvas = ChunkyPNG::Canvas.new(5, 3, white)
      mask = ChunkyPNG::Canvas.new(5, 3, ChunkyPNG::Color::TRANSPARENT)
      # A protected barrier of 3 columns; only the 2 outer columns can go.
      for y in 0...3
        for x in 1..3
          mask[x, y] = white
        end
      end
      expect { canvas.seam_carve(2, 3, mask: mask) }
        .to raise_error(ChunkyPNG::Canvas::SeamCarving::ProtectionConflict, /Removed 2 seam/)
    end

    it "should not cross protected pixels to reach the requested size" do
      canvas = ChunkyPNG::Canvas.new(5, 3, white)
      mask = ChunkyPNG::Canvas.new(5, 3, ChunkyPNG::Color::TRANSPARENT)
      for y in 0...3
        for x in 1..3
          mask[x, y] = white
        end
      end
      carved, carved_mask = canvas.seam_carve(3, 3, mask: mask)
      # Only the unprotected outer columns were removed; the protected
      # barrier is fully intact.
      expect(carved.dimension).to eql ChunkyPNG::Dimension.new(3, 3)
      for y in 0...3
        for x in 0...3
          expect(ChunkyPNG::Color.a(carved_mask[x, y])).to be > 0
        end
      end
    end

    it "should leave the canvas unchanged when carving fails" do
      canvas = ChunkyPNG::Canvas.new(5, 4, white)
      mask = ChunkyPNG::Canvas.new(5, 4, ChunkyPNG::Color::TRANSPARENT)
      for x in 0...5
        mask[x, 1] = white
      end
      expect { canvas.seam_carve!(4, 4, mask: mask) }
        .to raise_error(ChunkyPNG::Canvas::SeamCarving::ProtectionConflict)
      expect(canvas.dimension).to eql ChunkyPNG::Dimension.new(5, 4)
      expect(mask.dimension).to eql ChunkyPNG::Dimension.new(5, 4)
    end
  end

  describe "logo sample" do
    let(:logo) { reference_canvas("seam_carving_logo") }
    let(:background) { ChunkyPNG::Color.rgb(240, 240, 240) }

    def logo_columns(canvas)
      (0...canvas.width).select do |x|
        canvas.column(x).any? { |pixel| pixel != background }
      end
    end

    def protection_mask(canvas)
      mask = ChunkyPNG::Canvas.new(canvas.width, canvas.height, ChunkyPNG::Color::TRANSPARENT)
      for y in 0...canvas.height
        for x in 0...canvas.width
          mask[x, y] = ChunkyPNG::Color::WHITE if canvas[x, y] != background
        end
      end
      mask
    end

    it "should have a tall thin logo next to a large flat background" do
      expect(logo.dimension).to eql ChunkyPNG::Dimension.new(120, 48)
      expect(logo_columns(logo)).to eql (90...95).to_a
    end

    it "should narrow the image without deforming the protected logo" do
      carved, carved_mask = logo.seam_carve(60, 48, mask: protection_mask(logo))

      # The output size changed...
      expect(carved.dimension).to eql ChunkyPNG::Dimension.new(60, 48)
      expect(carved_mask.dimension).to eql carved.dimension

      # ...and every logo pixel is still intact: the carved image contains
      # the exact same logo columns, only shifted to the left.
      original_logo = logo_columns(logo).map { |x| logo.column(x) }
      carved_logo = logo_columns(carved).map { |x| carved.column(x) }
      expect(carved_logo).to eql original_logo

      # The carved mask still protects exactly the logo pixels.
      for y in 0...carved.height
        for x in 0...carved.width
          protected = ChunkyPNG::Color.a(carved_mask[x, y]) > 0
          expect(protected).to eql(carved[x, y] != background)
        end
      end
    end

    it "should also shrink the height without touching the logo" do
      carved, = logo.seam_carve(60, 40, mask: protection_mask(logo))
      expect(carved.dimension).to eql ChunkyPNG::Dimension.new(60, 40)
      # All 40 x 5 logo pixels survived; the 8 horizontal seams were taken
      # from the flat background rows above and below the logo.
      carved_logo_x = logo_columns(carved)
      expect(carved_logo_x.length).to eql 5
      non_background = carved.pixels.count { |pixel| pixel != background }
      expect(non_background).to eql 40 * 5
    end

    it "should refuse to shrink the height below the logo height" do
      # The logo is 40 rows tall; once the 8 flat background rows are gone,
      # the protected logo spans the full height and blocks every
      # horizontal seam.
      expect { logo.seam_carve(60, 39, mask: protection_mask(logo)) }
        .to raise_error(ChunkyPNG::Canvas::SeamCarving::ProtectionConflict, /horizontal seam/)
    end
  end
end
