require "spec_helper"

describe ChunkyPNG::ColorProfile do
  let(:srgb) { ChunkyPNG::ColorProfile.srgb }

  it "keeps the standard sRGB profile as the explicit default singleton" do
    expect(srgb.standard_srgb?).to be(true)
    expect(srgb.explicit?).to be(true)
    expect(srgb.to_chunks.map(&:type)).to eql ["sRGB"]
  end

  it "decodes and encodes the sRGB piecewise transfer function" do
    expect(srgb.decode_component(10, 255)).to be_within(1e-12).of(10.0 / (255 * 12.92))
    expect(srgb.encode_component(10.0 / (255 * 12.92))).to eql 10
    expect(srgb.encode_component(0.5)).to eql 188
  end

  it "supports a legal gAMA and cHRM combination" do
    profile = ChunkyPNG::ColorProfile.custom(
      gamma: 2.2,
      chromaticities: ChunkyPNG::ColorProfile::Chromaticities.srgb
    )
    chunks = profile.to_chunks

    expect(chunks.map(&:type)).to eql ["gAMA", "cHRM"]
    expect(chunks.first.gamma).to eql 45_455
    expect(profile.standard_srgb?).to be(false)
  end

  it "rejects a custom profile with an invalid white point" do
    chromaticities = ChunkyPNG::ColorProfile::Chromaticities.new(
      white_x: 0.9, white_y: 0.05,
      red_x: 0.64, red_y: 0.33,
      green_x: 0.30, green_y: 0.60,
      blue_x: 0.15, blue_y: 0.06
    )

    expect do
      ChunkyPNG::ColorProfile.custom(gamma: 2.2, chromaticities: chromaticities)
    end.to raise_error(ChunkyPNG::ColorProfile::InvalidColorSpace)
  end
end

describe "color-managed compositing" do
  let(:srgb) { ChunkyPNG::ColorProfile.srgb }
  let(:gamma_22) do
    ChunkyPNG::ColorProfile.custom(
      gamma: 2.2,
      chromaticities: ChunkyPNG::ColorProfile::Chromaticities.srgb
    )
  end

  it "linearizes mid-gray before source-over compositing" do
    foreground = ChunkyPNG::Color.rgba(188, 188, 188, 85)
    background = ChunkyPNG::Color.rgb(255, 255, 255)

    expect(ChunkyPNG::Color.compose_managed(foreground, background, srgb, srgb, srgb)).to eql 0xebebebff
    expect(ChunkyPNG::Color.compose_managed(foreground, background, gamma_22, srgb, srgb)).to eql 0xfafafaff
    expect(ChunkyPNG::Color.compose_quick(foreground, background)).to eql 0xe9e9e9ff
  end

  it "does not let hidden RGB in transparent pixels pollute the edge" do
    foreground = ChunkyPNG::Color.rgba(255, 0, 0, 0)
    background = ChunkyPNG::Color.rgba(0, 255, 0, 0)

    expect(ChunkyPNG::Color.compose_managed(foreground, background, srgb, srgb, srgb)).to eql background
  end

  it "leaves alpha unencoded while adapting a color to another white point" do
    chromaticities = {
      red_x: 3/5r, red_y: 3/10r,
      green_x: 1/5r, green_y: 3/5r,
      blue_x: 3/20r, blue_y: 1/20r,
    }
    source_white = chromaticities.merge(white_x: 2125/10_000r, white_y: 1500/10_000r)
    target_white = chromaticities.merge(white_x: 2122/10_000r, white_y: 1610/10_000r)
    source = ChunkyPNG::ColorProfile.custom(
      gamma: 1.0,
      chromaticities: ChunkyPNG::ColorProfile::Chromaticities.new(source_white)
    )
    target = ChunkyPNG::ColorProfile.custom(
      gamma: 1.0,
      chromaticities: ChunkyPNG::ColorProfile::Chromaticities.new(target_white)
    )

    foreground = ChunkyPNG::Color.rgba(255, 0, 0, 85)
    background = ChunkyPNG::Color.rgb(255, 255, 255)

    expect(ChunkyPNG::Color.compose_managed(foreground, background, source, target, target)).to eql 0xffabaaff
  end
end

describe ChunkyPNG::Canvas::Operations do
  let(:srgb) { ChunkyPNG::ColorProfile.srgb }

  it "composes canvases through the managed entry and assigns the target profile" do
    background = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgb(255, 255, 255))
    foreground = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(188, 188, 188, 85))
    foreground.color_profile = srgb
    background.color_profile = srgb

    result = background.compose_managed(foreground)

    expect(result[0, 0]).to eql 0xebebebff
    expect(result.color_profile).to equal(srgb)
  end

  it "keeps the ordinary fast compositing API unchanged" do
    background = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgb(255, 255, 255))
    foreground = ChunkyPNG::Canvas.new(1, 1, ChunkyPNG::Color.rgba(188, 188, 188, 85))

    expect(background.compose(foreground)[0, 0]).to eql 0xe9e9e9ff
  end
end
