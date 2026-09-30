require "spec_helper"

describe ChunkyPNG::Datastream do
  def datastream_with(*chunks)
    datastream = ChunkyPNG::Datastream.new
    datastream.header_chunk = ChunkyPNG::Chunk::Header.new(width: 1, height: 1)
    datastream.other_chunks.concat(chunks)
    datastream.data_chunks = [ChunkyPNG::Chunk::ImageData.new("IDAT", Zlib::Deflate.deflate("\0\377\377\377"))]
    datastream.end_chunk = ChunkyPNG::Chunk::End.new
    ChunkyPNG::Datastream.from_blob(datastream.to_blob)
  end

  let(:valid_chromaticities) do
    {
      white_x: 31_270, white_y: 32_900,
      red_x: 64_000, red_y: 33_000,
      green_x: 30_000, green_y: 60_000,
      blue_x: 15_000, blue_y: 6_000,
    }
  end

  let(:other_chromaticities) do
    {
      white_x: 90_000, white_y: 5_000,
      red_x: 64_000, red_y: 33_000,
      green_x: 30_000, green_y: 60_000,
      blue_x: 15_000, blue_y: 6_000,
    }
  end

  it "parses the sRGB chunk" do
    profile = datastream_with(ChunkyPNG::Chunk::SRGB.new(0)).color_profile

    expect(profile.standard_srgb?).to be(true)
  end

  it "parses a legal gAMA and cHRM combination" do
    profile = datastream_with(
      ChunkyPNG::Chunk::Gamma.new(100_000),
      ChunkyPNG::Chunk::Chromaticities.new(valid_chromaticities)
    ).color_profile

    expect(profile.standard_srgb?).to be(false)
    expect(profile.gamma).to be_within(1e-12).of(1.0)
  end

  it "exposes the parsed profile when decoding a PNG blob" do
    datastream = datastream_with(
      ChunkyPNG::Chunk::Gamma.new(100_000),
      ChunkyPNG::Chunk::Chromaticities.new(valid_chromaticities)
    )

    image = ChunkyPNG::Canvas.from_blob(datastream.to_blob)
    expect(image.color_profile.gamma).to be_within(1e-12).of(1.0)
  end

  it "assumes sRGB when metadata is missing by default" do
    profile = datastream_with.color_profile

    expect(profile.standard_srgb?).to be(true)
    expect(profile.explicit?).to be(false)
  end

  it "can reject missing color metadata" do
    expect { datastream_with.color_profile(missing: :raise) }.to raise_error(ChunkyPNG::MissingColorProfile)
  end

  it "raises by default when conflicting color chunks are present" do
    datastream = datastream_with(
      ChunkyPNG::Chunk::SRGB.new,
      ChunkyPNG::Chunk::Gamma.new(100_000)
    )

    expect { datastream.color_profile }.to raise_error(ChunkyPNG::ExpectationFailed)
  end

  it "does not silently use the last conflicting chunk" do
    datastream = datastream_with(
      ChunkyPNG::Chunk::SRGB.new,
      ChunkyPNG::Chunk::Gamma.new(100_000)
    )

    expect(datastream.color_profile(conflict: :prefer_srgb).standard_srgb?).to be(true)
    expect { datastream.color_profile(conflict: :bogus) }.to raise_error(ArgumentError)
  end

  it "uses the first color chunk when first-wins conflict handling is configured" do
    datastream = datastream_with(
      ChunkyPNG::Chunk::Gamma.new(100_000),
      ChunkyPNG::Chunk::Chromaticities.new(valid_chromaticities),
      ChunkyPNG::Chunk::SRGB.new
    )

    profile = datastream.color_profile(conflict: :prefer_first)
    expect(profile.standard_srgb?).to be(false)
    expect(profile.gamma).to be_within(1e-12).of(1.0)
  end

  it "raises by default for an invalid white point and can fall back to sRGB" do
    datastream = datastream_with(
      ChunkyPNG::Chunk::Gamma.new(100_000),
      ChunkyPNG::Chunk::Chromaticities.new(other_chromaticities)
    )

    expect { datastream.color_profile }.to raise_error(ChunkyPNG::ColorProfile::InvalidColorSpace)
    expect(datastream.color_profile(invalid_white: :assume_srgb).standard_srgb?).to be(true)
  end

  it "can ignore an invalid cHRM white point while retaining gAMA" do
    datastream = datastream_with(
      ChunkyPNG::Chunk::Gamma.new(100_000),
      ChunkyPNG::Chunk::Chromaticities.new(other_chromaticities)
    )

    profile = datastream.color_profile(invalid_white: :ignore_chrm)
    expect(profile.standard_srgb?).to be(false)
    expect(profile.gamma).to be_within(1e-12).of(1.0)
  end
end
