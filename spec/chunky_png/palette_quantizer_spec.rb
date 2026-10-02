# frozen_string_literal: true

require "spec_helper"

describe ChunkyPNG::PaletteQuantizer do
  let(:red) { ChunkyPNG::Color.rgb(255, 0, 0) }
  let(:green) { ChunkyPNG::Color.rgb(0, 255, 0) }
  let(:blue) { ChunkyPNG::Color.rgb(0, 0, 255) }
  let(:yellow) { ChunkyPNG::Color.rgb(255, 255, 0) }
  let(:black) { ChunkyPNG::Color.rgb(0, 0, 0) }
  let(:transparent_red) { ChunkyPNG::Color.rgba(255, 0, 0, 0) }
  let(:transparent_blue) { ChunkyPNG::Color.rgba(0, 0, 255, 0) }
  let(:near_red) { ChunkyPNG::Color.rgb(250, 2, 2) }
  let(:near_blue) { ChunkyPNG::Color.rgb(2, 2, 250) }

  describe ".quantize" do
    it "keeps fixed colors and the transparent slot at their indices" do
      palette, indices = ChunkyPNG::Palette.quantize(
        [[red, transparent_red, green], [blue, transparent_blue]],
        fixed_colors: [yellow],
        transparent_index: 3,
        size: 64,
      )

      expect(palette[0]).to eql(yellow)
      expect(palette[3]).to eql(ChunkyPNG::Color::TRANSPARENT)
      expect(palette.length).to eql(64)
      red_index = (0...64).find { |index| palette[index] == red }
      green_index = (0...64).find { |index| palette[index] == green }
      blue_index = (0...64).find { |index| palette[index] == blue }
      expect(indices).to eql([[red_index, 3, green_index], [blue_index, 3]])
      expect(indices.flatten).to all(be < 64)
    end

    it "preserves fixed colors that do not occur in a sample" do
      palette, indices = ChunkyPNG::Palette.quantize(
        [[red, green]],
        fixed_colors: { 10 => yellow, 20 => blue },
        size: 64,
      )

      expect(palette[10]).to eql(yellow)
      expect(palette[20]).to eql(blue)
      expect(indices.flatten).to all(be < 64)
    end

    it "does not duplicate a free slot color that matches a sparse fixed slot" do
      palette, indices = ChunkyPNG::Palette.quantize(
        [[black]],
        fixed_colors: { 63 => black },
        size: 64,
      )

      expect(palette[63]).to eql(black)
      expect(palette.to_a.uniq.length).to eql(64)
      expect(indices.first).to eql([63])
    end

    it "produces the same slots when the image order changes" do
      first_images = [[red, near_red], [blue, near_blue]]
      second_images = first_images.reverse
      options = { fixed_colors: [yellow], weights: [1, 2], size: 64 }

      first_palette, first_indices = ChunkyPNG::Palette.quantize(first_images, options)
      second_palette, second_indices = ChunkyPNG::Palette.quantize(second_images, options.merge(weights: [2, 1]))

      expect(second_palette.to_a).to eql(first_palette.to_a)
      expect(second_indices).to eql(first_indices.reverse)
    end

    it "ignores RGB channels of fully transparent pixels" do
      palette, indices = ChunkyPNG::Palette.quantize(
        [[transparent_red, transparent_blue, red]],
        fixed_colors: [yellow],
        size: 4,
      )

      expect(palette[1]).to eql(ChunkyPNG::Color::TRANSPARENT)
      expect(indices.first[0..1]).to eql([1, 1])
      expect(indices.flatten).to all(be < 4)
    end

    it "lets image weights influence which cluster wins a shared free slot" do
      images = [[near_red], [near_blue]]
      options = { fixed_colors: [yellow], size: 3 }

      red_weighted_palette, = ChunkyPNG::Palette.quantize(
        images, options.merge(weights: [100, 1])
      )
      blue_weighted_palette, = ChunkyPNG::Palette.quantize(
        images, options.merge(weights: [1, 100])
      )

      expect(ChunkyPNG::Color.euclidean_distance_rgba(red_weighted_palette[2], red)).to(
        be < ChunkyPNG::Color.euclidean_distance_rgba(red_weighted_palette[2], blue)
      )
      expect(ChunkyPNG::Color.euclidean_distance_rgba(blue_weighted_palette[2], blue)).to(
        be < ChunkyPNG::Color.euclidean_distance_rgba(blue_weighted_palette[2], red)
      )
    end

    it "encodes arbitrary-RGB transparent pixels through the transparent slot" do
      palette, = ChunkyPNG::Palette.quantize([[red, transparent_red]], fixed_colors: [yellow], size: 8)
      expect(palette.to_plte_chunk.content.bytes.first(3)).to eql([255, 255, 0])
      canvas = ChunkyPNG::Canvas.new(1, 2, [red, transparent_red])
      canvas.encoding_palette = palette
      decoded = ChunkyPNG::Canvas.from_blob(canvas.to_blob(color_mode: ChunkyPNG::COLOR_INDEXED))

      expect(decoded.pixels).to eql([red, ChunkyPNG::Color::TRANSPARENT])
    end

    it "rejects conflicting transparent and fixed slots" do
      expect do
        ChunkyPNG::Palette.quantize([[red]], fixed_colors: [yellow], transparent_index: 0, size: 2)
      end.to raise_error(ArgumentError)
    end
  end
end
