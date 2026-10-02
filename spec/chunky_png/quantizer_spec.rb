require "spec_helper"

describe ChunkyPNG::Quantizer do
  let(:red) { ChunkyPNG::Color.rgb(255, 0, 0) }
  let(:green) { ChunkyPNG::Color.rgb(0, 255, 0) }
  let(:blue) { ChunkyPNG::Color.rgb(0, 0, 255) }
  let(:transparent) { ChunkyPNG::Color::TRANSPARENT }

  it "builds a shared 64-color palette and valid image indexes" do
    images = [
      [red, ChunkyPNG::Color.rgb(250, 4, 4), transparent],
      [blue, ChunkyPNG::Color.rgb(4, 4, 250), transparent]
    ]

    palette, indexed_images = described_class.quantize(images, fixed_colors: [red])

    expect(palette.size).to eql 64
    expect(palette[0]).to eql red
    expect(palette[1]).to eql transparent
    expect(indexed_images.map(&:length)).to eql [3, 3]
    indexed_images.flatten.each do |index|
      expect(index).to be_between(0, 63)
    end
  end

  it "keeps transparent pixels in the transparent slot regardless of RGB" do
    odd_transparent = ChunkyPNG::Color.rgba(123, 45, 67, 0)
    palette, indexed_images = described_class.quantize(
      [[transparent, odd_transparent, red]],
      fixed_colors: [red]
    )

    expect(indexed_images.first[0]).to eql 1
    expect(indexed_images.first[1]).to eql 1
    expect(palette[1]).to eql transparent
    expect(indexed_images.first[2]).to eql 0
  end

  it "does not change palette slots when input order changes" do
    first_image = [ChunkyPNG::Color.rgb(250, 4, 4), ChunkyPNG::Color.rgb(246, 8, 8)]
    second_image = [ChunkyPNG::Color.rgb(4, 4, 250), ChunkyPNG::Color.rgb(8, 8, 246)]
    options = { fixed_colors: [red], size: 3 }

    first_palette, first_indexes = described_class.quantize([first_image, second_image], options)
    second_palette, second_indexes = described_class.quantize([second_image, first_image], options)

    expect(second_palette.to_a).to eql first_palette.to_a
    expect(second_indexes).to eql first_indexes.reverse
  end

  it "keeps palette fitting independent of image ordering with different counts" do
    many_red = Array.new(30) { ChunkyPNG::Color.rgb(230, 10, 10) }
    few_blue = Array.new(2) { ChunkyPNG::Color.rgb(10, 10, 230) }
    options = { fixed_colors: [red], size: 3 }

    first_palette, _ = described_class.quantize([many_red, few_blue], options)
    second_palette, _ = described_class.quantize([few_blue, many_red], options)

    expect(second_palette.to_a).to eql first_palette.to_a
  end

  it "preserves fixed colors even when they do not occur in the samples" do
    palette, indexed_images = described_class.quantize(
      [[blue, transparent]],
      fixed_colors: { 5 => green, 62 => red },
      transparent_index: 63
    )

    expect(palette[5]).to eql green
    expect(palette[62]).to eql red
    expect(palette[63]).to eql transparent
    expect(indexed_images.first.last).to eql 63
    expect(indexed_images.first.first).to be < 63
  end

  it "uses per-image weights while fitting the shared palette" do
    redish_image = Array.new(20) { ChunkyPNG::Color.rgb(238, 0, 0) }
    bluish_image = Array.new(20) { ChunkyPNG::Color.rgb(0, 0, 238) }
    options = {
      fixed_colors: [green],
      transparent_index: 1,
      size: 3,
      weights: [10.0, 0.1]
    }

    palette, _indexed_images = described_class.quantize([redish_image, bluish_image], options)
    generated_color = palette[2]

    expect(ChunkyPNG::Color.r(generated_color)).to be > ChunkyPNG::Color.b(generated_color)
  end

  it "accepts canvas objects" do
    canvas = ChunkyPNG::Canvas.new(1, 2, [red, transparent])
    palette, indexed_images = described_class.quantize([canvas], fixed_colors: [red])

    expect(palette[0]).to eql red
    expect(indexed_images.first).to eql [0, 1]
  end

  it "returns an encoding-ready ordered palette" do
    canvas = ChunkyPNG::Canvas.new(1, 2, [green, transparent])
    palette, indexed_images = described_class.quantize(
      [canvas],
      fixed_colors: { 0 => red, 2 => green },
      transparent_index: 1
    )
    encoded_canvas = ChunkyPNG::Canvas.new(1, 2, indexed_images.first.map { |index| palette[index] })
    encoded_canvas.encoding_palette = palette

    datastream = encoded_canvas.to_datastream
    decoded = ChunkyPNG::Canvas.from_datastream(datastream)

    expect(decoded.pixels).to eql [green, transparent]
  end
end

describe ChunkyPNG::Palette do
  it "preserves the order of an explicitly ordered palette when encoding" do
    colors = [ChunkyPNG::Color.rgb(1, 2, 3), ChunkyPNG::Color.rgb(200, 100, 50)]
    palette = described_class.from_ordered_colors(colors)
    palette.to_plte_chunk

    expect(palette[0]).to eql colors.first
    expect(palette.index(colors.first)).to eql 0
    expect(palette.index(colors.last)).to eql 1
  end
end
