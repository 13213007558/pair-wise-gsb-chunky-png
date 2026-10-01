require "spec_helper"

describe ChunkyPNG::Chunk::AnimationControl do
  it "should read and write the frame count and loop count" do
    chunk = described_class.new(3, 7)
    serialized = serialized_chunk(chunk)
    expect(serialized).to be_a(described_class)
    expect(serialized.num_frames).to eql 3
    expect(serialized.num_plays).to eql 7
  end

  it "should preserve an infinite loop count of 0" do
    chunk = described_class.new(1, 0)
    expect(serialized_chunk(chunk).num_plays).to eql 0
  end

  it "should raise when the content has the wrong size" do
    expect { described_class.read("acTL", "\x00\x01".b) }.to raise_error(ChunkyPNG::ExpectationFailed)
  end

  it "should raise when zero frames are declared" do
    content = [0, 0].pack("NN")
    expect { described_class.read("acTL", content) }.to raise_error(ChunkyPNG::ExpectationFailed)
  end
end

describe ChunkyPNG::Chunk::FrameControl do
  let(:attributes) do
    {
      sequence_number: 4,
      width: 2,
      height: 3,
      x_offset: 1,
      y_offset: 3,
      delay_num: 7,
      delay_den: 100,
      dispose_op: ChunkyPNG::APNG_DISPOSE_OP_PREVIOUS,
      blend_op: ChunkyPNG::APNG_BLEND_OP_OVER,
    }
  end

  it "should read and write all frame control fields" do
    chunk = described_class.new(attributes)
    loaded = serialized_chunk(chunk)
    attributes.each { |key, value| expect(loaded.send(key)).to eql value }
  end

  it "should use default frame timing of 1/100 seconds" do
    chunk = described_class.new(width: 1, height: 1)
    expect(chunk.delay_num).to eql 1
    expect(chunk.delay_den).to eql 100
  end

  it "should accept a valid first frame that covers the full canvas" do
    chunk = described_class.new(attributes.merge(width: 8, height: 6, x_offset: 0, y_offset: 0))
    expect { chunk.validate!(8, 6, first_frame: true) }.not_to raise_error
  end

  it "should reject a first frame that does not cover the full canvas" do
    chunk = described_class.new(attributes)
    expect { chunk.validate!(8, 6, first_frame: true) }.to raise_error(ChunkyPNG::ExpectationFailed, /first frame/i)
  end

  it "should accept a later frame with a partial region" do
    chunk = described_class.new(attributes)
    expect { chunk.validate!(8, 6) }.not_to raise_error
  end

  it "should reject an unknown dispose operation" do
    chunk = described_class.new(attributes.merge(dispose_op: 9))
    chunk.content_length = 26
    expect { chunk.validate!(8, 6) }.to raise_error(ChunkyPNG::ExpectationFailed, /dispose/i)
  end

  it "should reject an unknown blend operation" do
    chunk = described_class.new(attributes.merge(blend_op: 9))
    chunk.content_length = 26
    expect { chunk.validate!(8, 6) }.to raise_error(ChunkyPNG::ExpectationFailed, /blend/i)
  end

  it "should reject zero-sized frames" do
    chunk = described_class.new(attributes.merge(width: 0, height: 3))
    chunk.content_length = 26
    expect { chunk.validate!(8, 6) }.to raise_error(ChunkyPNG::ExpectationFailed)
  end

  it "should reject frames outside the canvas" do
    chunk = described_class.new(attributes.merge(width: 8, height: 1, x_offset: 1))
    chunk.content_length = 26
    expect { chunk.validate!(8, 6) }.to raise_error(ChunkyPNG::ExpectationFailed)
  end

  it "should reject truncated content" do
    chunk = described_class.read("fcTL", "\x00" * 20)
    expect { chunk.validate!(8, 6) }.to raise_error(ChunkyPNG::ExpectationFailed, /26 bytes/)
  end
end

describe ChunkyPNG::Chunk::FrameData do
  it "should prefix the data with the sequence number" do
    chunk = described_class.new(5, "hello".b)
    expect(chunk.content).to eql([5].pack("N") << "hello".b)
  end

  it "should read back the sequence number and data" do
    chunk = serialized_chunk(described_class.new(9, "data".b))
    expect(chunk).to be_a(described_class)
    expect(chunk.sequence_number).to eql 9
    expect(chunk.data).to eql "data".b
  end

  it "should combine and inflate the data of several chunks" do
    deflated = Zlib::Deflate.deflate("pixeldata".b)
    part1 = described_class.new(0, deflated.byteslice(0, 3))
    part2 = described_class.new(1, deflated.byteslice(3..-1))
    expect(described_class.combine_chunks([part1, part2])).to eql "pixeldata".b
  end
end
