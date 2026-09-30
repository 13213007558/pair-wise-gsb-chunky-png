# frozen_string_literal: true

require "spec_helper"

describe ChunkyPNG::ColorSpace do
  let(:d65) { ChunkyPNG::ColorSpace::SRGB_WHITE_POINT }
  let(:srgb_primaries) { ChunkyPNG::ColorSpace::SRGB_PRIMARIES }

  it "round-trips sRGB samples through linear sRGB" do
    result = ChunkyPNG::ColorSpace.srgb.from_linear_srgb(
      ChunkyPNG::ColorSpace.srgb.to_linear_srgb([0.5, 0.5, 0.5])
    )
    expect(result.map { |value| (value * 255).round }).to eq([128, 128, 128])
  end

  it "uses gAMA as an encoding transfer exponent" do
    source = described_class.new(encoding_gamma: 1.0, white_point: d65, primaries: srgb_primaries)
    destination = described_class.new(encoding_gamma: 2.0, white_point: d65, primaries: srgb_primaries)

    foreground = ChunkyPNG::Color.rgba(128, 128, 128, 128)
    background = ChunkyPNG::Color.rgb(255, 255, 255)
    result = ChunkyPNG::Color.compose_managed(foreground, background, source, destination)

    expect(ChunkyPNG::Color.r(result)).to eq(221)
    expect(ChunkyPNG::Color.g(result)).to eq(221)
    expect(ChunkyPNG::Color.b(result)).to eq(221)
    expect(ChunkyPNG::Color.a(result)).to eq(255)
  end

  it "keeps the alpha channel outside the transfer function" do
    source = described_class.new(encoding_gamma: 1.0, white_point: d65, primaries: srgb_primaries)
    destination = described_class.new(encoding_gamma: 2.0, white_point: d65, primaries: srgb_primaries)

    result = ChunkyPNG::Color.compose_managed(
      ChunkyPNG::Color.rgba(128, 128, 128, 128),
      ChunkyPNG::Color.rgba(0, 0, 0, 0),
      source,
      destination
    )
    expect(ChunkyPNG::Color.a(result)).to eq(128)
  end

  it "does not let hidden RGB in transparent pixels contaminate edges" do
    source = described_class.new(encoding_gamma: 1.0, white_point: d65, primaries: srgb_primaries)
    result = ChunkyPNG::Color.compose_managed(
      ChunkyPNG::Color.rgba(255, 0, 0, 0),
      ChunkyPNG::Color.rgb(0, 0, 255),
      source,
      ChunkyPNG::ColorSpace.srgb
    )
    expect(result).to eq(ChunkyPNG::Color.rgb(0, 0, 255))
  end

  it "adapts color patches between different white points" do
    equal_energy = described_class.new(
      encoding_gamma: 1.0,
      white_point: [1.0 / 3.0, 1.0 / 3.0],
      primaries: srgb_primaries
    )
    destination = ChunkyPNG::ColorSpace.srgb

    result = ChunkyPNG::Color.compose_managed(
      ChunkyPNG::Color.rgba(255, 0, 0, 128),
      ChunkyPNG::Color.rgba(0, 0, 0, 0),
      equal_energy,
      destination
    )
    expect(ChunkyPNG::Color.r(result)).to eq(255)
    expect(ChunkyPNG::Color.g(result)).to eq(2)
    expect(ChunkyPNG::Color.b(result)).to eq(1)
    expect(ChunkyPNG::Color.a(result)).to eq(128)
  end

  it "reads and writes sRGB, gAMA and cHRM chunks" do
    gamma = ChunkyPNG::Chunk::Gamma.new(0.45455)
    chromaticity = ChunkyPNG::Chunk::Chromaticity.new(0.3127, 0.3290, 0.6400, 0.3300, 0.3000, 0.6000, 0.1500, 0.0600)

    reparsed_gamma = serialized_chunk(gamma)
    reparsed_chromaticity = serialized_chunk(chromaticity)
    expect(reparsed_gamma.gamma).to be_within(0.000001).of(0.45455)
    expect(reparsed_chromaticity.white_point).to eq([0.3127, 0.3290])
    expect(reparsed_chromaticity.primaries).to eq(ChunkyPNG::ColorSpace::SRGB_PRIMARIES)
  end

  describe ".from_chunks" do
    it "assumes sRGB when color profile metadata is absent" do
      expect(described_class.from_chunks(nil, nil, nil)).to be_srgb_transfer
    end

    it "assumes the complete sRGB profile when one gAMA/cHRM half is missing" do
      gamma = ChunkyPNG::Chunk::Gamma.new(2.0)
      profile = described_class.from_chunks(nil, [gamma], nil)
      expect(profile).to be_srgb_transfer
    end

    it "raises by default when metadata conflicts" do
      chunks = [
        ChunkyPNG::Chunk::SRGB.new(0),
        ChunkyPNG::Chunk::Gamma.new(1.0),
      ]
      expect { described_class.from_chunks(chunks[0], [chunks[1]], nil) }
        .to raise_error(ChunkyPNG::ColorProfileError)
    end

    it "supports preferring sRGB when metadata conflicts" do
      profile = described_class.from_chunks(
        ChunkyPNG::Chunk::SRGB.new(0),
        ChunkyPNG::Chunk::Gamma.new(1.0),
        nil,
        on_conflicting_color_metadata: :prefer_srgb
      )
      expect(profile).to be_srgb_transfer
    end

    it "does not silently use the last duplicated gAMA chunk" do
      first = ChunkyPNG::Chunk::Gamma.new(2.0)
      second = ChunkyPNG::Chunk::Gamma.new(0.5)
      chromaticity = ChunkyPNG::Chunk::Chromaticity.new(
        0.3127, 0.3290, 0.64, 0.33, 0.3, 0.6, 0.15, 0.06
      )

      expect { described_class.from_chunks(nil, [first, second], [chromaticity]) }
        .to raise_error(ChunkyPNG::ColorProfileError)

      profile = described_class.from_chunks(
        nil,
        [first, second],
        [chromaticity],
        on_conflicting_color_metadata: :last
      )
      expect(profile.encoding_gamma).to be_within(0.00001).of(0.5)
    end

    it "raises by default for an invalid cHRM white point" do
      gamma = ChunkyPNG::Chunk::Gamma.new(1.0)
      chromaticity = ChunkyPNG::Chunk::Chromaticity.new(0.3, 0.0, 0.64, 0.33, 0.3, 0.6, 0.15, 0.06)
      expect { described_class.from_chunks(nil, [gamma], [chromaticity]) }
        .to raise_error(ChunkyPNG::ColorProfileError)
    end

    it "can replace an invalid white point with the sRGB white point" do
      gamma = ChunkyPNG::Chunk::Gamma.new(1.0)
      chromaticity = ChunkyPNG::Chunk::Chromaticity.new(
        0.3, 0.0, 0.64, 0.33, 0.3, 0.6, 0.15, 0.06
      )
      profile = described_class.from_chunks(
        nil,
        [gamma],
        [chromaticity],
        on_invalid_white_point: :assume_srgb
      )
      expect(profile.white_point).to eq(ChunkyPNG::ColorSpace::SRGB_WHITE_POINT)
    end
  end
end

describe ChunkyPNG::Canvas::ColorManagement do
  let(:source) do
    ChunkyPNG::ColorSpace.new(
      encoding_gamma: 1.0,
      white_point: ChunkyPNG::ColorSpace::SRGB_WHITE_POINT,
      primaries: ChunkyPNG::ColorSpace::SRGB_PRIMARIES
    )
  end
  let(:destination) do
    ChunkyPNG::ColorSpace.new(
      encoding_gamma: 2.0,
      white_point: ChunkyPNG::ColorSpace::SRGB_WHITE_POINT,
      primaries: ChunkyPNG::ColorSpace::SRGB_PRIMARIES
    )
  end

  it "keeps the normal compose interface on encoded RGB values" do
    foreground = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(64, 64, 64, 128))
    background = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgb(255, 255, 255))

    expect(background.compose(foreground).get_pixel(0, 0)).to eq(0x9f9f9fff)
  end

  it "composes canvas instances using their attached color spaces" do
    foreground = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(64, 64, 64, 128))
    foreground.color_space = source
    background = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgb(255, 255, 255))
    background.color_space = destination

    result = background.compose_managed(foreground)
    expect(result.get_pixel(0, 0)).to eq(0xc9c9c9ff)
  end

  it "preserves attached color profile chunks when decoding and encoding" do
    canvas = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgb(255, 255, 255))
    canvas.color_space = source
    loaded = ChunkyPNG::Canvas.from_blob(canvas.to_blob)
    expect(loaded.color_profile_chunks[:gama].first.gamma).to be_within(0.00001).of(1.0)
    expect(loaded.color_profile_chunks[:chrm].first.white_point)
      .to eq(ChunkyPNG::ColorSpace::SRGB_WHITE_POINT)
  end

  it "accepts explicit policy options" do
    foreground = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(64, 64, 64, 128))
    background = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgb(255, 255, 255))

    result = background.compose_managed(
      foreground,
      0,
      0,
      foreground_color_space: source,
      background_color_space: destination
    )
    expect(result.get_pixel(0, 0)).to eq(0xc9c9c9ff)
  end
end
